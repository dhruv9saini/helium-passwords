package sessioncapsule

import (
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func syntheticSession(commands ...byte) []byte {
	raw := make([]byte, 8)
	binary.LittleEndian.PutUint32(raw[:4], sessionFileSignature)
	binary.LittleEndian.PutUint32(raw[4:8], uint32(cleartextSessionVersion))
	for _, command := range commands {
		frame := []byte{0, 0, command}
		binary.LittleEndian.PutUint16(frame[:2], 1)
		raw = append(raw, frame...)
	}
	return raw
}

func fixture(t *testing.T) (*Store, string, string) {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	profile := filepath.Join(root, "profile")
	sessions := filepath.Join(profile, "Default", "Sessions")
	if err := os.MkdirAll(sessions, 0700); err != nil {
		t.Fatal(err)
	}
	for name, commands := range map[string][]byte{
		"Session_100": {1, initialStateMarkerID, 2},
		"Tabs_100":    {3, initialStateMarkerID, 4},
	} {
		if err := os.WriteFile(filepath.Join(sessions, name),
			syntheticSession(commands...), 0600); err != nil {
			t.Fatal(err)
		}
	}
	store, err := Open(filepath.Join(root, "store"))
	if err != nil {
		t.Fatal(err)
	}
	return store, profile, filepath.Join(root, "browser.guard")
}

func TestCaptureValidateRestoreAndCorruption(t *testing.T) {
	store, profile, guard := fixture(t)
	capturedAt := time.Date(2026, 7, 22, 9, 10, 11, 12, time.UTC)
	manifest, err := store.Capture(CaptureRequest{
		ProfileRoot: profile,
		GuardPath:   guard,
		Device:      "d",
		Profile:     "default",
		CapturedAt:  capturedAt,
	})
	if err != nil {
		t.Fatal(err)
	}
	if manifest.ChromiumCommit != pinnedChromiumCommit ||
		manifest.Validation != "stopped-guard-pinned-v150-command-parse" {
		t.Fatalf("missing pinned provenance: %+v", manifest)
	}
	for _, record := range manifest.Files {
		if record.FormatVersion != 3 || record.MarkerCount != 1 ||
			record.CommandCount != 3 {
			t.Fatalf("unexpected semantic record: %+v", record)
		}
	}
	if _, err := store.Validate(manifest.Generation); err != nil {
		t.Fatal(err)
	}

	disposable := filepath.Join(filepath.Dir(profile), "disposable")
	if err := os.Mkdir(disposable, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(disposable, rootMarkerFile),
		[]byte(rootMarkerContent), 0600); err != nil {
		t.Fatal(err)
	}
	destination, err := store.Restore(manifest.Generation, disposable,
		"drill-native-d")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateRestore(destination); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "Default", "Sessions",
		"Tabs_100"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateRestore(destination); err == nil {
		t.Fatal("corrupt native-session restore passed validation")
	}
}

func TestCaptureRefusesHeldGuardUnexpectedInventoryAndEncryptedFormat(t *testing.T) {
	store, profile, guard := fixture(t)
	locked, err := acquireGuard(guard, unix.LOCK_SH)
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.Capture(CaptureRequest{
		ProfileRoot: profile,
		GuardPath:   guard,
		Device:      "d",
		Profile:     "default",
	})
	releaseGuard(locked)
	if err == nil || !strings.Contains(err.Error(), "guard is held") {
		t.Fatalf("capture did not refuse live-browser guard: %v", err)
	}

	extra := filepath.Join(profile, "Default", "Sessions", "not-a-session")
	if err := os.WriteFile(extra, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(CaptureRequest{
		ProfileRoot: profile, GuardPath: guard, Device: "d", Profile: "default",
	}); err == nil {
		t.Fatal("capture accepted unexpected Sessions inventory")
	}
	if err := os.Remove(extra); err != nil {
		t.Fatal(err)
	}

	encrypted := syntheticSession(initialStateMarkerID)
	binary.LittleEndian.PutUint32(encrypted[4:8], 5)
	if err := os.WriteFile(filepath.Join(profile, "Default", "Sessions",
		"Tabs_100"), encrypted, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(CaptureRequest{
		ProfileRoot: profile, GuardPath: guard, Device: "d", Profile: "default",
	}); err == nil || !strings.Contains(err.Error(), "independently restorable") {
		t.Fatalf("encrypted native session did not fail closed: %v", err)
	}
}

func TestRetentionAndQuarantine(t *testing.T) {
	store, profile, guard := fixture(t)
	var generations []string
	for index := 0; index < 10; index++ {
		manifest, err := store.Capture(CaptureRequest{
			ProfileRoot: profile,
			GuardPath:   guard,
			Device:      "da",
			Profile:     "default",
			CapturedAt:  time.Date(2026, 7, 1+index, 1, 2, 3, index, time.UTC),
			Protected:   index == 0,
		})
		if err != nil {
			t.Fatal(err)
		}
		generations = append(generations, manifest.Generation)
	}
	plan, err := store.PlanRetention()
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Delete) != 1 || plan.Delete[0] != generations[1] {
		t.Fatalf("unexpected retention plan: %+v", plan)
	}
	if err := store.ApplyRetention(plan); err != nil {
		t.Fatal(err)
	}
	quarantined, err := store.Quarantine(generations[2], "drill-corrupt")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(quarantined, "drill-corrupt") {
		t.Fatalf("unexpected quarantine destination: %s", quarantined)
	}
}

func TestManifestRejectsUnknownFieldsAndTornCommands(t *testing.T) {
	store, profile, guard := fixture(t)
	manifest, err := store.Capture(CaptureRequest{
		ProfileRoot: profile, GuardPath: guard, Device: "oneplus",
		Profile: "default",
	})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(store.generations, manifest.Generation, manifestFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(raw, &object); err != nil {
		t.Fatal(err)
	}
	object["unknown"] = true
	raw, err = json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Validate(manifest.Generation); err == nil {
		t.Fatal("unknown manifest field passed")
	}

	torn := syntheticSession(1, initialStateMarkerID)
	torn = append(torn, 5, 0, 1)
	if _, err := inspectNativeSession(torn); err == nil {
		t.Fatal("torn command tail passed")
	}
}
