package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/dhruv9saini/helium-sync/internal/syncstore"
)

func TestVerifyResponseMatchesAuthenticatedMetadataAndPayloadHash(t *testing.T) {
	payload := json.RawMessage(`{"cookies":[{"name":"fixture","value":"rotated"}]}`)
	payloadHash := sha256.Sum256(payload)
	expected := expectedInventory{SchemaVersion: 1, Records: []expectedRecord{{
		Kind: syncstore.KindCookie, Key: "fixture-key", Revision: 2,
		DeviceID: "da-fixture", PayloadSHA256: hex.EncodeToString(payloadHash[:]),
	}}}
	response := syncstore.PlainPullResponse{NextSeq: 4, Records: []syncstore.PlainRecord{{
		Seq: 4, Kind: syncstore.KindCookie, Key: "fixture-key", Revision: 2,
		DeviceID: "da-fixture", KeyID: "key-fixture", Payload: payload,
	}}}
	receipt, err := verifyResponse(response, expected, "key-fixture")
	if err != nil {
		t.Fatal(err)
	}
	if len(receipt) != 1 || receipt[0].Revision != 2 || receipt[0].DeviceID != "da-fixture" {
		t.Fatalf("unexpected receipt: %+v", receipt)
	}

	response.Records[0].Payload = json.RawMessage(`{"cookies":[]}`)
	if _, err := verifyResponse(response, expected, "key-fixture"); err == nil {
		t.Fatal("payload substitution passed synthetic readback")
	}
	response.Records[0].Payload = payload
	response.Records[0].DeviceID = "oneplus-fixture"
	if _, err := verifyResponse(response, expected, "key-fixture"); err == nil {
		t.Fatal("source substitution passed synthetic readback")
	}
}

func TestExpectedInventoryRejectsNonCookieAndDuplicateRecords(t *testing.T) {
	hash := sha256.Sum256([]byte(`{}`))
	record := expectedRecord{Kind: syncstore.KindCookie, Key: "fixture", Revision: 1,
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
	expected.Records[0].Kind = syncstore.KindPassword
	if err := expected.validate(); err == nil {
		t.Fatal("password record passed cookie-only validation")
	}
}
