package tabsnapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	disposableRootMarkerFile     = ".helium-tabs-disposable-root-v1"
	disposableRootMarkerContent  = "helium-tabs-disposable-root-v1\n"
	browserProfileMarkerFile     = ".helium-tabs-disposable-browser-profile-v2"
	browserProfileMarkerContent  = "helium-tabs-disposable-browser-profile-v2\n"
	restorePreparedMarkerFile    = ".helium-tabs-restore-prepared-v2"
	restorePreparedMarkerContent = "helium-tabs-restore-state-v2\n"
	restoreInProgressMarkerFile  = ".helium-tabs-restore-in-progress-v2"
	restoreConsumedMarkerFile    = ".helium-tabs-restore-consumed-v2"
	restoreFailedMarkerFile      = ".helium-tabs-restore-failed-v2"
	restoreReceiptFile           = ".helium-tabs-restore-receipt-v2.json"
	browserRestoreManifestFile   = "browser-restore-manifest.json"
	restoreSourceDirectory       = "restore-source"
	preferencesFile              = "Preferences"
	browserRestorePreparedState  = "prepared-not-opened"
)

// ValidateBrowserRestoreState independently validates prepared and native
// post-launch state without opening a browser. Browser-created files are
// intentionally ignored, while the immutable recovery source, manifest,
// state marker, and terminal receipt remain exact and content-bound.
func ValidateBrowserRestoreState(directory string) (BrowserRestoreState, error) {
	if err := requirePrivateDirectory(directory); err != nil {
		return BrowserRestoreState{}, err
	}
	if err := requirePrivateDirectory(filepath.Dir(directory)); err != nil {
		return BrowserRestoreState{}, err
	}
	if err := requireMarker(filepath.Join(filepath.Dir(directory),
		disposableRootMarkerFile), disposableRootMarkerContent); err != nil {
		return BrowserRestoreState{}, err
	}
	if err := requireMarker(filepath.Join(directory, browserProfileMarkerFile),
		browserProfileMarkerContent); err != nil {
		return BrowserRestoreState{}, err
	}

	markers := []string{
		restorePreparedMarkerFile,
		restoreInProgressMarkerFile,
		restoreConsumedMarkerFile,
		restoreFailedMarkerFile,
	}
	selected := ""
	for _, marker := range markers {
		path := filepath.Join(directory, marker)
		if _, err := os.Lstat(path); err == nil {
			if selected != "" {
				return BrowserRestoreState{}, errors.New("multiple browser restore state markers")
			}
			if err := requireMarker(path, restorePreparedMarkerContent); err != nil {
				return BrowserRestoreState{}, err
			}
			selected = marker
		} else if !errors.Is(err, os.ErrNotExist) {
			return BrowserRestoreState{}, err
		}
	}
	if selected == "" {
		return BrowserRestoreState{}, errors.New("missing browser restore state marker")
	}

	sourceDirectory := filepath.Join(directory, restoreSourceDirectory)
	sourceManifest, err := ValidateRestore(sourceDirectory)
	if err != nil {
		return BrowserRestoreState{}, fmt.Errorf("validate browser restore source: %w", err)
	}
	session, err := readRestoredSession(sourceDirectory)
	if err != nil {
		return BrowserRestoreState{}, err
	}
	if err := ValidateSessionForBrowserRestore(session); err != nil {
		return BrowserRestoreState{}, err
	}
	windowCount, tabCount, groupCount := topologyCounts(session)
	manifestPath := filepath.Join(directory, browserRestoreManifestFile)
	if err := requirePrivateRegularFile(manifestPath); err != nil {
		return BrowserRestoreState{}, err
	}
	rawManifest, err := os.ReadFile(manifestPath)
	if err != nil {
		return BrowserRestoreState{}, err
	}
	var manifest BrowserRestoreManifest
	if err := decodeStrictJSON(rawManifest, &manifest); err != nil {
		return BrowserRestoreState{}, err
	}
	emptyPreferences := []byte("{}\n")
	emptyHash := sha256.Sum256(emptyPreferences)
	if manifest.SchemaVersion != BrowserRestoreSchemaVersion ||
		manifest.SourceGeneration != sourceManifest.SourceGeneration ||
		manifest.SourceDevice != sourceManifest.SourceDevice ||
		manifest.SourceProfile != sourceManifest.SourceProfile ||
		manifest.SourceSession != sourceManifest.Session ||
		manifest.Preferences.Size != int64(len(emptyPreferences)) ||
		manifest.Preferences.SHA256 != hex.EncodeToString(emptyHash[:]) ||
		manifest.WindowCount != windowCount || manifest.TabCount != tabCount ||
		manifest.GroupCount != groupCount ||
		manifest.Invocation != BrowserRestoreInvocation ||
		manifest.PreparedAt.IsZero() ||
		manifest.State != browserRestorePreparedState {
		return BrowserRestoreState{}, errors.New("post-launch browser restore manifest mismatch")
	}

	state := BrowserRestoreState{Marker: selected, Manifest: manifest}
	receiptPath := filepath.Join(directory, restoreReceiptFile)
	if _, err := os.Lstat(receiptPath); errors.Is(err, os.ErrNotExist) {
		if selected == restoreConsumedMarkerFile ||
			selected == restoreFailedMarkerFile {
			return BrowserRestoreState{}, errors.New("terminal browser restore state lacks receipt")
		}
		return state, nil
	} else if err != nil {
		return BrowserRestoreState{}, err
	}
	if err := requirePrivateRegularFile(receiptPath); err != nil {
		return BrowserRestoreState{}, err
	}
	rawReceipt, err := os.ReadFile(receiptPath)
	if err != nil {
		return BrowserRestoreState{}, err
	}
	var receipt BrowserRestoreReceipt
	if err := decodeStrictJSON(rawReceipt, &receipt); err != nil {
		return BrowserRestoreState{}, err
	}
	if receipt.SchemaVersion != BrowserRestoreSchemaVersion ||
		receipt.SourceGeneration != manifest.SourceGeneration ||
		receipt.SourceDevice != manifest.SourceDevice ||
		receipt.SourceProfile != manifest.SourceProfile ||
		receipt.SourceSessionSHA256 != manifest.SourceSession.SHA256 ||
		receipt.WindowCount != manifest.WindowCount ||
		receipt.TabCount != manifest.TabCount ||
		receipt.GroupCount != manifest.GroupCount ||
		receipt.CompletedAtUnixMillis == "" {
		return BrowserRestoreState{}, errors.New("browser restore receipt source mismatch")
	}
	if _, err := strconv.ParseInt(receipt.CompletedAtUnixMillis, 10, 64); err != nil {
		return BrowserRestoreState{}, errors.New("invalid browser restore receipt time")
	}
	switch receipt.State {
	case "applied":
		if receipt.ReadbackValidation != "exact-supported-live-topology" ||
			receipt.Error != "" ||
			(selected != restoreInProgressMarkerFile &&
				selected != restoreConsumedMarkerFile) {
			return BrowserRestoreState{}, errors.New("invalid applied browser restore receipt")
		}
	case "failed":
		if receipt.ReadbackValidation != "verified-rollback" ||
			receipt.Error == "" ||
			(selected != restoreInProgressMarkerFile &&
				selected != restoreFailedMarkerFile) {
			return BrowserRestoreState{}, errors.New("invalid failed browser restore receipt")
		}
	default:
		return BrowserRestoreState{}, errors.New("unknown browser restore receipt state")
	}
	state.Receipt = &receipt
	return state, nil
}

