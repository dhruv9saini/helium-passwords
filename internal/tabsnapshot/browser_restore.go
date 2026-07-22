package tabsnapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	disposableRootMarkerFile    = ".helium-tabs-disposable-root-v1"
	disposableRootMarkerContent = "helium-tabs-disposable-root-v1\n"
	browserProfileMarkerFile    = ".helium-tabs-disposable-browser-profile-v1"
	browserProfileMarkerContent = "helium-tabs-disposable-browser-profile-v1\n"
	browserRestoreManifestFile  = "browser-restore-manifest.json"
	restoreSourceDirectory      = "restore-source"
	preferencesFile             = "Preferences"
	browserRestorePreparedState = "prepared-not-opened"
)

type browserPreferences struct {
	Session browserStartupPreferences `json:"session"`
}

type browserStartupPreferences struct {
	RestoreOnStartup int      `json:"restore_on_startup"`
	StartupURLs      []string `json:"startup_urls"`
}

// PrepareDisposableBrowserProfile converts a validated neutral restore into a
// new, unopened Chromium user-data directory under an explicitly marked
// disposable root. It never launches a browser or accepts an existing target.
func PrepareDisposableBrowserProfile(restoreDirectory, disposableRoot, profile string) (BrowserRestoreManifest, string, error) {
	return prepareDisposableBrowserProfile(restoreDirectory, disposableRoot, profile, nil)
}

func prepareDisposableBrowserProfile(
	restoreDirectory, disposableRoot, profile string,
	afterStage func(string) error,
) (BrowserRestoreManifest, string, error) {
	if !validSlug(profile) || !strings.HasPrefix(profile, "drill-") || profile == "drill-" {
		return BrowserRestoreManifest{}, "", errors.New("disposable profile must be a drill-* slug")
	}
	root, err := validateDisposableBrowserRoot(disposableRoot)
	if err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	destination := filepath.Join(root, profile)
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		if err == nil {
			return BrowserRestoreManifest{}, "", errors.New("disposable browser profile target already exists")
		}
		return BrowserRestoreManifest{}, "", fmt.Errorf("inspect disposable browser profile target: %w", err)
	}
	if _, err := ValidateRestore(restoreDirectory); err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("validate neutral restore: %w", err)
	}

	temporary, err := os.MkdirTemp(root, ".helium-browser-profile-")
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("create browser restore staging directory: %w", err)
	}
	if err := os.Chmod(temporary, 0700); err != nil {
		_ = os.RemoveAll(temporary)
		return BrowserRestoreManifest{}, "", fmt.Errorf("secure browser restore staging directory: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temporary)
		}
	}()

	defaultDirectory := filepath.Join(temporary, "Default")
	restoreSource := filepath.Join(temporary, restoreSourceDirectory)
	for _, directory := range []string{defaultDirectory, restoreSource} {
		if err := os.Mkdir(directory, 0700); err != nil {
			return BrowserRestoreManifest{}, "", fmt.Errorf("create browser restore directory: %w", err)
		}
	}
	if err := writeSynced(filepath.Join(temporary, browserProfileMarkerFile),
		[]byte(browserProfileMarkerContent), 0600); err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	for _, name := range []string{"restore-manifest.json", sessionFile} {
		raw, err := os.ReadFile(filepath.Join(restoreDirectory, name))
		if err != nil {
			return BrowserRestoreManifest{}, "", fmt.Errorf("read neutral restore source: %w", err)
		}
		if err := writeSynced(filepath.Join(restoreSource, name), raw, 0600); err != nil {
			return BrowserRestoreManifest{}, "", err
		}
	}
	sourceManifest, err := ValidateRestore(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("validate staged neutral restore: %w", err)
	}
	session, err := readRestoredSession(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	startupURLs := currentURLs(session)
	preferencesRaw, err := json.MarshalIndent(browserPreferences{
		Session: browserStartupPreferences{RestoreOnStartup: 4, StartupURLs: startupURLs},
	}, "", "  ")
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("encode disposable browser preferences: %w", err)
	}
	preferencesRaw = append(preferencesRaw, '\n')
	if err := writeSynced(filepath.Join(defaultDirectory, preferencesFile), preferencesRaw, 0600); err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	preferencesHash := sha256.Sum256(preferencesRaw)
	manifest := BrowserRestoreManifest{
		SchemaVersion:    BrowserRestoreSchemaVersion,
		SourceGeneration: sourceManifest.SourceGeneration,
		SourceDevice:     sourceManifest.SourceDevice,
		SourceProfile:    sourceManifest.SourceProfile,
		SourceSession:    sourceManifest.Session,
		Preferences: FileRecord{
			SHA256: hex.EncodeToString(preferencesHash[:]),
			Size:   int64(len(preferencesRaw)),
		},
		StartupURLCount: len(startupURLs),
		PreparedAt:      time.Now().UTC(),
		State:           browserRestorePreparedState,
	}
	manifestRaw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("encode browser restore manifest: %w", err)
	}
	if err := writeSynced(filepath.Join(temporary, browserRestoreManifestFile),
		append(manifestRaw, '\n'), 0600); err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	if afterStage != nil {
		if err := afterStage(temporary); err != nil {
			return BrowserRestoreManifest{}, "", err
		}
	}
	if _, err := ValidateDisposableBrowserProfile(temporary); err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("validate staged browser profile: %w", err)
	}
	for _, directory := range []string{defaultDirectory, restoreSource, temporary} {
		if err := syncDirectory(directory); err != nil {
			return BrowserRestoreManifest{}, "", err
		}
	}
	if err := unix.Renameat2(unix.AT_FDCWD, temporary, unix.AT_FDCWD,
		destination, unix.RENAME_NOREPLACE); err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("commit disposable browser profile: %w", err)
	}
	committed = true
	if err := syncDirectory(root); err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	validated, err := ValidateDisposableBrowserProfile(destination)
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("validate committed browser profile: %w", err)
	}
	return validated, destination, nil
}

