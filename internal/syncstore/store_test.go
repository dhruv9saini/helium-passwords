package syncstore

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const (
	seedToken    = "seed-token-00000000000000000000000000000000"
	joinToken    = "join-token-00000000000000000000000000000000"
	oneplusToken = "oneplus-token-00000000000000000000000000000"
)

func TestCounterRequiresInt64DecimalString(t *testing.T) {
	raw, err := json.Marshal(struct {
		Seq Counter `json:"seq"`
	}{Seq: Counter(9_223_372_036_854_775_000)})
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != `{"seq":"9223372036854775000"}` {
		t.Fatalf("unexpected counter wire form: %s", raw)
	}
	var decoded struct {
		Seq Counter `json:"seq"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil || decoded.Seq != Counter(9_223_372_036_854_775_000) {
		t.Fatalf("counter round trip failed: seq=%d err=%v", decoded.Seq, err)
	}
	if err := json.Unmarshal([]byte(`{"seq":1}`), &decoded); err == nil {
		t.Fatal("numeric counter must fail closed")
	}
}

func TestSequenceExhaustionFailsClosedWithoutWrapping(t *testing.T) {
	if !hasSequenceCapacity(Counter(math.MaxInt64), false, 1) ||
		hasSequenceCapacity(Counter(math.MaxInt64), false, 2) ||
		hasSequenceCapacity(Counter(math.MaxInt64), true, 1) {
		t.Fatal("inclusive terminal sequence capacity is incorrect")
	}
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	store.nextSeq = Counter(math.MaxInt64)
	store.seqExhausted = true
	if cursor := store.Cursor(); cursor != Counter(math.MaxInt64) {
		t.Fatalf("exhausted cursor wrapped: %d", cursor)
	}
	response, err := store.Put("d", acceptedKeys("epoch"), nil)
	if err != nil || response.NextSeq != Counter(math.MaxInt64) {
		t.Fatalf("exhausted no-op lost the terminal cursor: response=%+v err=%v", response, err)
	}
	mutation := mustEncrypt(t, bytes.Repeat([]byte{9}, clientKeyLength), "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "exhausted", Payload: json.RawMessage(`{"value":1}`),
	}, 1)
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{mutation}); err == nil || !strings.Contains(err.Error(), "sequence space exhausted") {
		t.Fatalf("write after sequence exhaustion did not fail closed: %v", err)
	}
}

func TestCanonicalPayloadAADVector(t *testing.T) {
	aad, err := canonicalPayloadAAD(KindPassword, "key/é", Counter(0x0102030405060708), true, "da", "epoch-1")
	if err != nil {
		t.Fatal(err)
	}
	const expectedHex = "68656c69756d2d73796e632d653265652d7632000000000970617373776f726473000000066b65792fc3a90000000264610000000765706f63682d31010203040506070801"
	if hex.EncodeToString(aad) != expectedHex {
		t.Fatalf("AAD changed: %s", hex.EncodeToString(aad))
	}
}

func TestPaddedBase64AESVector(t *testing.T) {
	key := make([]byte, clientKeyLength)
	for index := range key {
		key[index] = byte(index)
	}
	nonce := make([]byte, clientNonceLength)
	for index := range nonce {
		nonce[index] = byte(index)
	}
	aad, _ := canonicalPayloadAAD(KindPassword, "vector", 7, false, "d", "epoch")
	block, _ := aes.NewCipher(key)
	aead, _ := cipher.NewGCM(block)
	encoded := base64.StdEncoding.EncodeToString(aead.Seal(nil, nonce, []byte(`{"p":"x"}`), aad))
	const expected = "PCCmOf/HujnwEbLIjZ0EgVuWMZPJfR6sgA=="
	if encoded != expected || !strings.HasSuffix(encoded, "=") {
		t.Fatalf("padded AES vector changed: %s", encoded)
	}
}

func TestStoreOpaqueCASAndTombstones(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{7}, clientKeyLength)
	first := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "example/user", Payload: json.RawMessage(`{"password":"never-plaintext"}`),
	}, 1)
	response, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{first})
	if err != nil {
		t.Fatal(err)
	}
	if len(response.Records) != 1 || response.Records[0].Revision != 1 || response.NextSeq != 1 {
		t.Fatalf("unexpected first response: %+v", response)
	}
	raw, err := os.ReadFile(filepath.Join(dir, recordsFile))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("never-plaintext")) {
		t.Fatal("server journal contains plaintext")
	}

	stale := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "example/user", Payload: json.RawMessage(`{"password":"stale"}`),
	}, 1)
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{stale}); err == nil {
		t.Fatal("stale create unexpectedly overwrote revision 1")
	} else {
		var conflict *ConflictError
		if !errors.As(err, &conflict) || conflict.CurrentRevision != 1 {
			t.Fatalf("wanted deterministic revision conflict, got %v", err)
		}
	}

	tombstone := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "example/user", Deleted: true, Payload: json.RawMessage(`{}`),
	}, 2)
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{tombstone}); err != nil {
		t.Fatal(err)
	}
	latest := store.Latest(map[Kind]struct{}{KindPassword: {}})
	if len(latest.Records) != 1 || !latest.Records[0].Deleted || latest.Records[0].Revision != 2 {
		t.Fatalf("latest omitted or changed tombstone: %+v", latest)
	}
	if _, err := store.Put("d", acceptedKeys("wrong-epoch"), []OpaqueMutation{tombstone}); err == nil {
		t.Fatal("inactive key epoch was accepted")
	}
}

func TestEnrollmentIsEncryptedSignedBoundAndComplete(t *testing.T) {
	seed, err := CreateSeedState(filepath.Join(t.TempDir(), "seed.json"))
	if err != nil {
		t.Fatal(err)
	}
	pendingPath := filepath.Join(t.TempDir(), "pending.json")
	request, err := CreateJoinRequest(pendingPath, "da", seed.SeedSigningPublicKey())
	if err != nil {
		t.Fatal(err)
	}
	wrapped, err := seed.WrapEnrollment(request)
	if err != nil {
		t.Fatal(err)
	}
	wrappedRaw, _ := json.Marshal(wrapped)
	for _, encodedKey := range seed.Keys {
		if bytes.Contains(wrappedRaw, []byte(encodedKey)) {
			t.Fatal("wrapped enrollment exposes a plaintext content key")
		}
	}
	joinPath := filepath.Join(t.TempDir(), "join.json")
	join, err := CompleteJoinState(joinPath, pendingPath, wrapped, []string{seed.ActiveKeyID})
	if err != nil {
		t.Fatal(err)
	}
	if join.DeviceID != "da" || join.Phase != PhasePending || join.Keys[seed.ActiveKeyID] != seed.Keys[seed.ActiveKeyID] {
		t.Fatalf("unexpected completed join: %+v", join)
	}

	missingPath := filepath.Join(t.TempDir(), "missing.json")
	missingPending := filepath.Join(t.TempDir(), "missing-pending.json")
	missingRequest, _ := CreateJoinRequest(missingPending, "oneplus", seed.SeedSigningPublicKey())
	missingWrapped, _ := seed.WrapEnrollment(missingRequest)
	if _, err := CompleteJoinState(missingPath, missingPending, missingWrapped, []string{"required-old-epoch"}); err == nil {
		t.Fatal("join accepted a bundle missing a required epoch")
	}

	tamperPending := filepath.Join(t.TempDir(), "tamper-pending.json")
	tamperRequest, _ := CreateJoinRequest(tamperPending, "tamper", seed.SeedSigningPublicKey())
	tampered, _ := seed.WrapEnrollment(tamperRequest)
	tampered.Ciphertext = flipBase64(t, tampered.Ciphertext)
	if _, err := CompleteJoinState(filepath.Join(t.TempDir(), "tamper.json"), tamperPending, tampered, nil); err == nil {
		t.Fatal("tampered enrollment was accepted")
	}

	wrongPending := filepath.Join(t.TempDir(), "wrong-pending.json")
	wrongRequest, _ := CreateJoinRequest(wrongPending, "wrong", seed.SeedSigningPublicKey())
	wrong, _ := seed.WrapEnrollment(wrongRequest)
	wrong.DeviceID = "another-device"
	if _, err := CompleteJoinState(filepath.Join(t.TempDir(), "wrong.json"), wrongPending, wrong, nil); err == nil {
		t.Fatal("enrollment retargeted to the wrong device")
	}

	recoveryPending := filepath.Join(t.TempDir(), "recovery-pending.json")
	recoveryRequest, _ := CreateJoinRequest(recoveryPending, "recovery-copy", seed.SeedSigningPublicKey())
	recoveryWrapped, _ := seed.WrapEnrollment(recoveryRequest)
	recovery, err := DecryptRecoveryExport(recoveryPending, recoveryWrapped, []string{seed.ActiveKeyID})
	if err != nil || recovery.Keys[seed.ActiveKeyID] == "" {
		t.Fatalf("encrypted recovery round trip failed: %v", err)
	}
}

func TestHTTPDeviceLifecycleNoOpAndStaleCAS(t *testing.T) {
	serverDir := t.TempDir()
	seedPath := filepath.Join(t.TempDir(), "seed.json")
	seed, err := CreateSeedState(seedPath)
	if err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(serverDir)
	if err != nil {
		t.Fatal(err)
	}
	registry, err := CreateDeviceRegistry(filepath.Join(serverDir, "devices.json"), seedToken, seed.ActiveKeyID)
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int64
	handler := NewHandler(store, registry)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	seedClient, err := NewClient(server.URL, seedToken, seedPath)
	if err != nil {
		t.Fatal(err)
	}
	seedPush, err := seedClient.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "site/user", Payload: json.RawMessage(`{"password":"one"}`),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if seedPush.Records[0].DeviceID != "d" {
		t.Fatalf("server did not derive seed identity: %+v", seedPush.Records[0])
	}
	requestsAfterWrite := requests.Load()
	if _, err := seedClient.Push(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != requestsAfterWrite {
		t.Fatal("unchanged restart/no-op performed an HTTP publication")
	}

	joinPath, pendingPath := filepath.Join(t.TempDir(), "join.json"), filepath.Join(t.TempDir(), "pending.json")
	request, _ := CreateJoinRequest(pendingPath, "da", seed.SeedSigningPublicKey())
	wrapped, _ := seed.WrapEnrollment(request)
	if _, err := CompleteJoinState(joinPath, pendingPath, wrapped, []string{seed.ActiveKeyID}); err != nil {
		t.Fatal(err)
	}
	if err := registry.EnrollPullOnly("da", joinToken); err != nil {
		t.Fatal(err)
	}
	joinClient, err := NewClient(server.URL, joinToken, joinPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := joinClient.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "site/user", Payload: json.RawMessage(`{"password":"blocked"}`),
	}}); err == nil {
		t.Fatal("pending join published before initial reconciliation")
	}
	initial, err := joinClient.Latest(context.Background(), []string{"passwords"})
	if err != nil || len(initial.Records) != 1 {
		t.Fatalf("join initial pull failed: records=%d err=%v", len(initial.Records), err)
	}
	// Synthetic browser write/readback verification precedes this acknowledgement.
	if string(initial.Records[0].Payload) != `{"password":"one"}` {
		t.Fatal("synthetic browser readback did not match authenticated remote payload")
	}
	if err := joinClient.AcknowledgeApplied(initial); err != nil {
		t.Fatal(err)
	}
	if err := joinClient.CompleteEnrollment(context.Background()); err != nil {
		t.Fatal(err)
	}
	joinEdit, err := joinClient.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "site/user", Payload: json.RawMessage(`{"password":"two"}`),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if joinEdit.Records[0].DeviceID != "da" || joinEdit.Records[0].Revision != 2 {
		t.Fatalf("active join result lacks authenticated server metadata: %+v", joinEdit.Records[0])
	}

	_, err = seedClient.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "site/user", Payload: json.RawMessage(`{"password":"stale-seed"}`),
	}})
	var protocol *ProtocolError
	if !errors.As(err, &protocol) || protocol.StatusCode != http.StatusConflict ||
		protocol.Code != "revision_conflict" || protocol.CurrentRevision != 2 {
		t.Fatalf("stale device did not receive deterministic CAS conflict: %v", err)
	}

	if err := registry.Revoke("da"); err != nil {
		t.Fatal(err)
	}
	if _, err := joinClient.Pull(context.Background(), nil); !errors.As(err, &protocol) || protocol.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked credential still worked: %v", err)
	}
}

func TestTLSThreeDevicePasswordLifecycleAndRotation(t *testing.T) {
	serverDir := t.TempDir()
	seedPath := filepath.Join(t.TempDir(), "seed.json")
	seed, err := CreateSeedState(seedPath)
	if err != nil {
		t.Fatal(err)
	}
	oldKeyID := seed.ActiveKeyID
	store, err := OpenStore(serverDir)
	if err != nil {
		t.Fatal(err)
	}
	registryPath := filepath.Join(serverDir, "devices.json")
	registry, err := CreateDeviceRegistry(registryPath, seedToken, oldKeyID)
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int64
	handler := NewHandler(store, registry)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()
	newTLSClient := func(token, statePath string) *Client {
		client, err := NewClient(server.URL, token, statePath)
		if err != nil {
			t.Fatal(err)
		}
		client.http = server.Client()
		return client
	}

	seedClient := newTLSClient(seedToken, seedPath)
	created, err := seedClient.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "fixture/user",
		Payload: json.RawMessage(`{"password":"created-fixture"}`),
	}})
	if err != nil || len(created.Records) != 1 || created.Records[0].Revision != 1 {
		t.Fatalf("seed password create failed: response=%+v err=%v", created, err)
	}
	requestsAfterCreate := requests.Load()
	if _, err := seedClient.Push(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != requestsAfterCreate {
		t.Fatal("unchanged seed restart published an HTTP request")
	}

	type joinedDevice struct {
		statePath string
		token     string
		client    *Client
	}
	join := func(device, token string) joinedDevice {
		statePath := filepath.Join(t.TempDir(), device+".json")
		pendingPath := filepath.Join(t.TempDir(), device+".pending.json")
		request, err := CreateJoinRequest(pendingPath, device, seed.SeedSigningPublicKey())
		if err != nil {
			t.Fatal(err)
		}
		wrapped, err := seed.WrapEnrollment(request)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := CompleteJoinState(statePath, pendingPath, wrapped, []string{oldKeyID}); err != nil {
			t.Fatal(err)
		}
		if err := registry.EnrollPullOnly(device, token); err != nil {
			t.Fatal(err)
		}
		client := newTLSClient(token, statePath)
		requestsBeforeBlockedPush := requests.Load()
		if _, err := client.Push(context.Background(), []PlainMutation{{
			Kind: KindPassword, Key: "fixture/user",
			Payload: json.RawMessage(`{"password":"must-not-publish"}`),
		}}); err == nil {
			t.Fatalf("pending %s published before verified application", device)
		}
		if requests.Load() != requestsBeforeBlockedPush {
			t.Fatalf("pending %s contacted the server for a blocked publication", device)
		}
		initial, err := client.Latest(context.Background(), []string{"passwords"})
		if err != nil || len(initial.Records) != 1 ||
			string(initial.Records[0].Payload) != `{"password":"created-fixture"}` {
			t.Fatalf("%s initial verified readback failed: response=%+v err=%v", device, initial, err)
		}
		if err := client.AcknowledgeApplied(initial); err != nil {
			t.Fatal(err)
		}
		if err := client.CompleteEnrollment(context.Background()); err != nil {
			t.Fatal(err)
		}
		return joinedDevice{statePath: statePath, token: token, client: client}
	}

	da := join("da", joinToken)
	oneplus := join("oneplus", oneplusToken)
	updated, err := da.client.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "fixture/user",
		Payload: json.RawMessage(`{"password":"updated-fixture"}`),
	}})
	if err != nil || updated.Records[0].Revision != 2 || updated.Records[0].DeviceID != "da" {
		t.Fatalf("da password update failed: response=%+v err=%v", updated, err)
	}
	_, err = oneplus.client.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "fixture/user",
		Payload: json.RawMessage(`{"password":"stale-oneplus"}`),
	}})
	var conflict *ProtocolError
	if !errors.As(err, &conflict) || conflict.Code != "revision_conflict" ||
		conflict.CurrentRevision != 2 {
		t.Fatalf("stale oneplus update did not fail closed: %v", err)
	}
	oneplusUpdate, err := oneplus.client.Latest(context.Background(), []string{"passwords"})
	if err != nil || string(oneplusUpdate.Records[0].Payload) != `{"password":"updated-fixture"}` {
		t.Fatalf("oneplus did not read back the verified update: response=%+v err=%v", oneplusUpdate, err)
	}
	if err := oneplus.client.AcknowledgeApplied(oneplusUpdate); err != nil {
		t.Fatal(err)
	}

	deleted, err := da.client.Push(context.Background(), []PlainMutation{{
		Kind: KindPassword, Key: "fixture/user", Deleted: true, Payload: json.RawMessage(`{}`),
	}})
	if err != nil || !deleted.Records[0].Deleted || deleted.Records[0].Revision != 3 {
		t.Fatalf("password tombstone failed: response=%+v err=%v", deleted, err)
	}
	for device, client := range map[string]*Client{"d": seedClient, "oneplus": oneplus.client} {
		latest, err := client.Latest(context.Background(), []string{"passwords"})
		if err != nil || len(latest.Records) != 1 || !latest.Records[0].Deleted ||
			latest.Records[0].Revision != 3 {
			t.Fatalf("%s did not verify the tombstone: response=%+v err=%v", device, latest, err)
		}
		if err := client.AcknowledgeApplied(latest); err != nil {
			t.Fatal(err)
		}
	}
	journal, err := os.ReadFile(filepath.Join(serverDir, recordsFile))
	if err != nil {
		t.Fatal(err)
	}
	for _, plaintext := range []string{"created-fixture", "updated-fixture", "stale-oneplus"} {
		if bytes.Contains(journal, []byte(plaintext)) {
			t.Fatalf("TLS server journal contains plaintext marker %q", plaintext)
		}
	}

	if err := registry.Revoke("da"); err != nil {
		t.Fatal(err)
	}
	if _, err := da.client.Pull(context.Background(), nil); !errors.As(err, &conflict) ||
		conflict.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked da credential still worked: %v", err)
	}
	if _, err := oneplus.client.Latest(context.Background(), nil); err != nil {
		t.Fatalf("revoking da affected oneplus: %v", err)
	}

	rotatedOneplusToken := "rotated-oneplus-token-000000000000000000000000"
	if err := oneplus.client.StageCredential(context.Background(), rotatedOneplusToken); err != nil {
		t.Fatal(err)
	}
	rotatedOneplus := newTLSClient(rotatedOneplusToken, oneplus.statePath)
	if err := rotatedOneplus.ConfirmCredential(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := oneplus.client.Latest(context.Background(), nil); err != nil {
		t.Fatal("old oneplus credential lost overlap before explicit retirement")
	}
	if err := rotatedOneplus.RetireOldCredential(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := oneplus.client.Latest(context.Background(), nil); err == nil {
		t.Fatal("old oneplus credential survived retirement")
	}
	if _, err := rotatedOneplus.Latest(context.Background(), nil); err != nil {
		t.Fatalf("rotated oneplus credential failed: %v", err)
	}

	newKeyID, err := seedClient.StageContentKey(context.Background())
	if err != nil || newKeyID == oldKeyID {
		t.Fatalf("content-key staging failed: key=%q err=%v", newKeyID, err)
	}
	seedWithStage, err := LoadClientState(seedPath)
	if err != nil {
		t.Fatal(err)
	}
	updatePending := filepath.Join(t.TempDir(), "oneplus-update.pending.json")
	updateRequest, err := CreateJoinRequest(updatePending, "oneplus", seed.SeedSigningPublicKey())
	if err != nil {
		t.Fatal(err)
	}
	updateWrapped, err := seedWithStage.WrapEnrollment(updateRequest)
	if err != nil {
		t.Fatal(err)
	}
	oneplusState, err := LoadClientState(oneplus.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := oneplusState.InstallKeyUpdate(updatePending, updateWrapped, []string{oldKeyID, newKeyID}); err != nil {
		t.Fatal(err)
	}
	rotatedOneplus = newTLSClient(rotatedOneplusToken, oneplus.statePath)
	if err := seedClient.AcknowledgeStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := rotatedOneplus.AcknowledgeStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := seedClient.ActivateStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := rotatedOneplus.AdoptServerKeyStatus(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := seedClient.RekeyAllLatest(context.Background()); err != nil {
		t.Fatal(err)
	}
	rekeyed, err := rotatedOneplus.Latest(context.Background(), []string{"passwords"})
	if err != nil || len(rekeyed.Records) != 1 || rekeyed.Records[0].KeyID != newKeyID ||
		!rekeyed.Records[0].Deleted || rekeyed.Records[0].Revision != 4 {
		t.Fatalf("oneplus did not verify the rekeyed tombstone: response=%+v err=%v", rekeyed, err)
	}
	if err := rotatedOneplus.AcknowledgeApplied(rekeyed); err != nil {
		t.Fatal(err)
	}
	if err := rotatedOneplus.AcknowledgeActiveRekey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := seedClient.RetireContentKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := rotatedOneplus.AdoptServerKeyStatus(context.Background()); err != nil {
		t.Fatal(err)
	}
	finalOneplus, err := LoadClientState(oneplus.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if finalOneplus.ActiveKeyID != newKeyID || len(finalOneplus.Keys) != 1 ||
		finalOneplus.Keys[newKeyID] == "" {
		t.Fatalf("oneplus retained the retired epoch: %+v", finalOneplus)
	}
	registryRaw, err := os.ReadFile(registryPath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(registryRaw, []byte(rotatedOneplusToken)) {
		t.Fatal("registry contains the rotated plaintext oneplus credential")
	}
}

func TestCredentialRotationAndScopes(t *testing.T) {
	seed, _ := CreateSeedState(filepath.Join(t.TempDir(), "seed.json"))
	registryPath := filepath.Join(t.TempDir(), "devices.json")
	registry, err := CreateDeviceRegistry(registryPath, seedToken, seed.ActiveKeyID)
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.EnrollPullOnly("oneplus", joinToken); err != nil {
		t.Fatal(err)
	}
	pending, _ := registry.Authenticate(joinToken)
	if !pending.Allows(ScopePull) || pending.Allows(ScopePush) || pending.Phase != PhasePending {
		t.Fatalf("pending scopes are wrong: %+v", pending)
	}
	if err := registry.Promote("oneplus"); err != nil {
		t.Fatal(err)
	}
	active, _ := registry.Authenticate(joinToken)
	if !active.Allows(ScopePush) || active.Allows(ScopeRotate) || active.Phase != PhaseActive {
		t.Fatalf("active join scopes are wrong: %+v", active)
	}
	store, _ := OpenStore(t.TempDir())
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	oldClient, _ := NewClient(server.URL, seedToken, seed.path)
	newToken := "rotated-seed-token-000000000000000000000000000"
	if err := oldClient.StageCredential(context.Background(), newToken); err != nil {
		t.Fatal(err)
	}
	if _, err := oldClient.Latest(context.Background(), nil); err != nil {
		t.Fatal("old credential lost overlap before confirmation")
	}
	newClient, err := NewClient(server.URL, newToken, seed.path)
	if err != nil {
		t.Fatal(err)
	}
	if err := newClient.ConfirmCredential(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := newClient.RetireOldCredential(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := oldClient.Latest(context.Background(), nil); err == nil {
		t.Fatal("old credential survived explicit HTTP retirement")
	}
	if _, err := newClient.Latest(context.Background(), nil); err != nil {
		t.Fatalf("new credential failed after retirement: %v", err)
	}
	if raw, _ := os.ReadFile(registryPath); bytes.Contains(raw, []byte(newToken)) {
		t.Fatal("registry persisted a plaintext bearer credential")
	}
}

func TestContentKeyRotationRekeysLatestAndTombstones(t *testing.T) {
	serverDir := t.TempDir()
	seedPath := filepath.Join(t.TempDir(), "seed.json")
	seed, _ := CreateSeedState(seedPath)
	oldKeyID := seed.ActiveKeyID
	store, _ := OpenStore(serverDir)
	registry, _ := CreateDeviceRegistry(filepath.Join(serverDir, "devices.json"), seedToken, oldKeyID)
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	client, _ := NewClient(server.URL, seedToken, seedPath)
	sealedRollback, err := seed.SealLocalPayload("cookie-rollback-v1", []byte("rollback-secret"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Push(context.Background(), []PlainMutation{
		{Kind: KindPassword, Key: "live", Payload: json.RawMessage(`{"value":1}`)},
		{Kind: KindPassword, Key: "deleted", Deleted: true, Payload: json.RawMessage(`{}`)},
	}); err != nil {
		t.Fatal(err)
	}

	joinPath := filepath.Join(t.TempDir(), "join.json")
	pending := filepath.Join(t.TempDir(), "pending.json")
	joinRequest, _ := CreateJoinRequest(pending, "da", seed.SeedSigningPublicKey())
	joinWrapped, _ := seed.WrapEnrollment(joinRequest)
	joinState, err := CompleteJoinState(joinPath, pending, joinWrapped, []string{oldKeyID})
	if err != nil {
		t.Fatal(err)
	}
	if err := registry.EnrollPullOnly("da", joinToken); err != nil {
		t.Fatal(err)
	}
	joinClient, _ := NewClient(server.URL, joinToken, joinPath)
	initial, _ := joinClient.Latest(context.Background(), nil)
	if err := joinClient.AcknowledgeApplied(initial); err != nil {
		t.Fatal(err)
	}
	if err := joinClient.CompleteEnrollment(context.Background()); err != nil {
		t.Fatal(err)
	}

	newKeyID, err := client.StageContentKey(context.Background())
	if err != nil || newKeyID == oldKeyID {
		t.Fatalf("content key staging failed: key=%q err=%v", newKeyID, err)
	}
	// A restart after local staging safely resumes the same server transition.
	client, _ = NewClient(server.URL, seedToken, seedPath)
	if resumed, err := client.StageContentKey(context.Background()); err != nil || resumed != newKeyID {
		t.Fatalf("staged rotation was not crash-resumable: key=%q err=%v", resumed, err)
	}
	seedWithStage, _ := LoadClientState(seedPath)
	updatePending := filepath.Join(t.TempDir(), "update-pending.json")
	updateRequest, _ := CreateJoinRequest(updatePending, "da", seed.SeedSigningPublicKey())
	updateWrapped, _ := seedWithStage.WrapEnrollment(updateRequest)
	joinState, _ = LoadClientState(joinPath)
	if err := joinState.InstallKeyUpdate(updatePending, updateWrapped, []string{oldKeyID, newKeyID}); err != nil {
		t.Fatal(err)
	}
	joinClient, _ = NewClient(server.URL, joinToken, joinPath)
	if err := client.AcknowledgeStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := joinClient.AcknowledgeStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Until activation, an active join still writes under the old accepted epoch.
	if _, err := joinClient.Push(context.Background(), []PlainMutation{{Kind: KindPassword, Key: "join-edit", Payload: json.RawMessage(`{"value":2}`)}}); err != nil {
		t.Fatal(err)
	}
	seedBaseline, _ := client.Latest(context.Background(), nil)
	if err := client.AcknowledgeApplied(seedBaseline); err != nil {
		t.Fatal(err)
	}
	if err := client.ActivateStagedKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, accepted := registry.AcceptedWriteKeyIDs()[oldKeyID]; !accepted {
		t.Fatal("old epoch lost overlap immediately after activation")
	}
	if err := joinClient.AdoptServerKeyStatus(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := client.RekeyAllLatest(context.Background()); err != nil {
		t.Fatal(err)
	}
	latest, err := client.Latest(context.Background(), nil)
	if err != nil || len(latest.Records) != 3 {
		t.Fatalf("post-rekey latest failed: records=%d err=%v", len(latest.Records), err)
	}
	for _, record := range latest.Records {
		if record.KeyID != newKeyID || record.Revision != 2 {
			t.Fatalf("record was not CAS-rekeyed: %+v", record)
		}
	}
	joinLatest, _ := joinClient.Latest(context.Background(), nil)
	if err := joinClient.AcknowledgeApplied(joinLatest); err != nil {
		t.Fatal(err)
	}
	if err := joinClient.AcknowledgeActiveRekey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := client.RetireContentKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, accepted := registry.AcceptedWriteKeyIDs()[oldKeyID]; accepted {
		t.Fatal("old epoch remained write-active after verified retirement")
	}
	if err := joinClient.AdoptServerKeyStatus(context.Background()); err != nil {
		t.Fatal(err)
	}
	stateAfterRekey, _ := LoadClientState(seedPath)
	if len(stateAfterRekey.Keys) != 1 || stateAfterRekey.Keys[newKeyID] == "" {
		t.Fatal("verified retirement did not remove old shared key")
	}
	opened, err := stateAfterRekey.OpenLocalPayload("cookie-rollback-v1", sealedRollback)
	if err != nil || string(opened) != "rollback-secret" {
		t.Fatalf("device-local rollback did not survive content rotation: %v", err)
	}
	joinAfterRetire, _ := LoadClientState(joinPath)
	if _, err := joinAfterRetire.OpenLocalPayload("cookie-rollback-v1", sealedRollback); err == nil {
		t.Fatal("another device opened device-local rollback")
	}
}

func TestMissingAndCorruptClientStateFailClosed(t *testing.T) {
	if _, err := NewClient("http://127.0.0.1", seedToken, filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing state did not fail closed")
	}
	path := filepath.Join(t.TempDir(), "corrupt.json")
	if err := os.WriteFile(path, []byte(`{"version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewClient("http://127.0.0.1", seedToken, path); err == nil {
		t.Fatal("corrupt state did not fail closed")
	}
}

func TestStoreRecoversOpaqueJournalFromSnapshot(t *testing.T) {
	dir := t.TempDir()
	store, _ := OpenStore(dir)
	key := bytes.Repeat([]byte{8}, clientKeyLength)
	mutation := mustEncrypt(t, key, "d", "epoch", PlainMutation{
		Kind: KindPassword, Key: "fixture", Payload: json.RawMessage(`{"secret":"opaque"}`),
	}, 1)
	if _, err := store.Put("d", acceptedKeys("epoch"), []OpaqueMutation{mutation}); err != nil {
		t.Fatal(err)
	}
	file, _ := os.OpenFile(filepath.Join(dir, recordsFile), os.O_WRONLY|os.O_APPEND, 0600)
	_, _ = file.WriteString("malformed\n")
	_ = file.Close()
	recovered, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if records := recovered.Pull(0, nil).Records; len(records) != 1 || records[0].Key != "fixture" {
		t.Fatalf("unexpected recovered records: %+v", records)
	}
}

func mustEncrypt(t *testing.T, key []byte, deviceID, keyID string, mutation PlainMutation, revision Counter) OpaqueMutation {
	t.Helper()
	record, err := encryptClientPayload(key, deviceID, keyID, mutation, revision)
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func acceptedKeys(ids ...string) map[string]struct{} {
	out := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		out[id] = struct{}{}
	}
	return out
}

func flipBase64(t *testing.T, encoded string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] ^= 1
	return base64.StdEncoding.EncodeToString(raw)
}

