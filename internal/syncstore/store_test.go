package syncstore

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	seedToken = "seed-token-0000000000000000000000000000000000"
	joinToken = "join-token-0000000000000000000000000000000000"
)

func mutation(
	kind Kind, key string, expected Counter, payload string) Mutation {
	return Mutation{
		Kind: kind, Key: key, ExpectedRevision: expected,
		Payload: json.RawMessage(payload),
	}
}

func TestStorePersistsReadableCASRecordsAndTombstones(t *testing.T) {
	root := t.TempDir()
	store, err := OpenStore(root)
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.Put("d", []Mutation{
		mutation(KindPassword, "credential/v2/a", 0,
			`{"username":"fixture","password":"synthetic"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.NextSeq != 1 || first.Records[0].Revision != 1 {
		t.Fatalf("unexpected first result: %+v", first)
	}
	if _, err := store.Put("d", []Mutation{
		mutation(KindPassword, "credential/v2/a", 0, `{}`),
	}); err == nil {
		t.Fatal("stale expected revision was accepted")
	} else {
		var conflict *ConflictError
		if !errors.As(err, &conflict) || conflict.CurrentRevision != 1 {
			t.Fatalf("wrong conflict: %v", err)
		}
	}
	tombstone := mutation(
		KindPassword, "credential/v2/a", 1, `{}`)
	tombstone.Deleted = true
	if _, err := store.Put("d", []Mutation{tombstone}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, recordsFile))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"username":"fixture"`) ||
		!strings.Contains(string(raw), `"deleted":true`) ||
		strings.Contains(string(raw), `"ciphertext"`) ||
		strings.Contains(string(raw), `"key_id"`) {
		t.Fatalf("journal does not use the readable trust-boundary schema: %s",
			raw)
	}
}

func TestStoreRecoversCorruptJournalFromCheckedSnapshot(t *testing.T) {
	root := t.TempDir()
	store, err := OpenStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Put("d", []Mutation{
		mutation(KindCookie, "cookie/a", 0, `{"value":"fixture"}`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(root, recordsFile), []byte("corrupt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	recovered, err := OpenStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.Cursor() != 1 {
		t.Fatalf("wrong recovered cursor: %d", recovered.Cursor())
	}
	entries, err := os.ReadDir(filepath.Join(root, "quarantine"))
	if err != nil || len(entries) != 1 {
		t.Fatalf("corrupt journal was not quarantined: %v %v", entries, err)
	}
}

func TestPendingEnrollmentIsPullOnlyUntilCurrentCursorAcknowledged(
	t *testing.T) {
	root := t.TempDir()
	seedPath := filepath.Join(root, "seed.json")
	if _, err := CreateSeedState(seedPath); err != nil {
		t.Fatal(err)
	}
	joinPath := filepath.Join(root, "join.json")
	if _, err := CreateJoinState(joinPath, "da"); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(filepath.Join(root, "server"))
	if err != nil {
		t.Fatal(err)
	}
	registry, err := CreateDeviceRegistry(
		filepath.Join(root, "server", "devices.json"), seedToken)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.EnrollPullOnly("da", joinToken); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()

	seed, err := NewClient(server.URL, seedToken, seedPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := seed.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "credential/v2/a",
		Payload: json.RawMessage(`{"value":"authoritative"}`),
	}}); err != nil {
		t.Fatal(err)
	}
	join, err := NewClient(server.URL, joinToken, joinPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := join.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "credential/v2/local",
		Payload: json.RawMessage(`{"value":"must-not-publish"}`),
	}}); err == nil {
		t.Fatal("pending join published")
	}
	pulled, err := join.Pull(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(pulled.Records) != 1 ||
		string(pulled.Records[0].Payload) != `{"value":"authoritative"}` {
		t.Fatalf("pending join did not receive seed inventory: %+v", pulled)
	}
	if err := join.AcknowledgeApplied(pulled); err != nil {
		t.Fatal(err)
	}
	if err := join.CompleteEnrollment(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := join.Push(context.Background(), []PlainMutation{{
		Kind: KindCookie, Key: "cookie/a",
		Payload: json.RawMessage(`{"value":"active"}`),
	}}); err != nil {
		t.Fatalf("active join could not publish: %v", err)
	}
}

func TestCredentialRotationRequiresNewTokenConfirmation(t *testing.T) {
	root := t.TempDir()
	registry, err := CreateDeviceRegistry(
		filepath.Join(root, "devices.json"), seedToken)
	if err != nil {
		t.Fatal(err)
	}
	newToken := "new-seed-token-0000000000000000000000000000000"
	if err := registry.StageCredentialHash(
		"d", hashToken(newToken)); err != nil {
		t.Fatal(err)
	}
	if err := registry.RetireOldCredentials(
		"d", hashToken(newToken)); err == nil {
		t.Fatal("unconfirmed token retired the old credential")
	}
	if _, err := registry.Authenticate(newToken); err != nil {
		t.Fatal(err)
	}
	if err := registry.ConfirmCredential(
		"d", hashToken(newToken)); err != nil {
		t.Fatal(err)
	}
	if err := registry.RetireOldCredentials(
		"d", hashToken(newToken)); err != nil {
		t.Fatal(err)
	}
	if _, err := registry.Authenticate(seedToken); err == nil {
		t.Fatal("retired old token still authenticates")
	}
}

func TestSyntheticSeedBootstrapUsesExplicitDeviceID(t *testing.T) {
	root := t.TempDir()
	state, err := CreateSeedStateForDevice(
		filepath.Join(root, "seed.json"), "synthetic-seed")
	if err != nil {
		t.Fatal(err)
	}
	bootstrap, err := NewServerBootstrap(state, seedToken)
	if err != nil {
		t.Fatal(err)
	}
	if bootstrap.DeviceID != "synthetic-seed" {
		t.Fatalf("wrong bootstrap seed id: %q", bootstrap.DeviceID)
	}
	registry, err := CreateDeviceRegistryFromBootstrap(
		filepath.Join(root, "devices.json"), bootstrap)
	if err != nil {
		t.Fatal(err)
	}
	principal, err := registry.Authenticate(seedToken)
	if err != nil {
		t.Fatal(err)
	}
	if principal.ID != "synthetic-seed" || principal.Role != RoleSeed {
		t.Fatalf("wrong synthetic seed principal: %+v", principal)
	}
	if err := registry.Revoke("synthetic-seed"); err == nil {
		t.Fatal("synthetic seed was revocable")
	}
}

func TestClientRejectsHTTPSAndNonTailnetHTTP(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "seed.json")
	if _, err := CreateSeedState(statePath); err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []string{
		"https://100.100.105.47:44719",
		"http://192.168.4.233:44719",
		"http://lm.tail0168aa.ts.net:44719",
	} {
		if _, err := NewClient(endpoint, seedToken, statePath); err == nil {
			t.Fatalf("unsafe or obsolete endpoint accepted: %s", endpoint)
		}
	}
	for _, endpoint := range []string{
		"http://127.0.0.1:44719",
		"http://100.100.105.47:44719",
	} {
		if _, err := NewClient(endpoint, seedToken, statePath); err != nil {
			t.Fatalf("valid private endpoint rejected: %s: %v", endpoint, err)
		}
	}
}
