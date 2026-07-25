package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
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

const cookieBridgeStateSchema = 5

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "seed-init":
		err = cmdSeedInit(os.Args[2:])
	case "join-init":
		err = cmdJoinInit(os.Args[2:])
	case "server-init":
		err = cmdServerInit(os.Args[2:])
	case "server-verify":
		err = cmdServerVerify(os.Args[2:])
	case "server-enroll":
		err = cmdServerEnroll(os.Args[2:])
	case "server-revoke":
		err = cmdServerRevoke(os.Args[2:])
	case "enrollment-complete":
		err = cmdEnrollmentComplete(os.Args[2:])
	case "credential-activate":
		err = cmdCredentialActivate(os.Args[2:])
	case "credential-stage", "credential-confirm", "credential-retire":
		err = cmdRemoteAction(os.Args[1], os.Args[2:])
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
	flags := flag.NewFlagSet("seed-init", flag.ContinueOnError)
	device := flags.String("device", "d", "seed device id")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "new seed client state")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "new seed device credential")
	bootstrapFile := flags.String(
		"bootstrap-file", "", "new hash-only server bootstrap JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *bootstrapFile == "" {
		return errors.New("--bootstrap-file is required")
	}
	for _, path := range []string{
		*stateFile, *tokenFile, *bootstrapFile,
	} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf(
				"refusing to replace existing seed material: %s", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := ensureSecretFile(*tokenFile, 32); err != nil {
		return err
	}
	state, err := syncstore.CreateSeedStateForDevice(*stateFile, *device)
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
	fmt.Printf(
		"seed client state: %s\ntoken file: %s\nserver bootstrap: %s\n",
		*stateFile, *tokenFile, *bootstrapFile)
	return nil
}

