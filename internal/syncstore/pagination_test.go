package syncstore

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func TestPullPagesFreezeSnapshotWithoutGapsOrDuplicates(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{3}, clientKeyLength)
	mutations := make([]OpaqueMutation, 0, 7)
	for index := 0; index < 7; index++ {
		kind := KindPassword
		if index%2 != 0 {
			kind = KindCookie
		}
		mutations = append(mutations, mustEncrypt(t, key, "d", "epoch", PlainMutation{
			Kind: kind, Key: "key-" + strconv.Itoa(index), Payload: json.RawMessage(`{"value":1}`),
		}, 1))
	}
	if _, err := store.Put("d", acceptedKeys("epoch"), mutations); err != nil {
		t.Fatal(err)
	}

	page, err := store.PullPage(0, "", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	if page.NextSeq != 7 || page.PageCursor == "" || len(page.Records) != 2 {
		t.Fatalf("unexpected first page: %+v", page)
	}
	late := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "late", Payload: json.RawMessage(`{"value":2}`),
	}, 1)
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{late}); err != nil {
		t.Fatal(err)
	}

	all := append([]OpaqueRecord(nil), page.Records...)
	for page.PageCursor != "" {
		page, err = store.PullPage(0, page.PageCursor, 2, nil)
		if err != nil {
			t.Fatal(err)
		}
		if page.NextSeq != 7 {
			t.Fatalf("snapshot changed across pages: %d", page.NextSeq)
		}
		all = append(all, page.Records...)
	}
	if len(all) != 7 {
		t.Fatalf("wanted seven frozen records, got %d", len(all))
	}
	for index, record := range all {
		if record.Seq != Counter(index+1) {
			t.Fatalf("gap or duplicate at %d: seq=%d", index, record.Seq)
		}
	}
	fresh, err := store.PullPage(7, "", 2, nil)
	if err != nil || len(fresh.Records) != 1 || fresh.Records[0].Seq != 8 || fresh.NextSeq != 8 {
		t.Fatalf("post-snapshot record was lost: response=%+v err=%v", fresh, err)
	}
}

func TestLatestPagesReturnOneOrderedRecordPerIdentity(t *testing.T) {
	store, _ := OpenStore(t.TempDir())
	key := bytes.Repeat([]byte{4}, clientKeyLength)
	put := func(keyName string, revision Counter, deleted bool) {
		t.Helper()
		mutation := mustEncrypt(t, key, "d", "epoch", PlainMutation{
			Kind: KindPassword, Key: keyName, Deleted: deleted, Payload: json.RawMessage(`{}`),
		}, revision)
		if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{mutation}); err != nil {
			t.Fatal(err)
		}
	}
	put("a", 1, false)
	put("b", 1, false)
	put("c", 1, false)
	put("a", 2, false)
	put("b", 2, true)

	page, err := store.LatestPage("", 1, nil)
	var all []OpaqueRecord
	for {
		if err != nil {
			t.Fatal(err)
		}
		all = append(all, page.Records...)
		if page.PageCursor == "" {
			break
		}
		page, err = store.LatestPage(page.PageCursor, 1, nil)
	}
	if len(all) != 3 || all[0].Key != "c" || all[0].Seq != 3 ||
		all[1].Key != "a" || all[1].Seq != 4 ||
		all[2].Key != "b" || all[2].Seq != 5 || !all[2].Deleted {
		t.Fatalf("latest pages were not unique and ordered: %+v", all)
	}
}

