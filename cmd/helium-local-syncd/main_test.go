package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestCookieUpdateIsAtomicCompareAndSwap(t *testing.T) {
	cookieDir := filepath.Join(t.TempDir(), "cookiecloud")
	if err := os.MkdirAll(cookieDir, 0700); err != nil {
		t.Fatal(err)
	}
	server := &app{cookieDir: cookieDir}

	first := updateCookie(t, server, map[string]any{
		"uuid":              "fixture",
		"encrypted":         "generation-one",
		"expected_revision": 0,
	})
	if first.Code != http.StatusOK {
		t.Fatalf("first update status = %d: %s", first.Code, first.Body.String())
	}

	stale := updateCookie(t, server, map[string]any{
		"uuid":              "fixture",
		"encrypted":         "stale-overwrite",
		"expected_revision": 0,
	})
	if stale.Code != http.StatusConflict {
		t.Fatalf("stale update status = %d: %s", stale.Code, stale.Body.String())
	}

	request := httptest.NewRequest(http.MethodGet, "/get/fixture", nil)
	response := httptest.NewRecorder()
	server.route(response, request)
	var record cookieCloudRecord
	if err := json.Unmarshal(response.Body.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record.Encrypted != "generation-one" || record.Revision != 1 {
		t.Fatalf("stale update changed record: %+v", record)
	}

	second := updateCookie(t, server, map[string]any{
		"uuid":              "fixture",
		"encrypted":         "generation-two",
		"expected_revision": 1,
	})
	if second.Code != http.StatusOK {
		t.Fatalf("second update status = %d: %s", second.Code, second.Body.String())
	}
	entries, err := os.ReadDir(cookieDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "fixture.json" {
		t.Fatalf("unexpected atomic-write files: %v", entries)
	}
}

func TestCookieUpdateRequiresRevision(t *testing.T) {
	cookieDir := filepath.Join(t.TempDir(), "cookiecloud")
	if err := os.MkdirAll(cookieDir, 0700); err != nil {
		t.Fatal(err)
	}
	server := &app{cookieDir: cookieDir}
	response := updateCookie(t, server, map[string]any{
		"uuid":      "fixture",
		"encrypted": "legacy-unconditional-write",
	})
	if response.Code != http.StatusPreconditionRequired {
		t.Fatalf("unconditional update status = %d", response.Code)
	}
}

func updateCookie(t *testing.T, server *app, body map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/update", bytes.NewReader(raw))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	server.route(response, request)
	return response
}
