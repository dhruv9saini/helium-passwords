package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteJSONExclusivePublishesCompleteFileWithoutOverwrite(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "request.json")
	want := map[string]string{"device_id": "oneplus"}
	if err := writeJSONExclusive(path, want); err != nil {
		t.Fatal(err)
	}
	var got map[string]string
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got["device_id"] != want["device_id"] {
		t.Fatalf("published wrong JSON: %v", got)
	}
	if err := writeJSONExclusive(path, map[string]string{"device_id": "da"}); err == nil {
		t.Fatal("exclusive JSON publish replaced an existing file")
	}
	rawAfter, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(rawAfter) != string(raw) {
		t.Fatal("failed exclusive publish changed the existing file")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) {
		t.Fatalf("temporary publish files remain: %v", entries)
	}
}

func TestCredentialActivationPreservesRollbackAndReplacesAtomically(t *testing.T) {
	root := t.TempDir()
	currentPath := filepath.Join(root, "profile", "Default", "helium-sync", "token")
	newPath := filepath.Join(root, "staged", "token.new")
	oldPath := filepath.Join(root, "rollback", "token.old")
	if err := os.MkdirAll(filepath.Dir(currentPath), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(newPath), 0700); err != nil {
		t.Fatal(err)
	}
	oldToken := strings.Repeat("o", 40)
	newToken := strings.Repeat("n", 40)
	if err := os.WriteFile(currentPath, []byte(oldToken+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(newPath, []byte(newToken+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := ensureCredentialBackup(oldPath, oldToken); err != nil {
		t.Fatal(err)
	}
	if err := ensureCredentialBackup(oldPath, oldToken); err != nil {
		t.Fatalf("matching rollback copy was not resumable: %v", err)
	}
	if err := replaceCredentialAtomically(currentPath, oldToken, newToken); err != nil {
		t.Fatal(err)
	}
	installed, _ := readPrivateSecret(currentPath)
	rollback, _ := readPrivateSecret(oldPath)
	if installed != newToken || rollback != oldToken {
		t.Fatal("credential activation lost the new or rollback credential")
	}
	if err := replaceCredentialAtomically(currentPath, oldToken, "third"); err == nil {
		t.Fatal("credential activation overwrote an unexpectedly changed token")
	}
}

func TestCredentialActivationRequiresStoppedAbsoluteProfile(t *testing.T) {
	profile := filepath.Join(t.TempDir(), "profile")
	if err := os.MkdirAll(profile, 0700); err != nil {
		t.Fatal(err)
	}
	if err := requireStoppedProfile(profile); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profile, "SingletonLock"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := requireStoppedProfile(profile); err == nil {
		t.Fatal("locked browser profile was accepted")
	}
	if err := requireStoppedProfile("relative-profile"); err == nil {
		t.Fatal("relative browser profile path was accepted")
	}
}

func TestReadBrowserRevisionsRequiresSchemaCursorAndStringRevisions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "password-state.json")
	raw := `{
  "schema_version": 3,
  "verified_sequence": "19",
  "credentials": {
    "record-a": {"revision": "4", "ignored": true},
    "record-b": {"revision": "0"}
  }
}`
	if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	sequence, revisions, err := readBrowserRevisions(
		path, 3, "credentials", "revision")
	if err != nil {
		t.Fatal(err)
	}
	if sequence != 19 || revisions["record-a"] != 4 || revisions["record-b"] != 0 {
		t.Fatalf("unexpected browser revisions: sequence=%d revisions=%v",
			sequence, revisions)
	}
	if _, _, err := readBrowserRevisions(path, 2, "credentials", "revision"); err == nil {
		t.Fatal("wrong browser bridge schema was accepted")
	}
	bad := strings.Replace(raw, `"revision": "4"`, `"revision": 4`, 1)
	if err := os.WriteFile(path, []byte(bad), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readBrowserRevisions(path, 3, "credentials", "revision"); err == nil {
		t.Fatal("numeric browser revision was accepted")
	}
}
