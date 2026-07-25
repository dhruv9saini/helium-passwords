package syncstore

import (
	"context"
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
	mutations := make([]Mutation, 0, 7)
	for index := 0; index < 7; index++ {
		kind := KindPassword
		if index%2 != 0 {
			kind = KindCookie
		}
		mutations = append(mutations,
			mutation(kind, "key-"+strconv.Itoa(index), 0, `{"value":1}`))
	}
	if _, err := store.Put("d", mutations); err != nil {
		t.Fatal(err)
	}

	page, err := store.PullPage(0, "", 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	if page.NextSeq != 7 || page.PageCursor == "" ||
		len(page.Records) != 2 {
		t.Fatalf("unexpected first page: %+v", page)
	}
	if _, err := store.Put("d", []Mutation{
		mutation(KindPassword, "late", 0, `{"value":2}`),
	}); err != nil {
		t.Fatal(err)
	}

	all := append([]Record(nil), page.Records...)
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
	if err != nil || len(fresh.Records) != 1 ||
		fresh.Records[0].Seq != 8 || fresh.NextSeq != 8 {
		t.Fatalf("post-snapshot record was lost: %+v %v", fresh, err)
	}
}

func TestLatestPagesReturnOneOrderedRecordPerIdentity(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	put := func(key string, expected Counter, deleted bool) {
		t.Helper()
		item := mutation(KindPassword, key, expected, `{}`)
		item.Deleted = deleted
		if _, err := store.Put("d", []Mutation{item}); err != nil {
			t.Fatal(err)
		}
	}
	put("a", 0, false)
	put("b", 0, false)
	put("c", 0, false)
	put("a", 1, false)
	put("b", 1, true)

	page, err := store.LatestPage("", 1, nil)
	var all []Record
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
	if _, err := CreateSeedState(seedPath); err != nil {
		t.Fatal(err)
	}
	readerPath := filepath.Join(t.TempDir(), "reader.json")
	seedRaw, err := os.ReadFile(seedPath)
	if err != nil || os.WriteFile(readerPath, seedRaw, 0600) != nil {
		t.Fatalf("copy synthetic client state: %v", err)
	}
	store, err := OpenStore(serverDir)
	if err != nil {
		t.Fatal(err)
	}
	registry, err := CreateDeviceRegistry(
		filepath.Join(serverDir, "devices.json"), seedToken)
	if err != nil {
		t.Fatal(err)
	}
	var pullRequests atomic.Int64
	handler := NewHandler(store, registry)
	server := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/v2/records/pull" {
				pullRequests.Add(1)
			}
			handler.ServeHTTP(w, r)
		}))
	defer server.Close()
	publisher, err := NewClient(server.URL, seedToken, seedPath)
	if err != nil {
		t.Fatal(err)
	}
	mutations := make([]PlainMutation, 0, 300)
	for index := 0; index < 300; index++ {
		mutations = append(mutations, PlainMutation{
			Kind: KindPassword, Key: "bulk-" + strconv.Itoa(index),
			Payload: json.RawMessage(`{"value":"synthetic"}`),
		})
	}
	if _, err := publisher.Push(
		context.Background(), mutations); err != nil {
		t.Fatal(err)
	}
	reader, err := NewClient(server.URL, seedToken, readerPath)
	if err != nil {
		t.Fatal(err)
	}
	pulled, err := reader.Pull(
		context.Background(), []string{"passwords"})
	if err != nil {
		t.Fatal(err)
	}
	if len(pulled.Records) != 300 || pulled.NextSeq != 300 ||
		pullRequests.Load() != 3 {
		t.Fatalf(
			"client did not exhaust pages: records=%d next=%d requests=%d",
			len(pulled.Records), pulled.NextSeq, pullRequests.Load())
	}
	if err := reader.AcknowledgeApplied(pulled); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewClient(server.URL, seedToken, readerPath)
	if err != nil {
		t.Fatal(err)
	}
	empty, err := restarted.Pull(
		context.Background(), []string{"passwords"})
	if err != nil || len(empty.Records) != 0 ||
		empty.NextSeq != 300 || pullRequests.Load() != 4 {
		t.Fatalf(
			"restart cursor was not durable: %+v requests=%d err=%v",
			empty, pullRequests.Load(), err)
	}
}

func TestPageProtocolAndBudgetsFailClosed(t *testing.T) {
	var missing PullResponse
	if err := json.Unmarshal(
		[]byte(`{"records":[],"next_seq":"0"}`),
		&missing); err == nil {
		t.Fatal("legacy unpaged response was accepted")
	}

	seedPath := filepath.Join(t.TempDir(), "seed.json")
	if _, err := CreateSeedState(seedPath); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	registry, err := CreateDeviceRegistry(
		filepath.Join(t.TempDir(), "devices.json"), seedToken)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	for _, query := range []string{
		"", "?limit=128", "?limit=0128&since=0",
		"?limit=128&since=0&unknown=x",
	} {
		request, _ := http.NewRequest(
			http.MethodGet, server.URL+"/v2/records/pull"+query, nil)
		request.Header.Set("Authorization", "Bearer "+seedToken)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusBadRequest {
			t.Fatalf("invalid query %q returned %d",
				query, response.StatusCode)
		}
	}
	oversized := mutation(
		KindPassword, "oversized", 0,
		`{"value":"`+strings.Repeat("x", maxMutationBytes)+`"}`)
	if _, err := store.Put("d", []Mutation{oversized}); err == nil ||
		!strings.Contains(err.Error(), "mutation exceeds") {
		t.Fatalf("oversized record did not fail closed: %v", err)
	}
}