// PrepareDisposableBrowserProfile converts a validated neutral restore into a
// new, unopened Chromium user-data directory under an explicitly marked
// disposable root. It preserves the complete neutral topology for a future
// explicit native restore switch; it never launches a browser or accepts an
// existing target.
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
	if err := writeSynced(filepath.Join(temporary, restorePreparedMarkerFile),
		[]byte(restorePreparedMarkerContent), 0600); err != nil {
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
	sourceManifest, err := normalizeRestoredSessionFiles(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("validate staged neutral restore: %w", err)
	}
	session, err := readRestoredSession(restoreSource)
	if err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	if err := ValidateSessionForBrowserRestore(session); err != nil {
		return BrowserRestoreManifest{}, "", fmt.Errorf("prepare browser topology: %w", err)
	}
	preferencesRaw := []byte("{}\n")
	if err := writeSynced(filepath.Join(defaultDirectory, preferencesFile), preferencesRaw, 0600); err != nil {
		return BrowserRestoreManifest{}, "", err
	}
	preferencesHash := sha256.Sum256(preferencesRaw)
	windowCount, tabCount, groupCount := topologyCounts(session)
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
		WindowCount: windowCount,
		TabCount:    tabCount,
		GroupCount:  groupCount,
		Invocation:  BrowserRestoreInvocation,
		PreparedAt:  time.Now().UTC(),
		State:       browserRestorePreparedState,
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
	expected := []string{
		browserProfileMarkerFile,
		restorePreparedMarkerFile,
		"Default",
		browserRestoreManifestFile,
		restoreSourceDirectory,
	}
	sort.Strings(expected)
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
	if err := requireMarker(filepath.Join(directory, restorePreparedMarkerFile), restorePreparedMarkerContent); err != nil {
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
	var preferences map[string]any
	if err := decodeStrictJSON(preferencesRaw, &preferences); err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("decode disposable browser preferences: %w", err)
	}
	if len(preferences) != 0 {
		return BrowserRestoreManifest{}, errors.New("disposable browser preferences must not auto-open tabs")
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
	if err := ValidateSessionForBrowserRestore(session); err != nil {
		return BrowserRestoreManifest{}, fmt.Errorf("validate browser topology: %w", err)
	}
	windowCount, tabCount, groupCount := topologyCounts(session)

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
		manifest.WindowCount != windowCount || manifest.TabCount != tabCount ||
		manifest.GroupCount != groupCount ||
		manifest.Invocation != BrowserRestoreInvocation ||
		manifest.PreparedAt.IsZero() ||
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
	normalized, err := NormalizeSession(session)
	if err != nil {
		return Session{}, err
	}
	return normalized, nil
}

// normalizeRestoredSessionFiles migrates an authenticated neutral restore only
// inside the unopened staging directory. The caller's source restore remains
// untouched, and the updated receipt binds the canonical schema-two bytes.
func normalizeRestoredSessionFiles(directory string) (RestoreManifest, error) {
	manifest, err := ValidateRestore(directory)
	if err != nil {
		return RestoreManifest{}, err
	}
	session, err := readRestoredSession(directory)
	if err != nil {
		return RestoreManifest{}, err
	}
	raw, err := json.MarshalIndent(session, "", "  ")
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("encode normalized neutral restore: %w", err)
	}
	raw = append(raw, '\n')
	sum := sha256.Sum256(raw)
	manifest.Session = FileRecord{
		SHA256: hex.EncodeToString(sum[:]),
		Size:   int64(len(raw)),
	}
	manifestRaw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return RestoreManifest{}, fmt.Errorf("encode normalized restore manifest: %w", err)
	}
	if err := os.Remove(filepath.Join(directory, sessionFile)); err != nil {
		return RestoreManifest{}, fmt.Errorf("replace staged neutral session: %w", err)
	}
	if err := writeSynced(filepath.Join(directory, sessionFile), raw, 0600); err != nil {
		return RestoreManifest{}, err
	}
	if err := os.Remove(filepath.Join(directory, "restore-manifest.json")); err != nil {
		return RestoreManifest{}, fmt.Errorf("replace staged restore manifest: %w", err)
	}
	if err := writeSynced(filepath.Join(directory, "restore-manifest.json"),
		append(manifestRaw, '\n'), 0600); err != nil {
		return RestoreManifest{}, err
	}
	if err := syncDirectory(directory); err != nil {
		return RestoreManifest{}, err
	}
	return ValidateRestore(directory)
}

func topologyCounts(session Session) (int, int, int) {
	windowCount := len(session.Windows)
	tabCount := 0
	groupCount := 0
	for _, window := range session.Windows {
		tabCount += len(window.Tabs)
		groupCount += len(window.Groups)
	}
	return windowCount, tabCount, groupCount
}
