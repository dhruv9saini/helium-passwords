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

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "seed-init":
		err = cmdSeedInit(os.Args[2:])
	case "server-init":
		err = cmdServerInit(os.Args[2:])
	case "join-request":
		err = cmdJoinRequest(os.Args[2:])
	case "seed-wrap":
		err = cmdSeedWrap(os.Args[2:])
	case "join-install":
		err = cmdJoinInstall(os.Args[2:])
	case "server-enroll":
		err = cmdServerEnroll(os.Args[2:])
	case "server-revoke":
		err = cmdServerRevoke(os.Args[2:])
	case "enrollment-complete":
		err = cmdEnrollmentComplete(os.Args[2:])
	case "push":
		err = cmdPush(os.Args[2:])
	case "pull":
		err = cmdPull(os.Args[2:], false)
	case "latest":
		err = cmdPull(os.Args[2:], true)
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func cmdSeedInit(args []string) error {
	flags := flag.NewFlagSet("seed-init", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "new d seed client state")
	tokenFile := flags.String("token-file", defaultTokenPath(), "new d device credential")
	bootstrapFile := flags.String("bootstrap-file", "", "new server bootstrap JSON containing no plaintext secret")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *bootstrapFile == "" {
		return errors.New("--bootstrap-file is required")
	}
	if err := ensureSecretFile(*tokenFile, 32); err != nil {
		return err
	}
	state, err := syncstore.CreateSeedState(*stateFile)
	if err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	bootstrap, err := syncstore.NewServerBootstrap(state, token)
	if err != nil {
		return err
	}
	if err := writeJSONExclusive(*bootstrapFile, bootstrap); err != nil {
		return err
	}
	fmt.Printf("seed client state: %s\n", *stateFile)
	fmt.Printf("token file: %s\n", *tokenFile)
	fmt.Printf("server bootstrap: %s\n", *bootstrapFile)
	return nil
}

func cmdServerInit(args []string) error {
	flags := flag.NewFlagSet("server-init", flag.ExitOnError)
	dataDir := flags.String("data-dir", defaultDataDir(), "new opaque server data directory")
	devicesFile := flags.String("devices-file", filepath.Join(defaultDataDir(), "devices.json"), "new hashed device registry")
	bootstrapFile := flags.String("bootstrap-file", "", "seed-produced server bootstrap JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *bootstrapFile == "" {
		return errors.New("--bootstrap-file is required")
	}
	var bootstrap syncstore.ServerBootstrap
	if err := readJSONFile(*bootstrapFile, &bootstrap); err != nil {
		return err
	}
	if _, err := syncstore.CreateDeviceRegistryFromBootstrap(*devicesFile, bootstrap); err != nil {
		return err
	}
	if _, err := syncstore.OpenStore(*dataDir); err != nil {
		return err
	}
	fmt.Printf("opaque data dir: %s\n", *dataDir)
	fmt.Printf("device registry: %s\n", *devicesFile)
	return nil
}

func cmdJoinRequest(args []string) error {
	flags := flag.NewFlagSet("join-request", flag.ExitOnError)
	device := flags.String("device", "", "join device id: da or oneplus")
	seedPublicFile := flags.String("seed-public-file", "", "authenticated d signing public key file")
	pendingFile := flags.String("pending-file", "", "new device-local pending X25519 state")
	requestFile := flags.String("request-file", "", "new public join request JSON")
	authRequestFile := flags.String("auth-request-file", "", "new hashed credential enrollment request JSON")
	tokenFile := flags.String("token-file", defaultTokenPath(), "new device-local bearer credential")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *device == "" || *seedPublicFile == "" || *pendingFile == "" ||
		*requestFile == "" || *authRequestFile == "" {
		return errors.New("--device, --seed-public-file, --pending-file, --request-file, and --auth-request-file are required")
	}
	if err := ensureSecretFile(*tokenFile, 32); err != nil {
		return err
	}
	seedPublic, err := readSecret(*seedPublicFile)
	if err != nil {
		return err
	}
	request, err := syncstore.CreateJoinRequest(*pendingFile, *device, seedPublic)
	if err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	authRequest, err := syncstore.NewDeviceEnrollmentRequest(*device, token)
	if err != nil {
		return err
	}
	if err := writeJSONExclusive(*requestFile, request); err != nil {
		return err
	}
	if err := writeJSONExclusive(*authRequestFile, authRequest); err != nil {
		return err
	}
	fmt.Printf("join request: %s\nauth request: %s\npending state: %s\ntoken file: %s\n",
		*requestFile, *authRequestFile, *pendingFile, *tokenFile)
	return nil
}

