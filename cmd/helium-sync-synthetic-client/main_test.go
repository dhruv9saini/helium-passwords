package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/dhruv9saini/helium-passwords/internal/syncstore"
)

const (
	testSeedToken = "synthetic-seed-token-00000000000000000000000000"
	testJoinToken = "synthetic-join-token-00000000000000000000000000"
)

func TestVerifyResponseMatchesAuthenticatedMetadataAndPayloadHash(t *testing.T) {
	payload := json.RawMessage(`{"credential":"fixture"}`)
	payloadHash := sha256.Sum256(payload)
	expected := expectedInventory{SchemaVersion: 1, Records: []expectedRecord{{
		Kind: syncstore.KindPassword, Key: "fixture-key", Revision: 2,
		DeviceID: "da-fixture", PayloadSHA256: hex.EncodeToString(payloadHash[:]),
	}}}
	response := syncstore.PlainPullResponse{NextSeq: 4, Records: []syncstore.PlainRecord{{
		Seq: 4, Kind: syncstore.KindPassword, Key: "fixture-key", Revision: 2,
		DeviceID: "da-fixture", Payload: payload,
	}}}
	receipt, err := verifyResponse(response, expected)
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt) != 1 || receipt[0].Kind != syncstore.KindPassword ||
		receipt[0].Revision != 2 || receipt[0].DeviceID != "da-fixture" {
		t.Fatalf("unexpected receipt: %+v", receipt)
	}

	response.Records[0].Payload = json.RawMessage(`{"credential":"changed"}`)
	if _, err := verifyResponse(response, expected); err == nil {
		t.Fatal("payload substitution passed synthetic readback")
	}
	response.Records[0].Payload = payload
	response.Records[0].DeviceID = "oneplus-fixture"
	if _, err := verifyResponse(response, expected); err == nil {
		t.Fatal("source substitution passed synthetic readback")
	}
}

func TestExpectedInventoryAcceptsPasswordsAndRejectsCookiesUnknownAndDuplicates(t *testing.T) {
	hash := sha256.Sum256([]byte(`{}`))
	record := expectedRecord{Kind: syncstore.KindPassword, Key: "fixture", Revision: 1,
		DeviceID: "d", PayloadSHA256: hex.EncodeToString(hash[:])}
	expected := expectedInventory{SchemaVersion: 1, Records: []expectedRecord{record}}
	if err := expected.validate(); err != nil {
		t.Fatal(err)
	}
	expected.Records = append(expected.Records, record)
	if err := expected.validate(); err == nil {
		t.Fatal("duplicate expected record passed validation")
	}
	expected.Records = []expectedRecord{record}
	expected.Records[0].Kind = syncstore.KindCookie
	if err := expected.validate(); err == nil {
		t.Fatal("cookie record passed password-only validation")
	}
	expected.Records[0].Kind = syncstore.Kind("unknown")
	if err := expected.validate(); err == nil {
		t.Fatal("unknown record kind passed validation")
	}
}

func TestRunVerifiesCompletePasswordInventoryBeforeEnrollmentCompletion(t *testing.T) {
	root := t.TempDir()
	seedPath := filepath.Join(root, "d.json")
	_, err := syncstore.CreateSeedState(seedPath)
	if err != nil {
		t.Fatal(err)
	}
	store, err := syncstore.OpenStore(filepath.Join(root, "server"))
	if err != nil {
		t.Fatal(err)
	}
	registry, err := syncstore.CreateDeviceRegistry(
		filepath.Join(root, "server", "devices.json"), testSeedToken)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(syncstore.NewHandler(store, registry))
	defer server.Close()
	seedClient, err := syncstore.NewClient(server.URL, testSeedToken, seedPath)
	if err != nil {
		t.Fatal(err)
	}
	passwordPayload := json.RawMessage(`{"credential":"synthetic"}`)
	if _, err := seedClient.Push(context.Background(), []syncstore.PlainMutation{
		{Kind: syncstore.KindPassword, Key: "credential/v2/fixture", Payload: passwordPayload},
	}); err != nil {
		t.Fatal(err)
	}

	markerPath := filepath.Join(root, "SYNTHETIC_ONLY")
	if err := os.WriteFile(markerPath, []byte(syntheticMarker+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	expectedPath := filepath.Join(root, "expected.json")
	passwordHash := sha256.Sum256(passwordPayload)
	expected := expectedInventory{SchemaVersion: 1, Records: []expectedRecord{
		{Kind: syncstore.KindPassword, Key: "credential/v2/fixture", Revision: 1,
			DeviceID: "d", PayloadSHA256: hex.EncodeToString(passwordHash[:])},
	}}
	rawExpected, err := json.Marshal(expected)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(expectedPath, rawExpected, 0600); err != nil {
		t.Fatal(err)
	}

	join := func(device, token string) string {
		t.Helper()
		statePath := filepath.Join(root, device+".json")
		if _, err := syncstore.CreateJoinState(statePath, device); err != nil {
			t.Fatal(err)
		}
		if err := registry.EnrollPullOnly(device, token); err != nil {
			t.Fatal(err)
		}
		tokenPath := filepath.Join(root, device+".token")
		if err := os.WriteFile(tokenPath, []byte(token+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		return tokenPath
	}

	daTokenPath := join("da", testJoinToken)
	if err := run([]string{
		"--synthetic-only-marker", markerPath,
		"--url", server.URL,
		"--token-file", daTokenPath,
		"--state-file", filepath.Join(root, "da.json"),
		"--expected-file", expectedPath,
		"--latest",
		"--complete-enrollment",
	}); err != nil {
		t.Fatal(err)
	}
	principal, err := registry.Authenticate(testJoinToken)
	if err != nil || principal.Phase != syncstore.PhaseActive {
		t.Fatalf("verified password inventory did not activate da: principal=%+v err=%v", principal, err)
	}

	partialPath := filepath.Join(root, "partial.json")
	partial := expectedInventory{SchemaVersion: 1, Records: []expectedRecord{}}
	rawPartial, err := json.Marshal(partial)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(partialPath, rawPartial, 0600); err != nil {
		t.Fatal(err)
	}
	oneplusToken := testJoinToken + "-oneplus"
	oneplusTokenPath := join("oneplus", oneplusToken)
	if err := run([]string{
		"--synthetic-only-marker", markerPath,
		"--url", server.URL,
		"--token-file", oneplusTokenPath,
		"--state-file", filepath.Join(root, "oneplus.json"),
		"--expected-file", partialPath,
		"--latest",
		"--complete-enrollment",
	}); err == nil {
		t.Fatal("incomplete password inventory activated enrollment")
	}
	principal, err = registry.Authenticate(oneplusToken)
	if err != nil || principal.Phase != syncstore.PhasePending {
		t.Fatalf("failed mixed inventory did not leave oneplus pending: principal=%+v err=%v", principal, err)
	}
}