func TestRemovedTabsAndAliasesAreRejected(t *testing.T) {
	for _, value := range []string{"tabs", "tab", "password", "cookie"} {
		if _, err := ParseKind(value); err == nil {
			t.Fatalf("legacy or removed kind %q was accepted", value)
		}
	}
	for _, value := range []string{"passwords", "cookies"} {
		if _, err := ParseKind(value); err != nil {
			t.Fatalf("canonical kind %q was rejected: %v", value, err)
		}
	}
}

func TestServerRejectsClientAssertedDeviceField(t *testing.T) {
	seed, _ := CreateSeedState(filepath.Join(t.TempDir(), "seed.json"))
	store, _ := OpenStore(t.TempDir())
	registry, _ := CreateDeviceRegistry(filepath.Join(t.TempDir(), "devices.json"), seedToken, seed.ActiveKeyID)
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v2/records/push",
		strings.NewReader(`{"device":"forged","mutations":[]}`))
	request.Header.Set("Authorization", "Bearer "+seedToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("caller-supplied device field was not rejected: %d", response.StatusCode)
	}
}

func TestServerRejectsTrailingJSON(t *testing.T) {
	seed, _ := CreateSeedState(filepath.Join(t.TempDir(), "seed.json"))
	store, _ := OpenStore(t.TempDir())
	registry, _ := CreateDeviceRegistry(filepath.Join(t.TempDir(), "devices.json"), seedToken, seed.ActiveKeyID)
	server := httptest.NewServer(NewHandler(store, registry))
	defer server.Close()
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v2/records/push",
		strings.NewReader(`{"mutations":[]} {"mutations":[]}`))
	request.Header.Set("Authorization", "Bearer "+seedToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("trailing JSON was not rejected: %d", response.StatusCode)
	}
}
