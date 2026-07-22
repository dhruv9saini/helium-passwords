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
	"time"

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

const cookieBridgeStateSchema = 3

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
	case "server-verify":
		err = cmdServerVerify(os.Args[2:])
	case "seed-public":
		err = cmdSeedPublic(os.Args[2:])
	case "join-request":
		err = cmdJoinRequest(os.Args[2:])
	case "seed-wrap":
		err = cmdSeedWrap(os.Args[2:])
	case "join-install":
		err = cmdJoinInstall(os.Args[2:])
	case "key-update-request":
		err = cmdKeyUpdateRequest(os.Args[2:])
	case "key-update-install":
		err = cmdKeyUpdateInstall(os.Args[2:])
	case "recovery-keygen":
		err = cmdRecoveryKeygen(os.Args[2:])
	case "recovery-export":
		err = cmdRecoveryExport(os.Args[2:])
	case "recovery-import":
		err = cmdRecoveryImport(os.Args[2:])
	case "tls-ca-init":
		err = cmdTLSCAInit(os.Args[2:])
	case "tls-server-issue":
		err = cmdTLSServerIssue(os.Args[2:])
	case "tls-server-verify":
		err = cmdTLSServerVerify(os.Args[2:])
	case "server-enroll":
		err = cmdServerEnroll(os.Args[2:])
	case "server-revoke":
		err = cmdServerRevoke(os.Args[2:])
	case "enrollment-complete":
		err = cmdEnrollmentComplete(os.Args[2:])
	case "credential-activate":
		err = cmdCredentialActivate(os.Args[2:])
	case "key-rekey":
		err = cmdKeyRekey(os.Args[2:])
	case "key-stage", "key-ack-install", "key-activate", "key-adopt",
		"key-ack-rekey", "key-retire", "credential-stage",
		"credential-confirm", "credential-retire":
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
	for _, path := range []string{*stateFile, *tokenFile, *bootstrapFile} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("refusing to replace existing seed material: %s", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
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

func cmdServerVerify(args []string) error {
	flags := flag.NewFlagSet("server-verify", flag.ExitOnError)
	dataDir := flags.String("data-dir", defaultDataDir(), "disposable restored opaque data directory")
	devicesFile := flags.String("devices-file", filepath.Join(defaultDataDir(), "devices.json"), "restored hashed device registry")
	if err := flags.Parse(args); err != nil {
		return err
	}
	cursor, err := syncstore.VerifyStore(*dataDir)
	if err != nil {
		return err
	}
	registry, err := syncstore.OpenDeviceRegistry(*devicesFile)
	if err != nil {
		return err
	}
	status := registry.KeyStatus()
	return writePretty(map[string]any{
		"verified": true, "cursor": cursor,
		"active_key_id":   status.ActiveKeyID,
		"staged_key_id":   status.StagedKeyID,
		"retiring_key_id": status.RetiringKeyID,
	})
}

func cmdSeedPublic(args []string) error {
	flags := flag.NewFlagSet("seed-public", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "d seed client state")
	output := flags.String("output", "", "new public trust-anchor file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *output == "" {
		return errors.New("--output is required")
	}
	state, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	return writeExclusive(*output, []byte(state.SeedSigningPublicKey()+"\n"), 0644)
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
	for _, path := range []string{*pendingFile, *requestFile, *authRequestFile, *tokenFile} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("refusing to replace existing join material: %s", path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
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

func cmdKeyUpdateRequest(args []string) error {
	flags := flag.NewFlagSet("key-update-request", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "active join client state")
	pendingFile := flags.String("pending-file", "", "new device-local pending X25519 state")
	requestFile := flags.String("request-file", "", "new public key-update request JSON")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *pendingFile == "" || *requestFile == "" {
		return errors.New("--pending-file and --request-file are required")
	}
	state, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	request, err := syncstore.CreateJoinRequest(
		*pendingFile, state.DeviceID, state.SeedSigningPublicKey())
	if err != nil {
		return err
	}
	return writeJSONExclusive(*requestFile, request)
}

func cmdKeyUpdateInstall(args []string) error {
	flags := flag.NewFlagSet("key-update-install", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "active join client state")
	pendingFile := flags.String("pending-file", "", "device-local pending X25519 state")
	wrappedFile := flags.String("wrapped-file", "", "d-signed encrypted keyring update")
	var requiredKeyIDs repeatedFlag
	flags.Var(&requiredKeyIDs, "required-key-id", "server-observed key id; repeat for every live epoch")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *pendingFile == "" || *wrappedFile == "" || len(requiredKeyIDs) == 0 {
		return errors.New("--pending-file, --wrapped-file, and at least one --required-key-id are required")
	}
	state, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	var wrapped syncstore.WrappedEnrollment
	if err := readJSONFile(*wrappedFile, &wrapped); err != nil {
		return err
	}
	return state.InstallKeyUpdate(*pendingFile, wrapped, requiredKeyIDs)
}

func cmdRecoveryKeygen(args []string) error {
	flags := flag.NewFlagSet("recovery-keygen", flag.ExitOnError)
	outputDir := flags.String("output-dir", "", "new directory on independently held recovery media")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *outputDir == "" {
		return errors.New("--output-dir is required")
	}
	if err := syncstore.GenerateRecoveryIdentity(*outputDir); err != nil {
		return err
	}
	fmt.Printf("recovery_identity=%s\nrecovery_recipient=%s\n",
		filepath.Join(*outputDir, "identity.txt"),
		filepath.Join(*outputDir, "recipient.txt"))
	return nil
}

func cmdRecoveryExport(args []string) error {
	flags := flag.NewFlagSet("recovery-export", flag.ExitOnError)
	stateFile := flags.String("state-file", defaultClientStatePath(), "d seed client state")
	tokenFile := flags.String("token-file", defaultTokenPath(), "d device credential")
	recipientsFile := flags.String("recipients-file", "", "file containing at least two distinct age recipients")
	output := flags.String("output", "", "new encrypted recovery generation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *recipientsFile == "" || *output == "" {
		return errors.New("--recipients-file and --output are required")
	}
	receipt, err := syncstore.ExportSeedRecovery(
		*stateFile, *tokenFile, *recipientsFile, *output)
	if err != nil {
		return err
	}
	fmt.Printf("recovery_export=%s\nsha256=%s\nrecipient_count=%d\n",
		*output, receipt.SHA256, receipt.RecipientCount)
	return nil
}

func cmdRecoveryImport(args []string) error {
	flags := flag.NewFlagSet("recovery-import", flag.ExitOnError)
	input := flags.String("input", "", "encrypted recovery generation")
	identityFile := flags.String("identity-file", "", "dedicated age identity file")
	expectedSeedPublic := flags.String("expected-seed-public-file", "", "independently authenticated d public key")
	outputDir := flags.String("output-dir", "", "new disposable recovery directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *input == "" || *identityFile == "" || *expectedSeedPublic == "" ||
		*outputDir == "" {
		return errors.New("--input, --identity-file, --expected-seed-public-file, and --output-dir are required")
	}
	receipt, err := syncstore.ImportSeedRecovery(
		*input, *identityFile, *expectedSeedPublic, *outputDir)
	if err != nil {
		return err
	}
	fmt.Printf("recovery_import=%s\ndevice_id=%s\nactive_key_id=%s\n",
		*outputDir, receipt.DeviceID, receipt.ActiveKeyID)
	return nil
}

func cmdTLSCAInit(args []string) error {
	flags := flag.NewFlagSet("tls-ca-init", flag.ExitOnError)
	hostname := flags.String("hostname", "", "exact lm Tailscale .ts.net hostname")
	outputDir := flags.String("output-dir", "", "new offline CA directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *hostname == "" || *outputDir == "" {
		return errors.New("--hostname and --output-dir are required")
	}
	receipt, err := syncstore.CreateTLSCA(*outputDir, *hostname)
	if err != nil {
		return err
	}
	fmt.Printf("ca_sha256=%s\nhostname=%s\nnot_after=%s\n",
		receipt.CAFingerprint, receipt.Hostname,
		receipt.NotAfter.Format(time.RFC3339))
	return nil
}

func cmdTLSServerIssue(args []string) error {
	flags := flag.NewFlagSet("tls-server-issue", flag.ExitOnError)
	caCert := flags.String("ca-cert", "", "offline CA certificate")
	caKey := flags.String("ca-key", "", "offline CA private key")
	hostname := flags.String("hostname", "", "exact lm Tailscale .ts.net hostname")
	address := flags.String("ip", "", "exact lm Tailscale IPv4 address")
	outputDir := flags.String("output-dir", "", "new server leaf directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *caCert == "" || *caKey == "" || *hostname == "" ||
		*address == "" || *outputDir == "" {
		return errors.New("--ca-cert, --ca-key, --hostname, --ip, and --output-dir are required")
	}
	receipt, err := syncstore.IssueTLSServer(
		*caCert, *caKey, *outputDir, *hostname, *address)
	if err != nil {
		return err
	}
	printTLSReceipt(receipt)
	return nil
}

func cmdTLSServerVerify(args []string) error {
	flags := flag.NewFlagSet("tls-server-verify", flag.ExitOnError)
	caCert := flags.String("ca-cert", "", "enrolled CA certificate")
	serverCert := flags.String("server-cert", "", "lm server certificate")
	serverKey := flags.String("server-key", "", "lm server private key")
	hostname := flags.String("hostname", "", "exact lm Tailscale .ts.net hostname")
	address := flags.String("ip", "", "exact lm Tailscale IPv4 address")
	minimumValidity := flags.Duration("minimum-validity", 30*24*time.Hour,
		"required remaining certificate validity")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *caCert == "" || *serverCert == "" || *serverKey == "" ||
		*hostname == "" || *address == "" {
		return errors.New("--ca-cert, --server-cert, --server-key, --hostname, and --ip are required")
	}
	receipt, err := syncstore.VerifyTLSServer(
		*caCert, *serverCert, *serverKey, *hostname, *address, *minimumValidity)
	if err != nil {
		return err
	}
	printTLSReceipt(receipt)
	return nil
}

func printTLSReceipt(receipt syncstore.TLSIdentityReceipt) {
	fmt.Printf("ca_sha256=%s\nserver_sha256=%s\nhostname=%s\nip=%s\nnot_after=%s\n",
		receipt.CAFingerprint, receipt.ServerFingerprint,
		receipt.Hostname, receipt.IP, receipt.NotAfter.Format(time.RFC3339))
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
	if err := registry.EnrollPullOnlyRequest(request); err != nil {
		return err
	}
	fmt.Printf("registry_updated=enroll:%s\ndaemon_restart_required=true\n", request.DeviceID)
	return nil
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
	if err := registry.Revoke(*device); err != nil {
		return err
	}
	fmt.Printf("registry_updated=revoke:%s\ndaemon_restart_required=true\n", *device)
	return nil
}

func cmdEnrollmentComplete(args []string) error {
	flags := flag.NewFlagSet("enrollment-complete", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", ""), "HTTPS daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "per-device credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "pending client E2EE state")
	passwordState := flags.String("password-state", filepath.Join(defaultConfigDir(), "password-state.json"), "browser-verified password state")
	cookieState := flags.String("cookie-state", filepath.Join(defaultConfigDir(), "cookie-state.json"), "browser-verified cookie state")
	profileDir := flags.String("profile-dir", "", "browser profile root, which must be stopped")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *profileDir == "" {
		return errors.New("--profile-dir is required")
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
	cookieSequence, err := readVerifiedSequence(*cookieState,
		cookieBridgeStateSchema)
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

func cmdCredentialActivate(args []string) error {
	flags := flag.NewFlagSet("credential-activate", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", ""), "HTTPS daemon URL")
	stateFile := flags.String("state-file", defaultClientStatePath(), "client E2EE state")
	tokenFile := flags.String("token-file", defaultTokenPath(), "current profile credential")
	newTokenFile := flags.String("new-token-file", "", "staged new credential")
	oldTokenFile := flags.String("old-token-file", "", "new rollback copy of the old credential")
	profileDir := flags.String("profile-dir", "", "browser profile root, which must be stopped")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *newTokenFile == "" || *oldTokenFile == "" || *profileDir == "" {
		return errors.New("--new-token-file, --old-token-file, and --profile-dir are required")
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
		return errors.New("new credential is identical to the installed credential")
	}
	if err := ensureCredentialBackup(*oldTokenFile, currentToken); err != nil {
		return err
	}
	client, err := syncstore.NewClient(*baseURL, newToken, *stateFile)
	if err != nil {
		return err
	}
	if err := client.ConfirmCredential(context.Background()); err != nil {
		return fmt.Errorf("new credential was not accepted and confirmed: %w", err)
	}
	if err := replaceCredentialAtomically(*tokenFile, currentToken, newToken); err != nil {
		return err
	}
	fmt.Printf("credential_activated=%s\nold_credential_backup=%s\n",
		*tokenFile, *oldTokenFile)
	return nil
}

func cmdKeyRekey(args []string) error {
	flags := flag.NewFlagSet("key-rekey", flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", ""), "HTTPS daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "d credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "d seed E2EE state")
	passwordState := flags.String("password-state", filepath.Join(defaultConfigDir(), "password-state.json"), "browser-verified password state")
	cookieState := flags.String("cookie-state", filepath.Join(defaultConfigDir(), "cookie-state.json"), "browser-verified cookie state")
	if err := flags.Parse(args); err != nil {
		return err
	}
	state, err := syncstore.LoadClientState(*stateFile)
	if err != nil {
		return err
	}
	passwordSequence, passwordRevisions, err := readPasswordRevisions(
		*passwordState)
	if err != nil {
		return fmt.Errorf("password rekey readiness: %w", err)
	}
	cookieSequence, cookieRevisions, err := readBrowserRevisions(
		*cookieState, cookieBridgeStateSchema, "records", "remote_revision")
	if err != nil {
		return fmt.Errorf("cookie rekey readiness: %w", err)
	}
	if passwordSequence != cookieSequence ||
		passwordSequence != int64(state.Sequence) {
		return fmt.Errorf("rekey is not ready: password=%d cookie=%d client=%d",
			passwordSequence, cookieSequence, state.Sequence)
	}
	if err := state.ImportBrowserRevisionBaseline(state.Sequence,
		map[syncstore.Kind]map[string]syncstore.Counter{
			syncstore.KindPassword: passwordRevisions,
			syncstore.KindCookie:   cookieRevisions,
		}); err != nil {
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
	return client.RekeyAllLatest(context.Background())
}

func cmdRemoteAction(action string, args []string) error {
	flags := flag.NewFlagSet(action, flag.ExitOnError)
	baseURL := flags.String("url", envOrDefault("HELIUM_SYNC_URL", ""), "HTTPS daemon URL")
	tokenFile := flags.String("token-file", defaultTokenPath(), "current per-device credential file")
	stateFile := flags.String("state-file", defaultClientStatePath(), "client E2EE state")
	newTokenFile := flags.String("new-token-file", "", "new device-local credential for credential-stage")
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
	ctx := context.Background()
	switch action {
	case "key-stage":
		keyID, err := client.StageContentKey(ctx)
		if err == nil {
			fmt.Printf("staged_key_id=%s\n", keyID)
		}
		return err
	case "key-ack-install":
		return client.AcknowledgeStagedKey(ctx)
	case "key-activate":
		return client.ActivateStagedKey(ctx)
	case "key-adopt":
		return client.AdoptServerKeyStatus(ctx)
	case "key-ack-rekey":
		return client.AcknowledgeActiveRekey(ctx)
	case "key-retire":
		return client.RetireContentKey(ctx)
	case "credential-stage":
		if *newTokenFile == "" {
			return errors.New("--new-token-file is required")
		}
		if !filepath.IsAbs(*newTokenFile) {
			return errors.New("--new-token-file must be absolute")
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
		return client.StageCredential(ctx, newToken)
	case "credential-confirm":
		return client.ConfirmCredential(ctx)
	case "credential-retire":
		return client.RetireOldCredential(ctx)
	default:
		return fmt.Errorf("unknown remote action %q", action)
	}
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

func readPrivateSecret(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("credential path must be absolute: %s", path)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", fmt.Errorf("credential must be a regular file with mode 0600 or stricter: %s", path)
	}
	return readSecret(path)
}

func ensureCredentialBackup(path, expected string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("credential backup path must be absolute: %s", path)
	}
	if _, err := os.Lstat(path); err == nil {
		backup, err := readPrivateSecret(path)
		if err != nil {
			return err
		}
		if backup != expected {
			return errors.New("existing credential backup does not match the installed credential")
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
		return errors.New("installed credential changed before atomic activation")
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
		return fmt.Errorf("profile directory must be absolute: %s", profileDir)
	}
	if _, err := os.Lstat(filepath.Join(profileDir, "SingletonLock")); err == nil {
		return errors.New("browser profile still has a SingletonLock; stop the browser first")
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
	if err := installExclusive(tempPath, path); err != nil {
		return fmt.Errorf("install %s without overwrite: %w", path, err)
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func writeExclusive(path string, contents []byte, mode os.FileMode) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("output path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
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
	return nil
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
	if err := json.Unmarshal(state["schema_version"], &schema); err != nil ||
		schema != expectedSchema {
		return 0, fmt.Errorf("expected schema_version %d", expectedSchema)
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

func validateCanonicalPasswordState(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return err
	}
	var identitySchema, migrationStatus string
	if err := json.Unmarshal(root["identity_schema"], &identitySchema); err != nil ||
		identitySchema != "password-form-unique-key-v2" {
		return errors.New("password identity schema is not canonical v2")
	}
	if err := json.Unmarshal(root["migration_status"], &migrationStatus); err != nil ||
		migrationStatus != "complete" {
		return errors.New("password identity migration is incomplete")
	}
	var legacy map[string]json.RawMessage
	if err := json.Unmarshal(root["legacy_credentials"], &legacy); err != nil ||
		len(legacy) != 0 {
		return errors.New("password state retains legacy credentials")
	}
	var credentials map[string]json.RawMessage
	if err := json.Unmarshal(root["credentials"], &credentials); err != nil {
		return errors.New("password credentials are missing or invalid")
	}
	for key, recordRaw := range credentials {
		const prefix = "credential/v2/"
		if !strings.HasPrefix(key, prefix) || len(key) != len(prefix)+64 {
			return fmt.Errorf("password credential key %q is not canonical v2", key)
		}
		if _, err := hex.DecodeString(strings.TrimPrefix(key, prefix)); err != nil {
			return fmt.Errorf("password credential key %q is invalid", key)
		}
		var record map[string]json.RawMessage
		if err := json.Unmarshal(recordRaw, &record); err != nil {
			return fmt.Errorf("password credential state %q is invalid", key)
		}
		if _, pending := record["pending_publication"]; pending {
			return fmt.Errorf("password credential %q has an unresolved publication", key)
		}
		if _, queued := record["queued_mutation"]; queued {
			return fmt.Errorf("password credential %q has an unpublished mutation", key)
		}
	}
	return nil
}

func readPasswordVerifiedSequence(path string) (int64, error) {
	if err := validateCanonicalPasswordState(path); err != nil {
		return 0, err
	}
	return readVerifiedSequence(path, 4)
}

func readPasswordRevisions(path string) (int64, map[string]syncstore.Counter, error) {
	if err := validateCanonicalPasswordState(path); err != nil {
		return 0, nil, err
	}
	return readBrowserRevisions(path, 4, "credentials", "revision")
}

func readBrowserRevisions(path string, expectedSchema int,
	collectionField, revisionField string) (int64, map[string]syncstore.Counter, error) {
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
	if err := json.Unmarshal(root[collectionField], &records); err != nil {
		return 0, nil, fmt.Errorf("%s is missing or invalid", collectionField)
	}
	revisions := make(map[string]syncstore.Counter, len(records))
	for key, recordRaw := range records {
		if strings.TrimSpace(key) == "" {
			return 0, nil, errors.New("browser revision inventory contains an empty key")
		}
		var record map[string]json.RawMessage
		if err := json.Unmarshal(recordRaw, &record); err != nil {
			return 0, nil, fmt.Errorf("browser revision for %q is invalid", key)
		}
		var encoded string
		if err := json.Unmarshal(record[revisionField], &encoded); err != nil {
			return 0, nil, fmt.Errorf("browser revision for %q is missing", key)
		}
		value, err := strconv.ParseInt(encoded, 10, 64)
		if err != nil || value < 0 {
			return 0, nil, fmt.Errorf("browser revision for %q is invalid", key)
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
	fmt.Fprintln(os.Stderr, "usage: helium-sync <seed-init|server-init|server-verify|seed-public|join-request|seed-wrap|join-install|key-update-request|key-update-install|recovery-keygen|recovery-export|recovery-import|tls-ca-init|tls-server-issue|tls-server-verify|server-enroll|server-revoke|enrollment-complete|key-*|credential-*|push|pull|latest> [flags]")
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
