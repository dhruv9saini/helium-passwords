import assert from "node:assert/strict";
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
const service = readFileSync(
  new URL("../../chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc", import.meta.url),
  "utf8",
);
const passwords = readFileSync(
  new URL("../../chromium/overlay/components/helium_sync/helium_password_sync_bridge.cc", import.meta.url),
  "utf8",
);

test("native wire uses readable authenticated Tailnet records", () => {
  assert.doesNotMatch(client, /\/v1\//);
  assert.match(client, /\/v2\/records\/push/);
  assert.match(client, /wire->Set\("expected_revision"/);
  assert.match(client, /wire->Set\("payload", std::move\(\*payload\)\)/);
  assert.match(client, /wire\.Find\("payload"\)/);
  assert.match(clientHeader, /int64_t expected_revision/);
  assert.match(clientHeader, /std::string device_id/);
  assert.match(clientHeader, /std::string payload_json/);
  assert.doesNotMatch(
    client + clientHeader,
    /ciphertext|nonce|key_id|active_key_id|AES_256_GCM|SealLocalPayload|OpenLocalPayload/,
  );
});

test("native endpoint is exact HTTP loopback or Tailscale IPv4", () => {
  assert.match(service, /SchemeIs\(url::kHttpScheme\)/);
  assert.match(service, /AssignFromIPLiteral/);
  assert.match(service, /address\.IsLoopback\(\)/);
  assert.match(service, /IPAddress\(100, 64, 0, 0\), 10/);
  assert.doesNotMatch(service, /kHttpsScheme|active_key_id|Base64Decode/);
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
  assert.match(passwords, /kPasswordStateSchema = 6/);
  assert.doesNotMatch(passwords, /key_id|active_key_id/);
  assert.doesNotMatch(passwords, /CompleteEnrollment/);
});
