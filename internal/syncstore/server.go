package syncstore

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

const maxRequestBytes = 16 * 1024 * 1024

type HandlerOptions struct {
	Token string
}

func NewHandler(store *Store, options HandlerOptions) http.Handler {
	mux := http.NewServeMux()
	server := server{store: store, token: options.Token}
	mux.HandleFunc("/v1/health", server.health)
	mux.HandleFunc("/v1/records/push", server.withAuth(server.push))
	mux.HandleFunc("/v1/records/pull", server.withAuth(server.pull))
	mux.HandleFunc("/v1/records/latest", server.withAuth(server.latest))
	return mux
}

type server struct {
	store *Store
	token string
}

func (server server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (server server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if server.token == "" {
			writeError(w, http.StatusInternalServerError, errors.New("server token is not configured"))
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, errors.New("missing bearer token"))
			return
		}
		token := strings.TrimPrefix(auth, "Bearer ")
		if subtle.ConstantTimeCompare([]byte(token), []byte(server.token)) != 1 {
			writeError(w, http.StatusUnauthorized, errors.New("invalid bearer token"))
			return
		}
		next(w, r)
	}
}

func (server server) push(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return
	}
	defer r.Body.Close()
	var request PushRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBytes)).Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decode request: %w", err))
		return
	}
	response, err := server.store.Put(request.Records, request.Device)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (server server) pull(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return
	}
	since, kinds, _, err := parseQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	response, err := server.store.Pull(since, kinds)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (server server) latest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return
	}
	_, kinds, includeDeleted, err := parseQuery(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	response, err := server.store.Latest(kinds, includeDeleted)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func parseQuery(r *http.Request) (int64, map[Kind]struct{}, bool, error) {
	query := r.URL.Query()
	since := int64(0)
	if raw := query.Get("since"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < 0 {
			return 0, nil, false, errors.New("since must be a non-negative integer")
		}
		since = value
	}
	kinds, err := ParseKinds(query["kind"])
	if err != nil {
		return 0, nil, false, err
	}
	includeDeleted := false
	if raw := query.Get("include_deleted"); raw != "" {
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return 0, nil, false, errors.New("include_deleted must be a boolean")
		}
		includeDeleted = value
	}
	return since, kinds, includeDeleted, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}
