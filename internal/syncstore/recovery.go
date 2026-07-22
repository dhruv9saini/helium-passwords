package syncstore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"filippo.io/age"
)

const (
	seedRecoveryVersion = 1
	maxRecoveryBytes    = 16 * 1024 * 1024
)

type seedRecoveryBundle struct {
	Version     int         `json:"version"`
	CreatedAt   time.Time   `json:"created_at"`
	ClientState ClientState `json:"client_state"`
	Token       string      `json:"token"`
}

type RecoveryExportReceipt struct {
	SHA256         string
	RecipientCount int
}

type RecoveryImportReceipt struct {
	DeviceID          string
	ActiveKeyID       string
	SeedSigningPublic string
}

// GenerateRecoveryIdentity creates one dedicated age identity and its public
// recipient in a new directory. Keeping key generation separate lets an
// operator create each identity directly on independently held recovery media.
func GenerateRecoveryIdentity(outputDir string) error {
	if err := requireAbsolutePath(outputDir); err != nil {
		return err
	}
	identity, err := age.GenerateX25519Identity()
	if err != nil {
		return err
	}
	return installNewDirectory(outputDir, func(root string) error {
		if err := writeSyncedFile(filepath.Join(root, "identity.txt"),
			[]byte(identity.String()+"\n"), 0600); err != nil {
			return err
		}
		return writeSyncedFile(filepath.Join(root, "recipient.txt"),
			[]byte(identity.Recipient().String()+"\n"), 0644)
	})
}

// ExportSeedRecovery age-encrypts d's complete client state and bearer
// credential. At least two distinct recipients are required, and plaintext is
// streamed directly into the encrypted output without a temporary archive.
func ExportSeedRecovery(statePath, tokenPath, recipientsPath, outputPath string) (RecoveryExportReceipt, error) {
	for _, path := range []string{statePath, tokenPath, recipientsPath, outputPath} {
		if err := requireAbsolutePath(path); err != nil {
			return RecoveryExportReceipt{}, err
		}
	}
	stateFile, err := openSecretFile(statePath)
	if err != nil {
		return RecoveryExportReceipt{}, err
	}
	if err := stateFile.Close(); err != nil {
		return RecoveryExportReceipt{}, err
	}
	state, err := LoadClientState(statePath)
	if err != nil {
		return RecoveryExportReceipt{}, err
	}
	if state.Role != RoleSeed || state.DeviceID != "d" || state.Phase != PhaseActive {
		return RecoveryExportReceipt{}, errors.New("recovery export requires active seed state d")
	}
	token, err := readSecretFile(tokenPath)
	if err != nil {
		return RecoveryExportReceipt{}, err
	}
	if _, err := NewServerBootstrap(state, token); err != nil {
		return RecoveryExportReceipt{}, fmt.Errorf("validate seed credential: %w", err)
	}
	recipientsFile, err := os.Open(recipientsPath)
	if err != nil {
		return RecoveryExportReceipt{}, err
	}
	recipients, parseErr := age.ParseRecipients(recipientsFile)
	closeErr := recipientsFile.Close()
	if parseErr != nil {
		return RecoveryExportReceipt{}, fmt.Errorf("parse recovery recipients: %w", parseErr)
	}
	if closeErr != nil {
		return RecoveryExportReceipt{}, closeErr
	}
	unique := make(map[string]struct{}, len(recipients))
	for _, recipient := range recipients {
		unique[fmt.Sprint(recipient)] = struct{}{}
	}
	if len(unique) < 2 {
		return RecoveryExportReceipt{}, errors.New("at least two distinct recovery recipients are required")
	}

	bundle := seedRecoveryBundle{
		Version: seedRecoveryVersion, CreatedAt: time.Now().UTC(),
		ClientState: *state, Token: token,
	}
	if err := writeAgeFileExclusive(outputPath, recipients, bundle); err != nil {
		return RecoveryExportReceipt{}, err
	}
	digest, err := fileSHA256(outputPath)
	if err != nil {
		return RecoveryExportReceipt{}, err
	}
	return RecoveryExportReceipt{SHA256: digest, RecipientCount: len(unique)}, nil
}

