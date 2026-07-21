package main

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

const maxBodyBytes = 50 * 1024 * 1024

type app struct {
	cookieDir string
	mu        sync.Mutex
}

type cookieCloudRecord struct {
	Encrypted  string `json:"encrypted"`
	CryptoType string `json:"crypto_type,omitempty"`
	Revision   int64  `json:"revision"`
}

func main() {
	var (
		listen  = flag.String("listen", "127.0.0.1:8088", "listen address")
		dataDir = flag.String("data-dir", defaultDataDir(), "data directory")
	)
	flag.Parse()

	server := app{
		cookieDir: filepath.Join(*dataDir, "cookiecloud"),
	}
	if err := os.MkdirAll(server.cookieDir, 0700); err != nil {
		fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", server.route)

	slog.Info("helium-local-syncd listening", "addr", *listen, "data_dir", *dataDir)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		fatal(err)
	}
}

func (a *app) route(w http.ResponseWriter, r *http.Request) {
	addCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimRight(r.URL.Path, "/")
	switch {
	case path == "":
		writeText(w, http.StatusOK, "CookieCloud local API")
	case path == "/health":
		writeJSON(w, http.StatusOK, map[string]any{"status": "OK", "local": true})
	case path == "/update":
		a.cookieUpdate(w, r)
	case strings.HasPrefix(path, "/get/"):
		a.cookieGet(w, r, strings.TrimPrefix(path, "/get/"))
	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	}
}

func (a *app) cookieUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	body, err := readBody(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	values, err := parseBody(r.Header.Get("Content-Type"), body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	uuid := strings.TrimSpace(values.Get("uuid"))
	encrypted := strings.TrimSpace(values.Get("encrypted"))
	cryptoType := strings.TrimSpace(values.Get("crypto_type"))
	expectedRevision, err := strconv.ParseInt(strings.TrimSpace(values.Get("expected_revision")), 10, 64)
	if err != nil || expectedRevision < 0 {
		writeJSON(w, http.StatusPreconditionRequired, map[string]string{"error": "expected_revision is required"})
		return
	}
	if cryptoType == "" {
		cryptoType = "legacy"
	}
	if uuid == "" || encrypted == "" {
		writeText(w, http.StatusBadRequest, "Bad Request")
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	current, err := a.readCookieRecord(uuid)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if expectedRevision != current.Revision {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    "cookie record revision conflict",
			"revision": current.Revision,
		})
		return
	}
	record := cookieCloudRecord{
		Encrypted:  encrypted,
		CryptoType: cryptoType,
		Revision:   current.Revision + 1,
	}
	raw, err := json.Marshal(record)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if err := writeAtomic(a.cookieDir, a.cookiePath(uuid), raw); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"action": "done", "revision": record.Revision})
}

func (a *app) cookieGet(w http.ResponseWriter, _ *http.Request, uuid string) {
	uuid = strings.TrimSpace(uuid)
	if uuid == "" {
		writeText(w, http.StatusBadRequest, "Bad Request")
		return
	}
	raw, err := os.ReadFile(a.cookiePath(uuid))
	if errors.Is(err, os.ErrNotExist) {
		writeText(w, http.StatusNotFound, "Not Found")
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(raw)
}

func (a *app) cookiePath(uuid string) string {
	return filepath.Join(a.cookieDir, filepath.Base(uuid)+".json")
}

func (a *app) readCookieRecord(uuid string) (cookieCloudRecord, error) {
	raw, err := os.ReadFile(a.cookiePath(uuid))
	if err != nil {
		return cookieCloudRecord{}, err
	}
	var record cookieCloudRecord
	if err := json.Unmarshal(raw, &record); err != nil {
		return cookieCloudRecord{}, fmt.Errorf("decode cookie record: %w", err)
	}
	return record, nil
}

func writeAtomic(directory string, destination string, raw []byte) error {
	temporary, err := os.CreateTemp(directory, ".cookie-record-")
	if err != nil {
		return fmt.Errorf("create cookie record: %w", err)
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(raw); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, destination); err != nil {
		return fmt.Errorf("commit cookie record: %w", err)
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	if err := dir.Sync(); err != nil {
		dir.Close()
		return err
	}
	if err := dir.Close(); err != nil {
		return err
	}
	committed = true
	return nil
}

func readBody(r *http.Request) ([]byte, error) {
	reader := io.Reader(http.MaxBytesReader(nil, r.Body, maxBodyBytes))
	if strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
		gz, err := gzip.NewReader(reader)
		if err != nil {
			return nil, fmt.Errorf("open gzip body: %w", err)
		}
		defer gz.Close()
		reader = gz
	}
	defer r.Body.Close()
	return io.ReadAll(reader)
}

func parseBody(contentType string, body []byte) (url.Values, error) {
	values := make(url.Values)
	if strings.Contains(contentType, "application/json") || strings.TrimSpace(contentType) == "" {
		var raw map[string]any
		if err := json.Unmarshal(body, &raw); err != nil {
			return nil, fmt.Errorf("decode json: %w", err)
		}
		for key, value := range raw {
			switch typed := value.(type) {
			case string:
				values.Set(key, typed)
			default:
				values.Set(key, fmt.Sprint(typed))
			}
		}
		return values, nil
	}
	if strings.Contains(contentType, "application/x-www-form-urlencoded") {
		return url.ParseQuery(string(body))
	}
	return nil, fmt.Errorf("unsupported content type %q", contentType)
}

func defaultDataDir() string {
	if value := os.Getenv("XDG_DATA_HOME"); value != "" {
		return filepath.Join(value, "helium-local-sync")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".helium-local-sync"
	}
	return filepath.Join(home, ".local", "share", "helium-local-sync")
}

func addCORS(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Content-Encoding")
}

func writeText(w http.ResponseWriter, status int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(text))
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func fatal(err error) {
	slog.Error("fatal", "error", err)
	os.Exit(1)
}