func cmdJoinInit(args []string) error {
	flags := flag.NewFlagSet("join-init", flag.ContinueOnError)
	device := flags.String("device", "", "join device id")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(),
		"new pending pull-only client state")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "new device credential")
	authRequestFile := flags.String(
		"auth-request-file", "", "new hash-only enrollment request JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *device == "" || *authRequestFile == "" {
		return errors.New("--device and --auth-request-file are required")
	}
	for _, path := range []string{
		*stateFile, *tokenFile, *authRequestFile,
	} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf(
				"refusing to replace existing join material: %s", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := ensureSecretFile(*tokenFile, 32); err != nil {
		return err
	}
	if _, err := syncstore.CreateJoinState(
		*stateFile, *device); err != nil {
		return err
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	request, err := syncstore.NewDeviceEnrollmentRequest(*device, token)
	if err != nil {
		return err
	}
	if err := writeJSONExclusive(*authRequestFile, request); err != nil {
		return err
	}
	fmt.Printf(
		"pending client state: %s\ntoken file: %s\nauth request: %s\n",
		*stateFile, *tokenFile, *authRequestFile)
	return nil
}

func cmdServerInit(args []string) error {
	flags := flag.NewFlagSet("server-init", flag.ContinueOnError)
	dataDir := flags.String(
		"data-dir", defaultDataDir(), "new server data directory")
	devicesFile := flags.String(
		"devices-file", filepath.Join(defaultDataDir(), "devices.json"),
		"new hashed device registry")
	bootstrapFile := flags.String(
		"bootstrap-file", "", "seed-produced hash-only bootstrap JSON")
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
	if _, err := syncstore.CreateDeviceRegistryFromBootstrap(
		*devicesFile, bootstrap); err != nil {
		return err
	}
	if _, err := syncstore.OpenStore(*dataDir); err != nil {
		return err
	}
	fmt.Printf(
		"data dir: %s\ndevice registry: %s\n", *dataDir, *devicesFile)
	return nil
}

func cmdServerVerify(args []string) error {
	flags := flag.NewFlagSet("server-verify", flag.ContinueOnError)
	dataDir := flags.String(
		"data-dir", defaultDataDir(), "restored server data directory")
	devicesFile := flags.String(
		"devices-file", filepath.Join(defaultDataDir(), "devices.json"),
		"restored hashed device registry")
	if err := flags.Parse(args); err != nil {
		return err
	}
	cursor, err := syncstore.VerifyStore(*dataDir)
	if err != nil {
		return err
	}
	if _, err := syncstore.OpenDeviceRegistry(*devicesFile); err != nil {
		return err
	}
	return writePretty(map[string]any{
		"verified": true, "cursor": cursor,
	})
}

func cmdServerEnroll(args []string) error {
	flags := flag.NewFlagSet("server-enroll", flag.ContinueOnError)
	devicesFile := flags.String(
		"devices-file", filepath.Join(defaultDataDir(), "devices.json"),
		"hashed device registry")
	requestFile := flags.String(
		"auth-request-file", "", "hash-only enrollment request JSON")
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
	if err := registry.EnrollPullOnlyRequest(request); err != nil {
		return err
	}
	fmt.Printf("registry_updated=enroll:%s\n", request.DeviceID)
	return nil
}

func cmdServerRevoke(args []string) error {
	flags := flag.NewFlagSet("server-revoke", flag.ContinueOnError)
	devicesFile := flags.String(
		"devices-file", filepath.Join(defaultDataDir(), "devices.json"),
		"hashed device registry")
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
	if err := registry.Revoke(*device); err != nil {
		return err
	}
	fmt.Printf("registry_updated=revoke:%s\n", *device)
	return nil
}

func cmdEnrollmentComplete(args []string) error {
	flags := flag.NewFlagSet(
		"enrollment-complete", flag.ContinueOnError)
	baseURL := flags.String(
		"url", envOrDefault("HELIUM_SYNC_URL", ""),
		"HTTP daemon URL on loopback or Tailnet")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "pending client state")
	passwordState := flags.String(
		"password-state", filepath.Join(
			defaultConfigDir(), "password-state.json"),
		"browser-verified password state")
	cookieState := flags.String(
		"cookie-state", filepath.Join(defaultConfigDir(), "cookie-state.json"),
		"browser-verified cookie state")
	profileDir := flags.String(
		"profile-dir", "", "browser profile root, which must be stopped")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *baseURL == "" || *profileDir == "" {
		return errors.New("--url and --profile-dir are required")
	}
	if err := requireStoppedProfile(*profileDir); err != nil {
		return err
	}
	clientState, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	passwordSequence, err := readPasswordVerifiedSequence(*passwordState)
	if err != nil {
		return fmt.Errorf("password readiness: %w", err)
	}
	cookieSequence, err := readVerifiedSequence(
		*cookieState, cookieBridgeStateSchema)
	if err != nil {
		return fmt.Errorf("cookie readiness: %w", err)
	}
	if passwordSequence != cookieSequence ||
		passwordSequence != int64(clientState.Sequence) {
		return fmt.Errorf(
			"enrollment is not ready: password=%d cookie=%d client=%d",
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

func cmdCredentialActivate(args []string) error {
	flags := flag.NewFlagSet(
		"credential-activate", flag.ContinueOnError)
	baseURL := flags.String(
		"url", envOrDefault("HELIUM_SYNC_URL", ""),
		"HTTP daemon URL on loopback or Tailnet")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "client state")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "current profile credential")
	newTokenFile := flags.String(
		"new-token-file", "", "staged new credential")
	oldTokenFile := flags.String(
		"old-token-file", "", "new rollback copy of the old credential")
	profileDir := flags.String(
		"profile-dir", "", "browser profile root, which must be stopped")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *baseURL == "" || *newTokenFile == "" ||
		*oldTokenFile == "" || *profileDir == "" {
		return errors.New(
			"--url, --new-token-file, --old-token-file, and --profile-dir are required")
	}
	if err := requireStoppedProfile(*profileDir); err != nil {
		return err
	}
	currentToken, err := readPrivateSecret(*tokenFile)
	if err != nil {
		return err
	}
	newToken, err := readPrivateSecret(*newTokenFile)
	if err != nil {
		return err
	}
	if currentToken == newToken {
		return errors.New(
			"new credential is identical to the installed credential")
	}
	if err := ensureCredentialBackup(
		*oldTokenFile, currentToken); err != nil {
		return err
	}
	client, err := syncstore.NewClient(*baseURL, newToken, *stateFile)
	if err != nil {
		return err
	}
	if err := client.ConfirmCredential(context.Background()); err != nil {
		return fmt.Errorf(
			"new credential was not accepted and confirmed: %w", err)
	}
	if err := replaceCredentialAtomically(
		*tokenFile, currentToken, newToken); err != nil {
		return err
	}
	fmt.Printf(
		"credential_activated=%s\nold_credential_backup=%s\n",
		*tokenFile, *oldTokenFile)
	return nil
}

func cmdRemoteAction(action string, args []string) error {
	flags := flag.NewFlagSet(action, flag.ContinueOnError)
	baseURL := flags.String(
		"url", envOrDefault("HELIUM_SYNC_URL", ""),
		"HTTP daemon URL on loopback or Tailnet")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "current device credential")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "client state")
	newTokenFile := flags.String(
		"new-token-file", "", "new device credential for credential-stage")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *baseURL == "" {
		return errors.New("--url is required")
	}
	token, err := readSecret(*tokenFile)
	if err != nil {
		return err
	}
	client, err := syncstore.NewClient(*baseURL, token, *stateFile)
	if err != nil {
		return err
	}
	switch action {
	case "credential-stage":
		if *newTokenFile == "" || !filepath.IsAbs(*newTokenFile) {
			return errors.New(
				"--new-token-file must be an absolute path")
		}
		if _, err := os.Lstat(*newTokenFile); errors.Is(err, os.ErrNotExist) {
			if err := ensureSecretFile(*newTokenFile, 32); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
		newToken, err := readPrivateSecret(*newTokenFile)
		if err != nil {
			return err
		}
		return client.StageCredential(context.Background(), newToken)
	case "credential-confirm":
		return client.ConfirmCredential(context.Background())
	case "credential-retire":
		return client.RetireOldCredential(context.Background())
	default:
		return fmt.Errorf("unknown remote action %q", action)
	}
}