// ValidateDisposableBrowserProfile validates only a prepared, unopened
// profile. Chromium adds files after first launch, so this is a pre-launch gate.
func ValidateDisposableBrowserProfile(directory string) (BrowserRestoreManifest, error) {
	if err := requirePrivateDirectory(directory); err != nil {
		return BrowserRestoreManifest{}, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("list disposable browser profile: %w", err)
	}
	expected := []string{browserProfileMarkerFile, "Default", browserRestoreManifestFile, restoreSourceDirectory}
	if len(entries) != len(expected) {
		return BrowserRestoreManifest{}, errors.New("invalid disposable browser profile inventory")
	}
	for index, name := range expected {
		if entries[index].Name() != name {
			return BrowserRestoreManifest{}, errors.New("invalid disposable browser profile inventory")
		}
	}
	if err := requireMarker(filepath.Join(directory, browserProfileMarkerFile), browserProfileMarkerContent); err != nil {
		return BrowserRestoreManifest{}, err
	}
	defaultDirectory := filepath.Join(directory, "Default")
	if err := requirePrivateDirectory(defaultDirectory); err != nil {
		return BrowserRestoreManifest{}, err
	}
	defaultEntries, err := os.ReadDir(defaultDirectory)
	if err != nil || len(defaultEntries) != 1 || defaultEntries[0].Name() != preferencesFile {
		return BrowserRestoreManifest{}, errors.New("invalid disposable Default profile inventory")
	}
	preferencesPath := filepath.Join(defaultDirectory, preferencesFile)
	if err := requirePrivateRegularFile(preferencesPath); err != nil {
		return BrowserRestoreManifest{}, err
	}
	preferencesRaw, err := os.ReadFile(preferencesPath)
	if err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("read disposable browser preferences: %w", err)
	}
	var preferences browserPreferences
	if err := decodeStrictJSON(preferencesRaw, &preferences); err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("decode disposable browser preferences: %w", err)
	}
	if preferences.Session.RestoreOnStartup != 4 || len(preferences.Session.StartupURLs) == 0 {
		return BrowserRestoreManifest{}, errors.New("invalid disposable browser startup preferences")
	}

	restoreSource := filepath.Join(directory, restoreSourceDirectory)
	sourceManifest, err := ValidateRestore(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("validate copied neutral restore: %w", err)
	}
	session, err := readRestoredSession(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, err
	}
	expectedURLs := currentURLs(session)
	if len(expectedURLs) != len(preferences.Session.StartupURLs) {
		return BrowserRestoreManifest{}, errors.New("browser startup URL count does not match neutral restore")
	}
	for index := range expectedURLs {
		if expectedURLs[index] != preferences.Session.StartupURLs[index] {
			return BrowserRestoreManifest{}, errors.New("browser startup URLs do not match neutral restore")
		}
	}

	manifestPath := filepath.Join(directory, browserRestoreManifestFile)
	if err := requirePrivateRegularFile(manifestPath); err != nil {
		return BrowserRestoreManifest{}, err
	}
	manifestRaw, err := os.ReadFile(manifestPath)
	if err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("read browser restore manifest: %w", err)
	}
	var manifest BrowserRestoreManifest
	if err := decodeStrictJSON(manifestRaw, &manifest); err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("decode browser restore manifest: %w", err)
	}
	preferencesHash := sha256.Sum256(preferencesRaw)
	if manifest.SchemaVersion != BrowserRestoreSchemaVersion ||
		manifest.SourceGeneration != sourceManifest.SourceGeneration ||
		manifest.SourceDevice != sourceManifest.SourceDevice ||
		manifest.SourceProfile != sourceManifest.SourceProfile ||
		manifest.SourceSession != sourceManifest.Session ||
		manifest.Preferences.Size != int64(len(preferencesRaw)) ||
		manifest.Preferences.SHA256 != hex.EncodeToString(preferencesHash[:]) ||
		manifest.StartupURLCount != len(expectedURLs) || manifest.PreparedAt.IsZero() ||
		manifest.State != browserRestorePreparedState {
		return BrowserRestoreManifest{}, errors.New("browser restore manifest mismatch")
	}
	return manifest, nil
}

