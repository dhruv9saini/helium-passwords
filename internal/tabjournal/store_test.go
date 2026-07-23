package tabjournal

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fixtureCheckpoint(title string) string {
	checkpoint := Checkpoint{
		SchemaVersion: 1,
		Windows: []Window{{
			Index: 0,
			Groups: []Group{{
				ID: "work", Title: "Work", Color: "blue", Collapsed: false,
			}},
			Tabs: []Tab{
				{Index: 0, Active: true, Pinned: true, Group: "",
					URL: "https://one.invalid/", Title: title},
				{Index: 1, Active: false, Pinned: false, Group: "work",
					URL: "https://two.invalid/path?q=1", Title: "Two"},
				{Index: 2, Active: false, Pinned: false, Group: "",
					URL: "file:///tmp/fixture", Title: "Local"},
				{Index: 3, Active: false, Pinned: false, Group: "",
					URL: "javascript:void(0)", Title: "Script history"},
			},
		}},
	}
	raw, _ := json.Marshal(checkpoint)
	return string(raw)
}

func createSegment(t *testing.T, path, epoch string, corruptHash bool) {
	t.Helper()
	events := []Event{
		{
			Epoch: epoch, Sequence: 1, OccurredAtUnixMillis: "1784736000000",
			Kind: "initial-checkpoint", PayloadJSON: fixtureCheckpoint("<one>"),
		},
		{
			Epoch: epoch, Sequence: 2, OccurredAtUnixMillis: "1784736300000",
			Kind: "heartbeat", PayloadJSON: fixtureCheckpoint("One updated"),
		},
	}
	previous := ""
	for index := range events {
		events[index].PreviousSHA256 = previous
		events[index].SHA256 = eventHash(events[index])
		previous = events[index].SHA256
	}
	if corruptHash {
		events[1].SHA256 = strings.Repeat("0", 64)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	schema := `PRAGMA journal_mode=WAL;
CREATE TABLE events(
  epoch TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  occurred_at_unix_millis TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  previous_sha256 TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  PRIMARY KEY(epoch, sequence)
) STRICT;`
	command := exec.Command("sqlite3", path, schema)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("create sqlite: %v: %s", err, output)
	}
	for _, event := range events {
		sql := `INSERT INTO events VALUES(` +
			sqlQuote(event.Epoch) + `,` +
			strconv.FormatInt(event.Sequence, 10) + `,` +
			sqlQuote(event.OccurredAtUnixMillis) + `,` +
			sqlQuote(event.Kind) + `,` +
			sqlQuote(event.PayloadJSON) + `,` +
			sqlQuote(event.PreviousSHA256) + `,` +
			sqlQuote(event.SHA256) + `);`
		if output, err := exec.Command("sqlite3", path, sql).CombinedOutput(); err != nil {
			t.Fatalf("insert sqlite: %v: %s", err, output)
		}
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
}

func sqlQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func createJournalRoot(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, journalMarkerFile),
		[]byte(journalMarker), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestCaptureValidateAndEscapedCatalog(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	journalRoot := filepath.Join(root, "journal")
	createJournalRoot(t, journalRoot)
	createSegment(t, filepath.Join(journalRoot, "active.sqlite"),
		"20260722t120000z-aabbccdd", false)
	store, err := Open(filepath.Join(root, "store"))
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := store.Capture(CaptureRequest{
		JournalRoot: journalRoot,
		Device:      "da",
		Profile:     "default",
		CapturedAt:  time.Date(2026, 7, 22, 16, 10, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Format != "append-only-sqlite-hash-chain" ||
		len(manifest.Segments) != 1 {
		t.Fatalf("unexpected manifest: %+v", manifest)
	}
	if _, err := store.Validate(manifest.Generation); err != nil {
		t.Fatal(err)
	}
	disposable := filepath.Join(root, "disposable")
	if err := os.Mkdir(disposable, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(disposable, rootMarkerFile),
		[]byte(rootMarkerContent), 0600); err != nil {
		t.Fatal(err)
	}
	destination, err := store.RestoreCatalog(manifest.Generation, disposable,
		"drill-journal-da")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ValidateCatalog(destination); err != nil {
		t.Fatal(err)
	}
	catalog, err := os.ReadFile(filepath.Join(destination, catalogFile))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(catalog), "<one>") ||
		!strings.Contains(string(catalog), "One updated") ||
		!strings.Contains(string(catalog), "https://two.invalid/path?q=1") ||
		!strings.Contains(string(catalog), "file:///tmp/fixture") ||
		strings.Contains(string(catalog), `href="javascript:`) ||
		!strings.Contains(string(catalog), "#ZgotmplZ") ||
		!strings.Contains(string(catalog), "Group work: Work (blue)") {
		t.Fatalf("catalog escaping/content failure: %s", catalog)
	}
}

func TestHashChainCorruptionAndUnexpectedInventoryFailClosed(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	journalRoot := filepath.Join(root, "journal")
	createJournalRoot(t, journalRoot)
	createSegment(t, filepath.Join(journalRoot, "active.sqlite"),
		"20260722t120000z-deadbeef", true)
	store, err := Open(filepath.Join(root, "store"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(CaptureRequest{
		JournalRoot: journalRoot, Device: "d", Profile: "default",
	}); err == nil {
		t.Fatal("corrupt hash chain passed capture")
	}
	if err := os.WriteFile(filepath.Join(journalRoot, "unrelated"), []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(CaptureRequest{
		JournalRoot: journalRoot, Device: "d", Profile: "default",
	}); err == nil {
		t.Fatal("unexpected journal root entry passed")
	}
}

func TestClosedAndActiveEpochsRemainIndependentlyRecoverable(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	journalRoot := filepath.Join(root, "journal")
	createJournalRoot(t, journalRoot)
	if err := os.Mkdir(filepath.Join(journalRoot, "closed"), 0700); err != nil {
		t.Fatal(err)
	}
	createSegment(t, filepath.Join(journalRoot, "closed", "first.sqlite"),
		"20260721t120000z-aabbccdd", false)
	createSegment(t, filepath.Join(journalRoot, "active.sqlite"),
		"20260722t120000z-aabbccdd", false)
	store, err := Open(filepath.Join(root, "store"))
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := store.Capture(CaptureRequest{
		JournalRoot: journalRoot, Device: "oneplus", Profile: "default",
		CapturedAt: time.Date(2026, 7, 22, 16, 10, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest.Segments) != 2 {
		t.Fatalf("closed epoch omitted: %+v", manifest.Segments)
	}
	_, selected, _, checkpoint, err := store.LatestCheckpoint(manifest.Generation)
	if err != nil {
		t.Fatal(err)
	}
	if selected != "active.sqlite" || checkpoint.Windows[0].Tabs[0].Title != "One updated" {
		t.Fatalf("wrong latest epoch selected: %s %+v", selected, checkpoint)
	}
}

func TestCaptureRejectsStaleJournal(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	journalRoot := filepath.Join(root, "journal")
	createJournalRoot(t, journalRoot)
	createSegment(t, filepath.Join(journalRoot, "active.sqlite"),
		"20260722t120000z-stale", false)
	store, err := Open(filepath.Join(root, "store"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(CaptureRequest{
		JournalRoot: journalRoot, Device: "d", Profile: "default",
		CapturedAt: time.Date(2026, 7, 22, 17, 0, 0, 0, time.UTC),
	}); err == nil || !strings.Contains(err.Error(), "stale") {
		t.Fatalf("stale native journal passed capture: %v", err)
	}
}
