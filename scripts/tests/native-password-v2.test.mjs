import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

const client = readFileSync(
  new URL("../../chromium/overlay/components/helium_sync/helium_sync_client.cc", import.meta.url),
  "utf8",
);
const clientHeader = readFileSync(
  new URL("../../chromium/overlay/components/helium_sync/helium_sync_client.h", import.meta.url),
  "utf8",
);
const passwords = readFileSync(
  new URL("../../chromium/overlay/components/helium_sync/helium_password_sync_bridge.cc", import.meta.url),
  "utf8",
);

function field(value) {
  const bytes = Buffer.from(value, "utf8");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(bytes.length);
  return Buffer.concat([length, bytes]);
}

function payloadAad(kind, key, revision, deleted, deviceId, keyId) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(revision));
  return Buffer.concat([
    Buffer.from("helium-sync-e2ee-v2\0", "utf8"),
    field(kind),
    field(key),
    field(deviceId),
    field(keyId),
    counter,
    Buffer.from([deleted ? 1 : 0]),
  ]);
}

test("canonical AAD exactly matches the Go vector", () => {
  const actual = payloadAad("passwords", "key/é", 0x0102030405060708n, true, "da", "epoch-1");
  assert.equal(
    actual.toString("hex"),
    "68656c69756d2d73796e632d653265652d7632000000000970617373776f726473000000066b65792fc3a90000000264610000000765706f63682d31010203040506070801",
  );
  assert.match(client, /kPayloadAADMagic\[\] = "helium-sync-e2ee-v2\\0"/);
  assert.match(client, /AppendU32/);
  assert.match(client, /AppendU64/);
});

test("AES-GCM wire vector uses padded standard RFC4648 base64", () => {
  const key = Buffer.from(Array.from({ length: 32 }, (_, index) => index));
  const nonce = Buffer.from(Array.from({ length: 12 }, (_, index) => index));
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(payloadAad("passwords", "vector", 7, false, "d", "epoch"));
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from('{"p":"x"}')),
    cipher.final(),
    cipher.getAuthTag(),
  ]).toString("base64");
  assert.equal(ciphertext, "PCCmOf/HujnwEbLIjZ0EgVuWMZPJfR6sgA==");
  assert.match(client, /base::Base64Encode\(ciphertext\)/);
  assert.match(client, /base::Base64Decode\(\*encoded_ciphertext\)/);
});

test("native HTTP boundary is opaque v2 and server-authenticated", () => {
  assert.doesNotMatch(client, /\/v1\//);
  assert.doesNotMatch(client, /origin_device/);
  assert.match(client, /\/v2\/records\/push/);
  assert.match(client, /"mutations"/);
  assert.match(client, /crypto::aead::Seal/);
  assert.match(client, /crypto::aead::Open/);
  assert.match(clientHeader, /int64_t expected_revision/);
  assert.match(clientHeader, /std::string device_id/);
  assert.match(clientHeader, /std::string key_id/);
  assert.match(clientHeader, /RecordsResult/);
});

test("password startup reconciles before observing or publishing", () => {
  const start = passwords.indexOf("void HeliumPasswordSyncBridge::Start");
  const pull = passwords.indexOf("PullAndApply();", start);
  const observe = passwords.indexOf("AddObserver(this)", start);
  assert.ok(start >= 0 && pull > start && observe > pull);
  assert.match(passwords, /enrollment_phase\(\) == "pending"/);
  assert.match(passwords, /expected_revision/);
  assert.match(passwords, /RemoveLogin/);
  assert.match(passwords, /VerifyRemoteWrites/);
  assert.match(passwords, /AcknowledgeApplied/);
  assert.match(passwords, /verified_sequence/);
  assert.match(passwords, /blocked a malformed or concurrent/);
  assert.doesNotMatch(passwords, /CompleteEnrollment/);
  assert.doesNotMatch(passwords, /helium-password-v1/);
});

test("local rollback uses a non-enrolled device-local key", () => {
  assert.match(client, /kLocalSealKeyID\[\] = "device-local-v1"/);
  assert.match(client, /state_\.local_seal_key/);
  assert.doesNotMatch(
    client.slice(client.indexOf("SealLocalPayload"), client.indexOf("OpenLocalPayload")),
    /active_key_id/,
  );
});
