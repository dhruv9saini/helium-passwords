package syncstore

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestStoreRoundTripAndLatest(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "passphrase")
	if err != nil {
		t.Fatal(err)
	}

	response, err := store.Put([]PlainRecord{
		{Kind: KindTabs, Key: "device/window/1", Version: 1, Payload: json.RawMessage(`{"tabs":["https://example.com"]}`)},
		{Kind: KindTabs, Key: "device/window/1", Version: 99, Payload: json.RawMessage(`{"tabs":["https://example.org"]}`)},
		{Kind: KindCookie, Key: "example.com/session", Payload: json.RawMessage(`{"domain":"example.com","name":"session","value":"secret"}`)},
	}, "laptop")
	if err != nil {
		t.Fatal(err)
	}
	if response.Accepted != 3 || response.NextSeq != 4 {
		t.Fatalf("unexpected response: %+v", response)
	}

	pulled, err := store.Pull(1, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(pulled.Records) != 2 {
		t.Fatalf("wanted 2 records after seq 1, got %d", len(pulled.Records))
	}
	if !bytes.Contains(pulled.Records[0].Payload, []byte("example.org")) {
		t.Fatalf("unexpected payload: %s", pulled.Records[0].Payload)
	}

	latest, err := store.Latest(map[Kind]struct{}{KindTabs: {}}, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(latest.Records) != 1 {
		t.Fatalf("wanted one latest tab record, got %d", len(latest.Records))
	}
	if latest.Records[0].Version != 99 {
		t.Fatalf("wanted version 99, got %d", latest.Records[0].Version)
	}
}

func TestStoreDoesNotPersistPlaintext(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir, "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.Put([]PlainRecord{
		{Kind: KindPassword, Key: "https://example.com/user", Payload: json.RawMessage(`{"username":"me","password":"do-not-store-plain"}`)},
	}, "laptop")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, recordsFile))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("do-not-store-plain")) {
		t.Fatal("plaintext password was written to the records file")
	}
}

func TestWrongPassphraseCannotDecrypt(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir, "correct")
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.Put([]PlainRecord{
		{Kind: KindTabs, Key: "tab", Payload: json.RawMessage(`{"url":"https://example.com"}`)},
	}, "laptop")
	if err != nil {
		t.Fatal(err)
	}

	wrong, err := OpenStore(dir, "wrong")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := wrong.Pull(0, nil); err == nil {
		t.Fatal("expected decryption failure with wrong passphrase")
	}
}

func TestHTTPPushPull(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(NewHandler(store, HandlerOptions{Token: "token"}))
	defer server.Close()

	client := NewClient(server.URL, "token")
	push, err := client.Push(context.Background(), PushRequest{
		Device: "laptop",
		Records: []PlainRecord{
			{Kind: KindCookie, Key: "example.com/session", Payload: json.RawMessage(`{"value":"secret"}`)},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if push.Accepted != 1 {
		t.Fatalf("unexpected push response: %+v", push)
	}

	pull, err := client.Pull(context.Background(), 0, []string{"cookies"})
	if err != nil {
		t.Fatal(err)
	}
	if len(pull.Records) != 1 || pull.Records[0].Kind != KindCookie {
		t.Fatalf("unexpected pull response: %+v", pull)
	}
	pull, err = client.Pull(context.Background(), 0, []string{"cookie"})
	if err != nil {
		t.Fatal(err)
	}
	if len(pull.Records) != 1 || pull.Records[0].Kind != KindCookie {
		t.Fatalf("singular alias returned wrong response: %+v", pull)
	}
}

func TestTokenRequired(t *testing.T) {
	store, err := OpenStore(t.TempDir(), "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(NewHandler(store, HandlerOptions{Token: "token"}))
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/records/pull")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wanted 401, got %d", response.StatusCode)
	}
}