func TestHTTPClientExhaustsPagesBeforeDurableRestartCursor(t *testing.T) {
	serverDir := t.TempDir()
	seedPath := filepath.Join(t.TempDir(), "seed.json")
	seed, err := CreateSeedState(seedPath)
	if err != nil {
		t.Fatal(err)
	}
	readerPath := filepath.Join(t.TempDir(), "reader.json")
	seedRaw, err := os.ReadFile(seedPath)
	if err != nil || os.WriteFile(readerPath, seedRaw, 0600) != nil {
		t.Fatalf("copy synthetic client state: %v", err)
	}
	store, _ := OpenStore(serverDir)
	registry, _ := CreateDeviceRegistry(filepath.Join(serverDir, "devices.json"), seedToken, seed.ActiveKeyID)
	var pullRequests atomic.Int64
	handler := NewHandler(store, registry)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/records/pull" {
			pullRequests.Add(1)
		}
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	publisher, _ := NewClient(server.URL, seedToken, seedPath)
	mutations := make([]PlainMutation, 0, 300)
	for index := 0; index < 300; index++ {
		mutations = append(mutations, PlainMutation{
			Kind: KindPassword, Key: "bulk-" + strconv.Itoa(index), Payload: json.RawMessage(`{"value":"synthetic"}`),
		})
	}
	if _, err := publisher.Push(context.Background(), mutations); err != nil {
		t.Fatal(err)
	}
	reader, _ := NewClient(server.URL, seedToken, readerPath)
	pulled, err := reader.Pull(context.Background(), []string{"passwords"})
	if err != nil {
		t.Fatal(err)
	}
	if len(pulled.Records) != 300 || pulled.NextSeq != 300 || pullRequests.Load() != 3 {
		t.Fatalf("client did not exhaust three pages: records=%d next=%d requests=%d",
			len(pulled.Records), pulled.NextSeq, pullRequests.Load())
	}
	for index, record := range pulled.Records {
		if record.Seq != Counter(index+1) {
			t.Fatalf("client aggregate has a gap or duplicate at %d: %d", index, record.Seq)
		}
	}
	if err := reader.AcknowledgeApplied(pulled); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewClient(server.URL, seedToken, readerPath)
	if err != nil {
		t.Fatal(err)
	}
	empty, err := restarted.Pull(context.Background(), []string{"passwords"})
	if err != nil || len(empty.Records) != 0 || empty.NextSeq != 300 || pullRequests.Load() != 4 {
		t.Fatalf("restart cursor was not durable: response=%+v requests=%d err=%v", empty, pullRequests.Load(), err)
	}
}

func TestPageProtocolFailsClosed(t *testing.T) {
	var missing PullResponse
	if err := json.Unmarshal([]byte(`{"records":[],"next_seq":"0"}`), &missing); err == nil {
		t.Fatal("legacy unpaged response was accepted")
	}

	seedPath := filepath.Join(t.TempDir(), "seed.json")
	if _, err := CreateSeedState(seedPath); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"page_version":1,"page_cursor":"repeat","records":[],"next_seq":"0"}`))
	}))
	defer server.Close()
	client, _ := NewClient(server.URL, seedToken, seedPath)
	if _, err := client.Pull(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "repeated a page cursor") {
		t.Fatalf("repeated cursor did not fail closed: %v", err)
	}
}

func TestHTTPPageQueryAndOpaqueRecordBudgetsFailClosed(t *testing.T) {
	seed, _ := CreateSeedState(filepath.Join(t.TempDir(), "seed.json"))
	store, _ := OpenStore(t.TempDir())
	registry, _ := CreateDeviceRegistry(filepath.Join(t.TempDir(), "devices.json"), seedToken, seed.ActiveKeyID)
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	for _, query := range []string{"", "?limit=128", "?limit=0128&since=0", "?limit=128&since=0&unknown=x"} {
		request, _ := http.NewRequest(http.MethodGet, server.URL+"/v2/records/pull"+query, nil)
		request.Header.Set("Authorization", "Bearer "+seedToken)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusBadRequest {
			t.Fatalf("invalid page query %q returned %d", query, response.StatusCode)
		}
	}
	request, _ := http.NewRequest(http.MethodGet, server.URL+"/v2/records/pull?limit=128&since=0", nil)
	request.Header.Set("Authorization", "Bearer "+seedToken)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("canonical page query returned %d", response.StatusCode)
	}

	key := bytes.Repeat([]byte{5}, clientKeyLength)
	oversized := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "oversized", Payload: json.RawMessage(`{}`),
	}, 1)
	oversized.Ciphertext = base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, maxOpaqueMutationBytes))
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{oversized}); err == nil ||
		!strings.Contains(err.Error(), "opaque mutation exceeds") {
		t.Fatalf("oversized record did not fail closed: %v", err)
	}
}
