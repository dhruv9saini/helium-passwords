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
	"testing"
	"time"
)

func TestCaptureCommitsHashValidAtomicGeneration(t *testing.T) {
	store := openTestStore(t)
	manifest, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	validated, err := store.Validate(manifest.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if validated.Files[sessionFile].SHA256 == "" || validated.Files[sessionFile].Size == 0 {
		t.Fatal("validated generation has no session hash inventory")
	}
	entries, err := os.ReadDir(store.generations)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".tmp-") {
			t.Fatalf("temporary generation remained after commit: %s", entry.Name())
		}
	}
}

func TestOpenRejectsFilesystemRootAndStoreSymlink(t *testing.T) {
	if _, err := Open(string(os.PathSeparator)); err == nil {
		t.Fatal("filesystem root was accepted as a snapshot store")
	}
	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.Mkdir(target, 0755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "store-link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(link); err == nil || !strings.Contains(err.Error(), "non-symlink directory") {
		t.Fatalf("symlinked snapshot store was accepted: %v", err)
	}
	info, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0755 {
		t.Fatalf("rejected symlink target permissions changed to %o", info.Mode().Perm())
	}
}

func TestCorruptNewestRefusesRetentionAndPreservesPrevious(t *testing.T) {
	store := openTestStore(t)
	first, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.Capture(testCapture(time.Date(2026, 7, 21, 13, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.generations, second.Generation, sessionFile)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("corruption"); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Validate(second.Generation); err == nil {
		t.Fatal("corrupt generation unexpectedly validated")
	}
	if _, err := store.PlanRetention(); err == nil || !strings.Contains(err.Error(), "newest generation is invalid") {
		t.Fatalf("retention did not fail closed: %v", err)
	}
	if _, err := store.Validate(first.Generation); err != nil {
		t.Fatalf("previous generation was not preserved: %v", err)
	}
}

func TestMalformedNewestManifestAlsoRefusesRetention(t *testing.T) {
	store := openTestStore(t)
	if _, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false)); err != nil {
		t.Fatal(err)
	}
	newest, err := store.Capture(testCapture(time.Date(2026, 7, 21, 13, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(store.generations, newest.Generation, manifestFile)
	if err := os.WriteFile(manifestPath, []byte("not-json\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.PlanRetention(); err == nil || !strings.Contains(err.Error(), "newest generation is invalid") {
		t.Fatalf("malformed newest manifest did not stop retention: %v", err)
	}
}

func TestValidationRejectsExtraAndSymlinkedGenerationFiles(t *testing.T) {
	store := openTestStore(t)
	manifest, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(store.generations, manifest.Generation)
	extra := filepath.Join(directory, "unexpected")
	if err := os.WriteFile(extra, []byte("not part of the generation\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Validate(manifest.Generation); err == nil ||
		!strings.Contains(err.Error(), "file inventory") {
		t.Fatalf("extra generation file was accepted: %v", err)
	}
	if err := os.Remove(extra); err != nil {
		t.Fatal(err)
	}
	session := filepath.Join(directory, sessionFile)
	outside := filepath.Join(t.TempDir(), "outside-session.json")
	raw, err := os.ReadFile(session)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(outside, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(session); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, session); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Validate(manifest.Generation); err == nil ||
		!strings.Contains(err.Error(), "non-symlink regular file") {
		t.Fatalf("symlinked generation file was accepted: %v", err)
	}
}

func TestQuarantinePreservesCorruptGenerationAndUnblocksRetention(t *testing.T) {
	store := openTestStore(t)
	previous, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	suspect, err := store.Capture(testCapture(time.Date(2026, 7, 21, 13, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	suspectSession := filepath.Join(store.generations, suspect.Generation, sessionFile)
	if err := os.WriteFile(suspectSession, []byte("corrupt but preserved\n"), 0600); err != nil {
		t.Fatal(err)
	}
	quarantined, err := store.Quarantine(suspect.Generation, "checksum-mismatch")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(quarantined, sessionFile)); err != nil {
		t.Fatalf("quarantined bytes were not preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(store.generations, suspect.Generation)); !os.IsNotExist(err) {
		t.Fatalf("suspect generation remained active: %v", err)
	}
	if _, err := store.Validate(previous.Generation); err != nil {
		t.Fatalf("previous known-good generation was damaged: %v", err)
	}
	if _, err := store.PlanRetention(); err != nil {
		t.Fatalf("explicit quarantine did not unblock retention: %v", err)
	}
	if _, err := store.Quarantine(previous.Generation, "Bad Reason"); err == nil {
		t.Fatal("unsafe quarantine reason was accepted")
	}
}

func TestRetentionKeepsProtectedAndNeverDeletesLastValidGeneration(t *testing.T) {
	store := openTestStore(t)
	capturedAt := time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)
	protected, err := store.Capture(testCapture(capturedAt.Add(-time.Second), true))
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index < 5; index++ {
		if _, err := store.Capture(testCapture(capturedAt.Add(time.Duration(index)*time.Nanosecond), false)); err != nil {
			t.Fatal(err)
		}
	}
	plan, err := store.PlanRetention()
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Delete) == 0 {
		t.Fatal("expected superseded same-bucket generations in deletion plan")
	}
	if contains(plan.Delete, protected.Generation) {
		t.Fatal("protected generation was selected for deletion")
	}
	if err := store.ApplyRetention(plan); err != nil {
		t.Fatal(err)
	}
	items, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	valid := 0
	for _, item := range items {
		if item.Valid {
			valid++
		}
	}
	if valid == 0 {
		t.Fatal("retention removed every valid generation")
	}
	if _, err := store.Validate(protected.Generation); err != nil {
		t.Fatalf("protected generation was not retained: %v", err)
	}
}

func TestRetentionBucketLimitsAreExact(t *testing.T) {
	newest := time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)
	items := make([]Generation, 0, 120*24)
	for hoursAgo := 0; hoursAgo < 120*24; hoursAgo++ {
		captured := newest.Add(-time.Duration(hoursAgo) * time.Hour)
		items = append(items, Generation{
			Manifest: Manifest{
				Generation: fmt.Sprintf("generation-%04d", hoursAgo),
				CapturedAt: captured,
			},
			Valid: true,
		})
	}
	tests := []struct {
		name   string
		limit  int
		bucket func(time.Time) string
	}{
		{"hourly", 24, func(value time.Time) string { return value.UTC().Format("2006-01-02T15") }},
		{"daily", 14, func(value time.Time) string { return value.UTC().Format("2006-01-02") }},
		{"weekly", 12, func(value time.Time) string {
			year, week := value.UTC().ISOWeek()
			return fmt.Sprintf("%04d-W%02d", year, week)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			keep := make(map[string]struct{})
			selectBuckets(items, keep, test.limit, test.bucket)
			if len(keep) != test.limit {
				t.Fatalf("selected %d buckets, want %d", len(keep), test.limit)
			}
		})
	}
}

func TestRestoreTargetsNewDisposableState(t *testing.T) {
	store := openTestStore(t)
	manifest, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "disposable-state")
	if err := store.Restore(manifest.Generation, destination); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(destination, sessionFile))
	if err != nil {
		t.Fatal(err)
	}
	var restored Session
	if err := json.Unmarshal(raw, &restored); err != nil {
		t.Fatal(err)
	}
	if err := ValidateSession(restored); err != nil {
		t.Fatalf("restored session failed validation: %v", err)
	}
	receipt, err := ValidateRestore(destination)
	if err != nil {
		t.Fatalf("standalone restore validation failed: %v", err)
	}
	if receipt.SourceGeneration != manifest.Generation ||
		receipt.SourceDevice != manifest.Device || receipt.SourceProfile != manifest.Profile ||
		receipt.Session.SHA256 != manifest.Files[sessionFile].SHA256 {
		t.Fatal("restore receipt does not bind the source generation and session")
	}
	if len(restored.Windows) != 1 || len(restored.Windows[0].Tabs) != 2 ||
		!restored.Windows[0].Tabs[0].Pinned || restored.Windows[0].Tabs[0].Group != "" ||
		restored.Windows[0].Tabs[1].Group != "work" ||
		restored.Windows[0].Groups[0].Title != "Work" ||
		restored.Windows[0].Groups[0].Color != "blue" ||
		!restored.Windows[0].Groups[0].Collapsed {
		t.Fatal("representative window/tab state was not restored")
	}
	if err := store.Restore(manifest.Generation, destination); err == nil {
		t.Fatal("restore overwrote an existing destination")
	}
	insideStore := filepath.Join(store.root, "disposable-state")
	if err := store.Restore(manifest.Generation, insideStore); err == nil {
		t.Fatal("restore created disposable state inside the snapshot store")
	}
}

func TestValidateRestoreRejectsCorruptionAndExtraFiles(t *testing.T) {
	store := openTestStore(t)
	manifest, err := store.Capture(testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "disposable-state")
	if err := store.Restore(manifest.Generation, destination); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "unexpected"), []byte("extra\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateRestore(destination); err == nil ||
		!strings.Contains(err.Error(), "file inventory") {
		t.Fatalf("extra restore file was accepted: %v", err)
	}
	if err := os.Remove(filepath.Join(destination, "unexpected")); err != nil {
		t.Fatal(err)
	}
	sessionPath := filepath.Join(destination, sessionFile)
	file, err := os.OpenFile(sessionPath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("corruption"); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateRestore(destination); err == nil ||
		!strings.Contains(err.Error(), "size mismatch") {
		t.Fatalf("corrupt restored session was accepted: %v", err)
	}
}

func TestPrepareDisposableBrowserProfileConsumesValidatedNeutralRestore(t *testing.T) {
	restoreDirectory := createTestRestore(t)
	root := markedDisposableRoot(t)

	manifest, destination, err := PrepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-fixture")
	if err != nil {
		t.Fatal(err)
	}
	if destination != filepath.Join(root, "drill-fixture") ||
		manifest.State != browserRestorePreparedState ||
		manifest.WindowCount != 1 || manifest.TabCount != 2 || manifest.GroupCount != 1 ||
		manifest.Invocation != BrowserRestoreInvocation {
		t.Fatalf("unexpected browser restore result: %#v %q", manifest, destination)
	}
	validated, err := ValidateDisposableBrowserProfile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if validated != manifest {
		t.Fatal("committed browser restore manifest changed during validation")
	}
	preferencesRaw, err := os.ReadFile(filepath.Join(destination, "Default", preferencesFile))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(preferencesRaw), "exited_cleanly") ||
		strings.Contains(string(preferencesRaw), "exit_type") {
		t.Fatal("disposable restore forged Chromium clean-exit state")
	}
	var preferences map[string]any
	if err := json.Unmarshal(preferencesRaw, &preferences); err != nil {
		t.Fatal(err)
	}
	if len(preferences) != 0 {
		t.Fatalf("preferences would auto-open tabs: %v", preferences)
	}
	if raw, err := os.ReadFile(filepath.Join(destination, restorePreparedMarkerFile)); err != nil ||
		string(raw) != restorePreparedMarkerContent {
		t.Fatalf("prepared restore marker = %q %v", raw, err)
	}
	prepared, err := readRestoredSession(filepath.Join(destination, restoreSourceDirectory))
	if err != nil {
		t.Fatal(err)
	}
	window := prepared.Windows[0]
	if window.ActiveIndex != 1 || len(window.Groups) != 1 ||
		window.Groups[0].ID != "work" || window.Groups[0].Title != "Work" ||
		window.Groups[0].Color != "blue" || !window.Groups[0].Collapsed ||
		len(window.Tabs) != 2 || !window.Tabs[0].Pinned ||
		window.Tabs[1].Group != "work" ||
		window.Tabs[0].CurrentIndex != 1 ||
		len(window.Tabs[0].Navigations) != 2 {
		t.Fatalf("prepared browser source lost local topology: %#v", prepared)
	}
	if _, err := ValidateRestore(restoreDirectory); err != nil {
		t.Fatalf("neutral restore source changed: %v", err)
	}
}

func TestPostLaunchStateBindsTerminalReceiptToPreparedSource(t *testing.T) {
	restoreDirectory := createTestRestore(t)
	root := markedDisposableRoot(t)
	manifest, destination, err := PrepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-post-launch")
	if err != nil {
		t.Fatal(err)
	}
	state, err := ValidateBrowserRestoreState(destination)
	if err != nil || state.Marker != restorePreparedMarkerFile ||
		state.Receipt != nil {
		t.Fatalf("prepared state invalid: %#v %v", state, err)
	}
	if err := os.Rename(
		filepath.Join(destination, restorePreparedMarkerFile),
		filepath.Join(destination, restoreConsumedMarkerFile)); err != nil {
		t.Fatal(err)
	}
	receipt := BrowserRestoreReceipt{
		SchemaVersion:         BrowserRestoreSchemaVersion,
		State:                 "applied",
		SourceGeneration:      manifest.SourceGeneration,
		SourceDevice:          manifest.SourceDevice,
		SourceProfile:         manifest.SourceProfile,
		SourceSessionSHA256:   manifest.SourceSession.SHA256,
		WindowCount:           manifest.WindowCount,
		TabCount:              manifest.TabCount,
		GroupCount:            manifest.GroupCount,
		ReadbackValidation:    "exact-supported-live-topology",
		CompletedAtUnixMillis: "1784736000000",
		Error:                 "",
	}
	raw, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, restoreReceiptFile),
		append(raw, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	state, err = ValidateBrowserRestoreState(destination)
	if err != nil || state.Marker != restoreConsumedMarkerFile ||
		state.Receipt == nil || state.Receipt.State != "applied" {
		t.Fatalf("consumed state invalid: %#v %v", state, err)
	}
	receipt.SourceGeneration += "-stale"
	raw, _ = json.Marshal(receipt)
	if err := os.WriteFile(filepath.Join(destination, restoreReceiptFile),
		raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateBrowserRestoreState(destination); err == nil {
		t.Fatal("stale terminal receipt passed source binding")
	}
}

func TestDisposableBrowserProfileRequiresMarkerAndNewTarget(t *testing.T) {
	restoreDirectory := createTestRestore(t)

	unmarked := t.TempDir()
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, unmarked, "drill-unmarked"); err == nil {
		t.Fatal("unmarked disposable root was accepted")
	}
	wrongMarker := t.TempDir()
	if err := os.WriteFile(filepath.Join(wrongMarker, disposableRootMarkerFile),
		[]byte("wrong\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, wrongMarker, "drill-wrong-marker"); err == nil {
		t.Fatal("wrong disposable root marker was accepted")
	}
	symlinkMarker := t.TempDir()
	markerTarget := filepath.Join(t.TempDir(), "marker")
	if err := os.WriteFile(markerTarget, []byte(disposableRootMarkerContent), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(markerTarget, filepath.Join(symlinkMarker, disposableRootMarkerFile)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, symlinkMarker, "drill-symlink-marker"); err == nil {
		t.Fatal("symlinked disposable root marker was accepted")
	}
	root := markedDisposableRoot(t)
	existing := filepath.Join(root, "drill-existing")
	if err := os.Mkdir(existing, 0700); err != nil {
		t.Fatal(err)
	}
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-existing"); err == nil {
		t.Fatal("existing empty browser target was accepted")
	}
	entries, err := os.ReadDir(existing)
	if err != nil || len(entries) != 0 {
		t.Fatal("rejected existing browser target was modified")
	}
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, root, "default"); err == nil {
		t.Fatal("non-drill profile name was accepted")
	}
}

func TestDisposableBrowserProfileRejectsUnrecoverableLegacyGroupMetadata(t *testing.T) {
	store := openTestStore(t)
	request := testCapture(time.Now(), false)
	request.Session.SchemaVersion = LegacySessionSchemaVersion
	request.Session.Windows[0].Groups = nil
	for index := range request.Session.Windows[0].Tabs {
		request.Session.Windows[0].Tabs[index].HistoryState = ""
	}
	manifest, err := store.Capture(request)
	if err != nil {
		t.Fatal(err)
	}
	restoreDirectory := filepath.Join(t.TempDir(), "legacy-neutral-restore")
	if err := store.Restore(manifest.Generation, restoreDirectory); err != nil {
		t.Fatal(err)
	}
	root := markedDisposableRoot(t)
	if _, _, err := PrepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-legacy-group"); err == nil ||
		!strings.Contains(err.Error(), "lacks restorable visual metadata") {
		t.Fatalf("legacy group metadata was not rejected: %v", err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != disposableRootMarkerFile {
		t.Fatalf("rejected legacy restore left staging data: %v", entries)
	}
}

func TestDisposableBrowserProfileRollsBackFailedStaging(t *testing.T) {
	restoreDirectory := createTestRestore(t)
	root := markedDisposableRoot(t)
	injected := errors.New("injected staging failure")
	_, _, err := prepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-rollback", func(string) error { return injected })
	if !errors.Is(err, injected) {
		t.Fatalf("staging failure = %v, want injected failure", err)
	}
	if _, err := os.Lstat(filepath.Join(root, "drill-rollback")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed staging published a target: %v", err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != disposableRootMarkerFile {
		t.Fatalf("failed staging left temporary data: %v", entries)
	}
}

func TestDisposableBrowserProfileNeverReplacesConcurrentTarget(t *testing.T) {
	restoreDirectory := createTestRestore(t)
	root := markedDisposableRoot(t)
	destination := filepath.Join(root, "drill-race")
	_, _, err := prepareDisposableBrowserProfile(
		restoreDirectory, root, "drill-race", func(string) error {
			if err := os.Mkdir(destination, 0700); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(destination, "sentinel"), []byte("keep\n"), 0600)
		})
	if err == nil {
		t.Fatal("concurrently created browser target was replaced")
	}
	raw, readErr := os.ReadFile(filepath.Join(destination, "sentinel"))
	if readErr != nil || string(raw) != "keep\n" {
		t.Fatalf("concurrent target changed: %q %v", raw, readErr)
	}
	entries, readErr := os.ReadDir(root)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(entries) != 2 {
		t.Fatalf("failed no-replace commit left staging data: %v", entries)
	}
}

func TestCapturePreservesValidNonHTTPBrowserURLs(t *testing.T) {
	store := openTestStore(t)
	request := testCapture(time.Now(), false)
	for _, browserURL := range []string{
		"chrome-native://newtab/", "file:///tmp/fixture",
		"chrome-extension://abcdefghijklmnop/page.html",
		"devtools://devtools/bundled/inspector.html", "data:text/plain,fixture",
		"javascript:void(0)",
	} {
		request.Session.Windows[0].Tabs[0].Navigations[0].URL = browserURL
		if _, err := store.Capture(request); err != nil {
			t.Fatalf("valid browser URL %q was not preserved: %v", browserURL, err)
		}
	}
}

func TestCaptureMigratesSchemaOneWithoutInventingTopologyMetadata(t *testing.T) {
	store := openTestStore(t)
	request := testCapture(time.Now(), false)
	request.Session.SchemaVersion = LegacySessionSchemaVersion
	request.Session.Windows[0].Groups = nil
	for index := range request.Session.Windows[0].Tabs {
		request.Session.Windows[0].Tabs[index].HistoryState = ""
	}
	manifest, err := store.Capture(request)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(store.generations, manifest.Generation, sessionFile))
	if err != nil {
		t.Fatal(err)
	}
	var migrated Session
	if err := decodeStrictJSON(raw, &migrated); err != nil {
		t.Fatal(err)
	}
	if migrated.SchemaVersion != SessionSchemaVersion ||
		migrated.Windows[0].Tabs[0].HistoryState != HistoryLegacyBounded ||
		migrated.Windows[0].Tabs[1].HistoryState != HistoryLegacyBounded {
		t.Fatalf("schema-one navigation provenance was not preserved: %#v", migrated)
	}
	group := migrated.Windows[0].Groups[0]
	if group.ID != "work" || group.MetadataState != GroupMetadataLegacyUnavailable ||
		group.Title != "" || group.Color != "" || group.Collapsed {
		t.Fatalf("schema-one migration invented group metadata: %#v", group)
	}
	if err := ValidateSessionForBrowserRestore(migrated); err == nil ||
		!strings.Contains(err.Error(), "lacks restorable visual metadata") {
		t.Fatalf("legacy group was accepted for browser restore: %v", err)
	}
}

func TestHistoricalSchemaOneGenerationRestoresAsSchemaTwo(t *testing.T) {
	store := openTestStore(t)
	capture := testCapture(time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false)
	manifest, err := store.Capture(capture)
	if err != nil {
		t.Fatal(err)
	}
	legacy := capture.Session
	legacy.SchemaVersion = LegacySessionSchemaVersion
	legacy.Windows[0].Groups = nil
	for index := range legacy.Windows[0].Tabs {
		legacy.Windows[0].Tabs[index].HistoryState = ""
	}
	raw, err := json.MarshalIndent(legacy, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	raw = append(raw, '\n')
	sum := sha256.Sum256(raw)
	manifest.Files[sessionFile] = FileRecord{
		SHA256: hex.EncodeToString(sum[:]),
		Size:   int64(len(raw)),
	}
	manifestRaw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	generationDirectory := filepath.Join(store.generations, manifest.Generation)
	if err := os.WriteFile(filepath.Join(generationDirectory, sessionFile), raw, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(generationDirectory, manifestFile),
		append(manifestRaw, '\n'), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Validate(manifest.Generation); err != nil {
		t.Fatalf("historical schema-one generation did not validate through migration: %v", err)
	}
	destination := filepath.Join(t.TempDir(), "historical-restore")
	if err := store.Restore(manifest.Generation, destination); err != nil {
		t.Fatal(err)
	}
	restored, err := readRestoredSession(destination)
	if err != nil {
		t.Fatal(err)
	}
	if restored.SchemaVersion != SessionSchemaVersion ||
		restored.Windows[0].Groups[0].MetadataState != GroupMetadataLegacyUnavailable {
		t.Fatalf("historical restore was not migrated explicitly: %#v", restored)
	}
	if _, err := ValidateRestore(destination); err != nil {
		t.Fatalf("migrated neutral restore failed receipt validation: %v", err)
	}
}

func TestSchemaTwoTopologyValidationFailsClosed(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Session)
		want string
	}{
		{
			name: "pinned-and-grouped",
			edit: func(session *Session) {
				session.Windows[0].Tabs[0].Group = "work"
			},
			want: "both pinned and grouped",
		},
		{
			name: "unknown-group-color",
			edit: func(session *Session) {
				session.Windows[0].Groups[0].Color = "ultraviolet"
			},
			want: "invalid visual metadata",
		},
		{
			name: "unknown-history-state",
			edit: func(session *Session) {
				session.Windows[0].Tabs[0].HistoryState = "maybe"
			},
			want: "unsupported history state",
		},
		{
			name: "group-not-contiguous",
			edit: func(session *Session) {
				window := &session.Windows[0]
				window.Tabs = append(window.Tabs, Tab{
					ID:           "tab-3",
					HistoryState: HistoryBounded,
					Navigations:  []Navigation{{URL: "https://fixture.invalid/middle", Title: ""}},
				}, Tab{
					ID:           "tab-4",
					Group:        "work",
					HistoryState: HistoryBounded,
					Navigations:  []Navigation{{URL: "https://fixture.invalid/last", Title: ""}},
				})
			},
			want: "not contiguous",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			session := testCapture(time.Now(), false).Session
			test.edit(&session)
			if err := ValidateSession(session); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validation error = %v, want %q", err, test.want)
			}
		})
	}
}

func openTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "snapshots"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func createTestRestore(t *testing.T) string {
	t.Helper()
	store := openTestStore(t)
	manifest, err := store.Capture(testCapture(
		time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC), false))
	if err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "neutral-restore")
	if err := store.Restore(manifest.Generation, destination); err != nil {
		t.Fatal(err)
	}
	return destination
}

func markedDisposableRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, disposableRootMarkerFile),
		[]byte(disposableRootMarkerContent), 0600); err != nil {
		t.Fatal(err)
	}
	return root
}

func testCapture(capturedAt time.Time, protected bool) CaptureRequest {
	return CaptureRequest{
		Device:          "fixture-device",
		Profile:         "fixture-profile",
		BrowserVersion:  "Helium Sync fixture",
		ChromiumVersion: "fixture-chromium",
		Reason:          "test",
		CapturedAt:      capturedAt,
		Protected:       protected,
		Session: Session{
			SchemaVersion: SchemaVersion,
			Windows: []Window{{
				ID:          "window-1",
				ActiveIndex: 1,
				Groups: []Group{{
					ID:            "work",
					Title:         "Work",
					Color:         "blue",
					Collapsed:     true,
					MetadataState: GroupMetadataComplete,
				}},
				Tabs: []Tab{
					{
						ID:           "tab-1",
						Pinned:       true,
						HistoryState: HistoryBounded,
						CurrentIndex: 1,
						Navigations: []Navigation{
							{URL: "https://fixture.invalid/previous", Title: "Previous"},
							{URL: "https://fixture.invalid/current", Title: "Current"},
						},
					},
					{
						ID:           "tab-2",
						Group:        "work",
						HistoryState: HistoryBounded,
						CurrentIndex: 0,
						Navigations:  []Navigation{{URL: "chrome://newtab/", Title: ""}},
					},
				},
			}},
		},
	}
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
