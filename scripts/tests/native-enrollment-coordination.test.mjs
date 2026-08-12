import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const repoFile = relative => fs.readFileSync(
  new URL(`../../${relative}`, import.meta.url), "utf8");

const service = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");
const client = repoFile(
  "chromium/overlay/components/helium_sync/helium_sync_client.cc");
const passwords = repoFile(
  "chromium/overlay/components/helium_sync/helium_password_sync_bridge.cc");
const cookies = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc");

test("pending enrollment promotes only a verified native password cursor", () => {
  assert.match(service, /enrollment->phase == "pending"/);
  assert.match(service, /OnPasswordBaselineVerified/);
  assert.doesNotMatch(service, /OnCookieBaselineVerified|cookie_bridge_/);

  const coordinate = service.slice(
    service.indexOf("void HeliumSyncService::MaybeCompleteEnrollment"),
    service.indexOf("void HeliumSyncService::OnEnrollmentComplete"),
  );
  const acknowledge = coordinate.indexOf("AcknowledgeApplied");
  const complete = coordinate.indexOf("enrollment_client_->CompleteEnrollment");
  assert.ok(acknowledge >= 0 && complete > acknowledge);
  assert.match(coordinate, /verified_sequence = \*password_verified_sequence_/);
});

test("password readiness follows durable readback and cursor acknowledgement", () => {
  const finish = passwords.slice(
    passwords.indexOf("void HeliumPasswordSyncBridge::FinishReconcile"),
    passwords.indexOf("bool HeliumPasswordSyncBridge::LoadState"),
  );
  assert.ok(finish.indexOf("SaveState()") >= 0);
  assert.ok(finish.indexOf("AcknowledgeApplied") > finish.indexOf("SaveState()"));
  assert.ok(finish.indexOf("verified_baseline_callback_.Run") >
    finish.indexOf("AcknowledgeApplied"));
});

test("activation reloads immutable identity before password publication resumes", () => {
  const reload = client.slice(
    client.indexOf("bool HeliumSyncClient::ReloadEnrollmentState"),
    client.indexOf("void HeliumSyncClient::CompleteEnrollment"),
  );
  for (const invariant of ["device_id", "role"]) {
    assert.match(reload, new RegExp(`state_\\.${invariant} != previous\\.${invariant}`));
  }
  assert.match(reload, /state_\.sequence < previous\.sequence/);

  const activated = service.slice(
    service.indexOf("void HeliumSyncService::OnEnrollmentComplete"),
  );
  assert.match(activated, /password_bridge_->EnrollmentActivated/);
  assert.match(activated, /password_bridge_->PullAndApply/);
  assert.doesNotMatch(activated, /cookie_bridge_/);
});

test("normal cookie code is backup-only and never uses the Tailnet client", () => {
  assert.doesNotMatch(cookies, /HeliumSyncClient|Latest\(|Push\(|AcknowledgeApplied/);
  assert.match(cookies, /HeliumCookieAcceptanceFixture/);
  assert.match(cookies, /GetCookieManagerForBrowserProcess/);
  assert.doesNotMatch(passwords, /CompleteEnrollment/);
});