func cmdPush(args []string) error {
	flags := flag.NewFlagSet("push", flag.ContinueOnError)
	baseURL := flags.String(
		"url",
		envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"),
		"HTTP daemon URL on loopback or Tailnet")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "client state")
	kindValue := flags.String(
		"kind", "", "record kind: passwords or cookies")
	key := flags.String("key", "", "record key")
	payloadFile := flags.String(
		"payload-file", "-", "payload JSON file, or - for stdin")
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
	response, err := client.Push(context.Background(),
		[]syncstore.PlainMutation{{
			Kind: kind, Key: *key, Deleted: *deleted, Payload: payload,
		}})
	if err != nil {
		return err
	}
	return writePretty(response)
}

func cmdPull(args []string, latest bool) error {
	flags := flag.NewFlagSet("pull", flag.ContinueOnError)
	baseURL := flags.String(
		"url",
		envOrDefault("HELIUM_SYNC_URL", "http://127.0.0.1:44719"),
		"HTTP daemon URL on loopback or Tailnet")
	tokenFile := flags.String(
		"token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String(
		"state-file", defaultClientStatePath(), "client state")
	var kindFlags repeatedFlag
	flags.Var(
		&kindFlags, "kind", "record kind filter; may be repeated")
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

func (value *repeatedFlag) String() string {
	return strings.Join(*value, ",")
}

func (value *repeatedFlag) Set(item string) error {
	*value = append(*value, item)
	return nil
}

func ensureSecretFile(path string, length int) error {
	if raw, err := os.ReadFile(path); err == nil &&
		strings.TrimSpace(string(raw)) != "" {
		return nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	random := make([]byte, length)
	if _, err := rand.Read(random); err != nil {
		return err
	}
	secret := base64.RawURLEncoding.EncodeToString(random) + "\n"
	return writeExclusive(path, []byte(secret), 0600)
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

func readPrivateSecret(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf(
			"credential path must be absolute: %s", path)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", fmt.Errorf(
			"credential must be a regular file with mode 0600 or stricter: %s",
			path)
	}
	return readSecret(path)
}

func ensureCredentialBackup(path, expected string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf(
			"credential backup path must be absolute: %s", path)
	}
	if _, err := os.Lstat(path); err == nil {
		backup, err := readPrivateSecret(path)
		if err != nil {
			return err
		}
		if backup != expected {
			return errors.New(
				"existing credential backup does not match the installed credential")
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return writeExclusive(path, []byte(expected+"\n"), 0600)
}

func replaceCredentialAtomically(path, expected, replacement string) error {
	installed, err := readPrivateSecret(path)
	if err != nil {
		return err
	}
	if installed != expected {
		return errors.New("installed credential changed during activation")
	}
	directory := filepath.Dir(path)
	temp, err := os.CreateTemp(directory, ".helium-credential-*.tmp")
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
	if _, err := temp.WriteString(replacement + "\n"); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	installed, err = readPrivateSecret(path)
	if err != nil {
		return err
	}
	if installed != expected {
		return errors.New(
			"installed credential changed before atomic activation")
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func requireStoppedProfile(profileDir string) error {
	if !filepath.IsAbs(profileDir) {
		return fmt.Errorf(
			"profile directory must be absolute: %s", profileDir)
	}
	if _, err := os.Lstat(
		filepath.Join(profileDir, "SingletonLock")); err == nil {
		return errors.New(
			"browser profile still has a SingletonLock; stop the browser first")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
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
			return fmt.Errorf(
				"decode %s: unexpected trailing JSON", path)
		}
		return fmt.Errorf("decode %s: %w", path, err)
	}
	return nil
}

func writeJSONExclusive(path string, value any) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("output path is required")
	}
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return writeExclusive(path, append(raw, '\n'), 0600)
}

func writeExclusive(
	path string, contents []byte, mode os.FileMode) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("output path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(
		path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(contents); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	complete = true
	return syncParent(filepath.Dir(path))
}

func syncParent(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func readVerifiedSequence(path string, expectedSchema int) (int64, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var state map[string]json.RawMessage
	if err := json.Unmarshal(raw, &state); err != nil {
		return 0, err
	}
	var schema int
	if err := json.Unmarshal(
		state["schema_version"], &schema); err != nil ||
		schema != expectedSchema {
		return 0, fmt.Errorf(
			"expected schema_version %d", expectedSchema)
	}
	var encoded string
	if err := json.Unmarshal(
		state["verified_sequence"], &encoded); err != nil {
		return 0, errors.New(
			"verified_sequence is missing or not a string")
	}
	sequence, err := strconv.ParseInt(encoded, 10, 64)
	if err != nil || sequence < 0 {
		return 0, errors.New(
			"verified_sequence is not a non-negative int64 string")
	}
	return sequence, nil
}

func validateCanonicalPasswordState(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return err
	}
	if len(root) != 4 {
		return errors.New("password state has an unexpected field inventory")
	}
	var identitySchema string
	if err := json.Unmarshal(
		root["identity_schema"], &identitySchema); err != nil ||
		identitySchema != "password-form-unique-key-v2" {
		return errors.New("password identity schema is not canonical v2")
	}
	var credentials map[string]json.RawMessage
	if err := json.Unmarshal(
		root["credentials"], &credentials); err != nil {
		return errors.New("password credentials are missing or invalid")
	}
	for key, recordRaw := range credentials {
		const prefix = "credential/v2/"
		if !strings.HasPrefix(key, prefix) ||
			len(key) != len(prefix)+64 {
			return fmt.Errorf(
				"password credential key %q is not canonical v2", key)
		}
		if _, err := hex.DecodeString(
			strings.TrimPrefix(key, prefix)); err != nil {
			return fmt.Errorf(
				"password credential key %q is invalid", key)
		}
		var record map[string]json.RawMessage
		if err := json.Unmarshal(recordRaw, &record); err != nil {
			return fmt.Errorf(
				"password credential state %q is invalid", key)
		}
		if _, pending := record["pending_publication"]; pending {
			return fmt.Errorf(
				"password credential %q has an unresolved publication", key)
		}
		if _, queued := record["queued_mutation"]; queued {
			return fmt.Errorf(
				"password credential %q has an unpublished mutation", key)
		}
	}
	return nil
}

func readPasswordVerifiedSequence(path string) (int64, error) {
	if err := validateCanonicalPasswordState(path); err != nil {
		return 0, err
	}
	return readVerifiedSequence(path, 6)
}

func readPasswordRevisions(
	path string) (int64, map[string]syncstore.Counter, error) {
	if err := validateCanonicalPasswordState(path); err != nil {
		return 0, nil, err
	}
	return readBrowserRevisions(path, 6, "credentials", "revision")
}

func readBrowserRevisions(path string, expectedSchema int,
	collectionField, revisionField string,
) (int64, map[string]syncstore.Counter, error) {
	sequence, err := readVerifiedSequence(path, expectedSchema)
	if err != nil {
		return 0, nil, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, nil, err
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return 0, nil, err
	}
	var records map[string]json.RawMessage
	if err := json.Unmarshal(
		root[collectionField], &records); err != nil {
		return 0, nil, fmt.Errorf(
			"%s is missing or invalid", collectionField)
	}
	revisions := make(map[string]syncstore.Counter, len(records))
	for key, recordRaw := range records {
		if strings.TrimSpace(key) == "" {
			return 0, nil, errors.New(
				"browser revision inventory contains an empty key")
		}
		var record map[string]json.RawMessage
		if err := json.Unmarshal(recordRaw, &record); err != nil {
			return 0, nil, fmt.Errorf(
				"browser revision for %q is invalid", key)
		}
		var encoded string
		if err := json.Unmarshal(
			record[revisionField], &encoded); err != nil {
			return 0, nil, fmt.Errorf(
				"browser revision for %q is missing", key)
		}
		value, err := strconv.ParseInt(encoded, 10, 64)
		if err != nil || value < 0 {
			return 0, nil, fmt.Errorf(
				"browser revision for %q is invalid", key)
		}
		revisions[key] = syncstore.Counter(value)
	}
	return sequence, revisions, nil
}

func writePretty(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func usage() {
	fmt.Fprintln(os.Stderr,
		"usage: helium-sync <seed-init|join-init|server-init|server-verify|server-enroll|server-revoke|enrollment-complete|credential-activate|credential-stage|credential-confirm|credential-retire|push|pull|latest> [flags]")
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
	return envOrDefault(
		"HELIUM_SYNC_STATE_FILE",
		filepath.Join(defaultConfigDir(), "client.json"))
}

func defaultTokenPath() string {
	return envOrDefault(
		"HELIUM_SYNC_TOKEN_FILE",
		filepath.Join(defaultConfigDir(), "token"))
}