func cmdSeedWrap(args []string) error {
	flags := flag.NewFlagSet("seed-wrap", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "d seed client state")
	requestFile := flags.String("request-file", "", "join request JSON")
	wrappedFile := flags.String("wrapped-file", "", "new d-signed encrypted enrollment JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *requestFile == "" || *wrappedFile == "" {
		return errors.New("--request-file and --wrapped-file are required")
	}
	state, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	var request syncstore.JoinRequest
	if err := readJSONFile(*requestFile, &request); err != nil {
		return err
	}
	wrapped, err := state.WrapEnrollment(request)
	if err != nil {
		return err
	}
	return writeJSONExclusive(*wrappedFile, wrapped)
}

func cmdJoinInstall(args []string) error {
	flags := flag.NewFlagSet("join-install", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "new pending join client state")
	pendingFile := flags.String("pending-file", "", "device-local pending X25519 state")
	wrappedFile := flags.String("wrapped-file", "", "d-signed encrypted enrollment JSON")
	var requiredKeyIDs repeatedFlag
	flags.Var(&requiredKeyIDs, "required-key-id", "server-observed content key id; repeat for every live epoch")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *pendingFile == "" || *wrappedFile == "" || len(requiredKeyIDs) == 0 {
		return errors.New("--pending-file, --wrapped-file, and at least one --required-key-id are required")
	}
	var wrapped syncstore.WrappedEnrollment
	if err := readJSONFile(*wrappedFile, &wrapped); err != nil {
		return err
	}
	state, err := syncstore.CompleteJoinState(*stateFile, *pendingFile, wrapped, requiredKeyIDs)
	if err != nil {
		return err
	}
	fmt.Printf("installed pending pull-only client state for %s: %s\n", state.DeviceID, *stateFile)
	return nil
}

func cmdServerEnroll(args []string) error {
	flags := flag.NewFlagSet("server-enroll", flag.ExitOnError)
	devicesFile := flags.String("devices-file", filepath.Join(defaultDataDir(), "devices.json"), "hashed device registry")
	requestFile := flags.String("auth-request-file", "", "device-produced hashed credential request")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *requestFile == "" {
		return errors.New("--auth-request-file is required")
	}
	var request syncstore.DeviceEnrollmentRequest
	if err := readJSONFile(*requestFile, &request); err != nil {
		return err
	}
	registry, err := syncstore.OpenDeviceRegistry(*devicesFile)
	if err != nil {
		return err
	}
	return registry.EnrollPullOnlyRequest(request)
}

func cmdServerRevoke(args []string) error {
	flags := flag.NewFlagSet("server-revoke", flag.ExitOnError)
	devicesFile := flags.String("devices-file", filepath.Join(defaultDataDir(), "devices.json"), "hashed device registry")
	device := flags.String("device", "", "join device id to revoke")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *device == "" {
		return errors.New("--device is required")
	}
	registry, err := syncstore.OpenDeviceRegistry(*devicesFile)
	if err != nil {
		return err
	}
	return registry.Revoke(*device)
}