func validateDisposableBrowserRoot(root string) (string, error) {
	if strings.TrimSpace(root) == "" {
		return "", errors.New("disposable browser root is required")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("resolve disposable browser root: %w", err)
	}
	if abs == filepath.Clean(string(os.PathSeparator)) {
		return "", errors.New("filesystem root cannot be a disposable browser root")
	}
	if err := requirePrivateDirectory(abs); err != nil {
		return "", err
	}
	if err := requireMarker(filepath.Join(abs, disposableRootMarkerFile), disposableRootMarkerContent); err != nil {
		return "", fmt.Errorf("validate disposable browser root marker: %w", err)
	}
	return abs, nil
}

func requireMarker(path, expected string) error {
	if err := requirePrivateRegularFile(path); err != nil {
		return err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read disposable marker: %w", err)
	}
	if string(raw) != expected {
		return errors.New("invalid disposable marker")
	}
	return nil
}

func readRestoredSession(directory string) (Session, error) {
	raw, err := os.ReadFile(filepath.Join(directory, sessionFile))
	if err != nil {
		return Session{}, fmt.Errorf("read neutral restore session: %w", err)
	}
	var session Session
	if err := decodeStrictJSON(raw, &session); err != nil {
		return Session{}, fmt.Errorf("decode neutral restore session: %w", err)
	}
	if err := ValidateSession(session); err != nil {
		return Session{}, err
	}
	return session, nil
}

func currentURLs(session Session) []string {
	urls := make([]string, 0)
	for _, window := range session.Windows {
		for _, tab := range window.Tabs {
			urls = append(urls, tab.Navigations[tab.CurrentIndex].URL)
		}
	}
	return urls
}
