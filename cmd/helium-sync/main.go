package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/oof-baroomf/helium-sync/internal/syncstore"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "init":
		err = cmdInit(os.Args[2:])
	case "push":
		err = cmdPush(os.Args[2:])
	case "pull":
		err = cmdPull(os.Args[2:], false)
	case "latest":
		err = cmdPull(os.Args[2:], true)
	case "inspect-profile":
		err = cmdInspectProfile(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cmdInit(args []string) error {
	flags := flag.NewFlagSet("init", flag.ExitOnError)
	dataDir := flags.String("data-dir", defaultDataDir(), "helium-sync data directory")
	passphraseFile := flags.String("passphrase-file", envOrDefault("HELIUM_SYNC_PASSPHRASE_FILE", filepath.Join(defaultDataDir(), "passphrase")), "passphrase file")
	tokenFile := flags.String("token-file", envOrDefault("HELIUM_SYNC_TOKEN_FILE", filepath.Join(defaultDataDir(), "token")), "daemon token file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := os.MkdirAll(*dataDir, 0700); err != nil {
		return err
	}
	if err := ensureSecretFile(*passphraseFile, 32); err != nil {
		return err
	}
	if err := ensureSecretFile(*tokenFile, 32); err != nil {
		return err
	}
	passphrase, err := readSecret(*passphraseFile)
	if err != nil {
		return err
	}
	if _, err := syncstore.OpenStore(*dataDir, passphrase); err != nil {
		return err
	}
	fmt.Printf("initialized data dir: %s\n", *dataDir)
	fmt.Printf("passphrase file: %s\n", *passphraseFile)
	fmt.Printf("token file: %s\n", *tokenFile)
	return nil
}

func cmdPush(args []string) error {
	flags := flag.NewFlagSet("push", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"), "daemon URL")
	tokenFile := flags.String("token-file", envOrDefault("HELIUM_SYNC_TOKEN_FILE", filepath.Join(defaultDataDir(), "token")), "daemon token file")
	device := flags.String("device", envOrDefault("HELIUM_SYNC_DEVICE", defaultDeviceName()), "origin device name")
	kindValue := flags.String("kind", "", "record kind: tabs, passwords, or cookies")
	key := flags.String("key", "", "record key")
	payloadFile := flags.String("payload-file", "-", "payload JSON file, or - for stdin")
	version := flags.Int64("version", 0, "record version; defaults to current time")
	deleted := flags.Bool("deleted", false, "write tombstone record")
	if err := flags.Parse(args); err != nil {
		return err
	}
	kind, err := syncstore.ParseKind(*kindValue)
	if err != nil {
		return err
	}
	payload, err := readPayload(*payloadFile, *deleted)
	if err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	response, err := syncstore.NewClient(*baseURL, token).Push(context.Background(), syncstore.PushRequest{
		Device: *device,
		Records: []syncstore.PlainRecord{
			{
				Kind:      kind,
				Key:       *key,
				Version:   *version,
				Deleted:   *deleted,
				UpdatedAt: time.Now().UTC(),
				Payload:   payload,
			},
		},
	})
	if err != nil {
		return err
	}
	return writePretty(response)
}

func cmdPull(args []string, latest bool) error {
	flags := flag.NewFlagSet("pull", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"), "daemon URL")
	tokenFile := flags.String("token-file", envOrDefault("HELIUM_SYNC_TOKEN_FILE", filepath.Join(defaultDataDir(), "token")), "daemon token file")
	since := flags.Int64("since", 0, "first sequence to read after")
	includeDeleted := flags.Bool("include-deleted", false, "include tombstones in latest output")
	var kindFlags repeatedFlag
	flags.Var(&kindFlags, "kind", "record kind filter; may be repeated")
	if err := flags.Parse(args); err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	client := syncstore.NewClient(*baseURL, token)
	var response syncstore.PullResponse
	if latest {
		response, err = client.Latest(context.Background(), kindFlags, *includeDeleted)
	} else {
		response, err = client.Pull(context.Background(), *since, kindFlags)
	}
	if err != nil {
		return err
	}
	return writePretty(response)
}

func cmdInspectProfile(args []string) error {
	flags := flag.NewFlagSet("inspect-profile", flag.ExitOnError)
	profile := flags.String("profile", "", "Helium/Chromium profile directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*profile) == "" {
		return errors.New("--profile is required")
	}
	paths := []string{
		"Login Data",
		filepath.Join("Network", "Cookies"),
		filepath.Join("Sessions", "Session_"),
		filepath.Join("Sessions", "Tabs_"),
		"Preferences",
	}
	result := map[string]any{"profile": *profile}
	files := make(map[string]string)
	for _, rel := range paths {
		matches, err := filepath.Glob(filepath.Join(*profile, rel+"*"))
		if err != nil {
			return err
		}
		if len(matches) == 0 {
			files[rel] = "missing"
			continue
		}
		var sizes []string
		for _, match := range matches {
			info, err := os.Stat(match)
			if err != nil {
				sizes = append(sizes, filepath.Base(match)+": "+err.Error())
				continue
			}
			sizes = append(sizes, filepath.Base(match)+": "+strconv.FormatInt(info.Size(), 10)+" bytes")
		}
		files[rel] = strings.Join(sizes, ", ")
	}
	result["files"] = files
	result["note"] = "inspect-profile reports file presence and sizes only; it does not decrypt or print browser secrets"
	return writePretty(result)
}

type repeatedFlag []string

func (flag *repeatedFlag) String() string {
	return strings.Join(*flag, ",")
}

func (flag *repeatedFlag) Set(value string) error {
	*flag = append(*flag, value)
	return nil
}

func ensureSecretFile(path string, length int) error {
	if raw, err := os.ReadFile(path); err == nil && strings.TrimSpace(string(raw)) != "" {
		return nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	random := make([]byte, length)
	if _, err := rand.Read(random); err != nil {
		return err
	}
	secret := base64.RawURLEncoding.EncodeToString(random) + "\n"
	return os.WriteFile(path, []byte(secret), 0600)
}

func readPayload(path string, deleted bool) (json.RawMessage, error) {
	if deleted && path == "" {
		return json.RawMessage(`{}`), nil
	}
	var raw []byte
	var err error
	if path == "-" {
		raw, err = io.ReadAll(os.Stdin)
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return nil, err
	}
	raw = []byte(strings.TrimSpace(string(raw)))
	if len(raw) == 0 && deleted {
		raw = []byte(`{}`)
	}
	if !json.Valid(raw) {
		return nil, errors.New("payload must be valid JSON")
	}
	return json.RawMessage(raw), nil
}

func readSecret(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	secret := strings.TrimSpace(string(raw))
	if secret == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return secret, nil
}

func writePretty(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: helium-sync <init|push|pull|latest|inspect-profile> [flags]")
}

func defaultDataDir() string {
	if value := os.Getenv("HELIUM_SYNC_DATA_DIR"); value != "" {
		return value
	}
	if value := os.Getenv("XDG_DATA_HOME"); value != "" {
		return filepath.Join(value, "helium-sync")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".helium-sync"
	}
	return filepath.Join(home, ".local", "share", "helium-sync")
}

func defaultDeviceName() string {
	if hostname, err := os.Hostname(); err == nil && hostname != "" {
		return hostname
	}
	return "device"
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