func cmdEnrollmentComplete(args []string) error {
	flags := flag.NewFlagSet("enrollment-complete", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", ""), "HTTPS daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "pending client E2EE state")
	passwordState := flags.String("password-state", filepath.Join(defaultConfigDir(), "password-state.json"), "browser-verified password state")
	cookieState := flags.String("cookie-state", filepath.Join(defaultConfigDir(), "cookie-state.json"), "browser-verified cookie state")
	if err := flags.Parse(args); err != nil {
		return err
	}
	clientState, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	passwordSequence, err := readVerifiedSequence(*passwordState)
	if err != nil {
		return fmt.Errorf("password readiness: %w", err)
	}
	cookieSequence, err := readVerifiedSequence(*cookieState)
	if err != nil {
		return fmt.Errorf("cookie readiness: %w", err)
	}
	if passwordSequence != cookieSequence || passwordSequence != int64(clientState.Sequence) {
		return fmt.Errorf("enrollment is not ready: password=%d cookie=%d client=%d",
			passwordSequence, cookieSequence, clientState.Sequence)
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	client, err := syncstore.NewClient(*baseURL, token, *stateFile)
	if err != nil {
		return err
	}
	return client.CompleteEnrollment(context.Background())
}

func cmdPush(args []string) error {
	flags := flag.NewFlagSet("push", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"), "daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "client E2EE state")
	kindValue := flags.String("kind", "", "record kind: passwords or cookies")
	key := flags.String("key", "", "record key")
	payloadFile := flags.String("payload-file", "-", "payload JSON file, or - for stdin")
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
	client, err := syncstore.NewClient(*baseURL, token, *stateFile)
	if err != nil {
		return err
	}
	response, err := client.Push(context.Background(), []syncstore.PlainMutation{{
		Kind: kind, Key: *key, Deleted: *deleted, Payload: payload,
	}})
	if err != nil {
		return err
	}
	return writePretty(response)
}

func cmdPull(args []string, latest bool) error {
	flags := flag.NewFlagSet("pull", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"), "daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "client E2EE state")
	var kindFlags repeatedFlag
	flags.Var(&kindFlags, "kind", "record kind filter; may be repeated")
	if err := flags.Parse(args); err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	client, err := syncstore.NewClient(*baseURL, token, *stateFile)
	if err != nil {
		return err
	}
	var response syncstore.PlainPullResponse
	if latest {
		response, err = client.Latest(context.Background(), kindFlags)
	} else {
		response, err = client.Pull(context.Background(), kindFlags)
	}
	if err != nil {
		return err
	}
	return writePretty(response)
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

func readJSONFile(path string, value any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return fmt.Errorf("decode %s: %w", path, err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("decode %s: unexpected trailing JSON", path)
		}
		return fmt.Errorf("decode %s: %w", path, err)
	}
	return nil
}

func writeJSONExclusive(path string, value any) (resultErr error) {
	if strings.TrimSpace(path) == "" {
		return errors.New("output path is required")
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("refusing to replace existing file: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temp, err := os.CreateTemp(directory, ".helium-sync-*.tmp")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer func() {
		_ = temp.Close()
		_ = os.Remove(tempPath)
	}()
	if err := temp.Chmod(0600); err != nil {
		return err
	}
	encoder := json.NewEncoder(temp)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Link(tempPath, path); err != nil {
		return fmt.Errorf("install %s without overwrite: %w", path, err)
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func readVerifiedSequence(path string) (int64, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var state map[string]json.RawMessage
	if err := json.Unmarshal(raw, &state); err != nil {
		return 0, err
	}
	var encoded string
	if err := json.Unmarshal(state["verified_sequence"], &encoded); err != nil {
		return 0, errors.New("verified_sequence is missing or not a string")
	}
	sequence, err := strconv.ParseInt(encoded, 10, 64)
	if err != nil || sequence < 0 {
		return 0, errors.New("verified_sequence is not a non-negative int64 string")
	}
	return sequence, nil
}

func writePretty(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: helium-sync <seed-init|server-init|join-request|seed-wrap|join-install|server-enroll|server-revoke|enrollment-complete|push|pull|latest> [flags]")
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

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func defaultConfigDir() string {
	if value := os.Getenv("XDG_CONFIG_HOME"); value != "" {
		return filepath.Join(value, "helium-sync")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".helium-sync-client"
	}
	return filepath.Join(home, ".config", "helium-sync")
}

func defaultClientStatePath() string {
	return envOrDefault("HELIUM_SYNC_STATE_FILE", filepath.Join(defaultConfigDir(), "client.json"))
}

func defaultTokenPath() string {
	return envOrDefault("HELIUM_SYNC_TOKEN_FILE", filepath.Join(defaultConfigDir(), "token"))
}
