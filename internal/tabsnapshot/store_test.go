package tabsnapshot

import (
	"encoding/json"
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
	if len(restored.Windows) != 1 || len(restored.Windows[0].Tabs) != 2 ||
		!restored.Windows[0].Tabs[0].Pinned || restored.Windows[0].Tabs[0].Group != "work" {
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

func TestCaptureRejectsMalformedOrUnsafeSession(t *testing.T) {
	store := openTestStore(t)
	request := testCapture(time.Now(), false)
	request.Session.Windows[0].Tabs[0].Navigations[0].URL = "javascript:fixture()"
	if _, err := store.Capture(request); err == nil || !strings.Contains(err.Error(), "disallowed URL") {
		t.Fatalf("unsafe URL was not rejected: %v", err)
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
				Tabs: []Tab{
					{
						ID:           "tab-1",
						Pinned:       true,
						Group:        "work",
						CurrentIndex: 1,
						Navigations: []Navigation{
							{URL: "https://fixture.invalid/previous", Title: "Previous"},
							{URL: "https://fixture.invalid/current", Title: "Current"},
						},
					},
					{
						ID:           "tab-2",
						CurrentIndex: 0,
						Navigations:  []Navigation{{URL: "chrome://newtab/"}},
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