// ImportSeedRecovery decrypts and validates a recovery generation into a new
// directory. It never replaces existing state and requires an independently
// authenticated copy of d's signing public key.
func ImportSeedRecovery(inputPath, identityPath, expectedSeedPublicPath, outputDir string) (RecoveryImportReceipt, error) {
	for _, path := range []string{inputPath, identityPath, expectedSeedPublicPath, outputDir} {
		if err := requireAbsolutePath(path); err != nil {
			return RecoveryImportReceipt{}, err
		}
	}
	identitiesFile, err := openSecretFile(identityPath)
	if err != nil {
		return RecoveryImportReceipt{}, err
	}
	identities, parseErr := age.ParseIdentities(identitiesFile)
	closeErr := identitiesFile.Close()
	if parseErr != nil {
		return RecoveryImportReceipt{}, fmt.Errorf("parse recovery identities: %w", parseErr)
	}
	if closeErr != nil {
		return RecoveryImportReceipt{}, closeErr
	}
	encrypted, err := os.Open(inputPath)
	if err != nil {
		return RecoveryImportReceipt{}, err
	}
	plaintext, decryptErr := age.Decrypt(encrypted, identities...)
	if decryptErr != nil {
		encrypted.Close()
		return RecoveryImportReceipt{}, fmt.Errorf("decrypt recovery generation: %w", decryptErr)
	}
	raw, readErr := io.ReadAll(io.LimitReader(plaintext, maxRecoveryBytes+1))
	closeErr = encrypted.Close()
	if readErr != nil {
		return RecoveryImportReceipt{}, fmt.Errorf("read recovery generation: %w", readErr)
	}
	if closeErr != nil {
		return RecoveryImportReceipt{}, closeErr
	}
	if len(raw) > maxRecoveryBytes {
		return RecoveryImportReceipt{}, errors.New("recovery plaintext exceeds size limit")
	}
	var bundle seedRecoveryBundle
	if err := strictDecode(raw, &bundle); err != nil {
		return RecoveryImportReceipt{}, fmt.Errorf("decode recovery generation: %w", err)
	}
	if bundle.Version != seedRecoveryVersion || bundle.CreatedAt.IsZero() {
		return RecoveryImportReceipt{}, errors.New("recovery generation metadata is invalid")
	}
	bundle.ClientState.path = ""
	if err := bundle.ClientState.validate(); err != nil {
		return RecoveryImportReceipt{}, fmt.Errorf("validate recovered client state: %w", err)
	}
	if bundle.ClientState.Role != RoleSeed || bundle.ClientState.DeviceID != "d" ||
		bundle.ClientState.Phase != PhaseActive {
		return RecoveryImportReceipt{}, errors.New("recovery generation is not active seed state d")
	}
	if _, err := NewServerBootstrap(&bundle.ClientState, bundle.Token); err != nil {
		return RecoveryImportReceipt{}, fmt.Errorf("validate recovered credential: %w", err)
	}
	expectedPublic, err := readPublicValue(expectedSeedPublicPath)
	if err != nil {
		return RecoveryImportReceipt{}, err
	}
	if bundle.ClientState.SeedSigningPublic != expectedPublic {
		return RecoveryImportReceipt{}, errors.New("recovered seed does not match the authenticated trust anchor")
	}

	err = installNewDirectory(outputDir, func(root string) error {
		bundle.ClientState.path = filepath.Join(root, "client.json")
		if err := bundle.ClientState.Save(); err != nil {
			return err
		}
		return writeSyncedFile(filepath.Join(root, "token"),
			[]byte(bundle.Token+"\n"), 0600)
	})
	if err != nil {
		return RecoveryImportReceipt{}, err
	}
	return RecoveryImportReceipt{
		DeviceID: "d", ActiveKeyID: bundle.ClientState.ActiveKeyID,
		SeedSigningPublic: bundle.ClientState.SeedSigningPublic,
	}, nil
}

func writeAgeFileExclusive(path string, recipients []age.Recipient, value any) error {
	if _, err := os.Lstat(path); err == nil {
		return fmt.Errorf("refusing to replace existing recovery generation: %s", path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".helium-recovery-*.age")
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
	encrypted, err := age.Encrypt(temp, recipients...)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(encrypted).Encode(value); err != nil {
		_ = encrypted.Close()
		return err
	}
	if err := encrypted.Close(); err != nil {
		return err
	}
	if err := temp.Sync(); err != nil {
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Link(tempPath, path); err != nil {
		return fmt.Errorf("install recovery generation without overwrite: %w", err)
	}
	return syncDirectory(filepath.Dir(path))
}

func installNewDirectory(path string, populate func(string) error) error {
	parent := filepath.Dir(filepath.Clean(path))
	if err := os.MkdirAll(parent, 0700); err != nil {
		return err
	}
	if err := os.Mkdir(path, 0700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("refusing to replace existing recovery directory: %s", path)
		}
		return err
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(path)
		}
	}()
	if err := populate(path); err != nil {
		return err
	}
	if err := syncDirectory(path); err != nil {
		return err
	}
	complete = true
	return syncDirectory(parent)
}

func openSecretFile(path string) (*os.File, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("secret file must be regular and mode 0600 or stricter: %s", path)
	}
	return os.Open(path)
}

func readSecretFile(path string) (string, error) {
	file, err := openSecretFile(path)
	if err != nil {
		return "", err
	}
	raw, readErr := io.ReadAll(io.LimitReader(file, maxRecoveryBytes+1))
	closeErr := file.Close()
	if readErr != nil {
		return "", readErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	value := strings.TrimSpace(string(raw))
	if value == "" || len(raw) > maxRecoveryBytes {
		return "", errors.New("secret file is empty or too large")
	}
	return value, nil
}

func readPublicValue(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return "", errors.New("public trust anchor is empty")
	}
	return value, nil
}

func requireAbsolutePath(path string) error {
	if strings.TrimSpace(path) == "" || !filepath.IsAbs(path) {
		return fmt.Errorf("recovery path must be absolute: %s", path)
	}
	return nil
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
