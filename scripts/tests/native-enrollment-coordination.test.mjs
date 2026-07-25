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

class EnrollmentCoordinatorModel {
  cookie = null;
  password = null;
  completions = [];
  refreshes = 0;

  verified(kind, sequence) {
    this[kind] = sequence;
    if (this.cookie === null || this.password === null) return;
    if (this.cookie !== this.password) {
      this.cookie = null;
      this.password = null;
      this.refreshes += 1;
      return;
    }
    this.completions.push(this.cookie);
  }
}

test("pending enrollment promotes only a joint password and cookie cursor", () => {
  const coordinator = new EnrollmentCoordinatorModel();
  coordinator.verified("cookie", 40);
  assert.deepEqual(coordinator.completions, []);
  coordinator.verified("password", 41);
  assert.deepEqual(coordinator.completions, []);
  assert.equal(coordinator.refreshes, 1);

  coordinator.verified("password", 42);
  coordinator.verified("cookie", 42);
  assert.deepEqual(coordinator.completions, [42]);
});

test("service wires both pending bridges to one fail-closed coordinator", () => {
  assert.match(service, /enrollment->phase == "pending"/);
  assert.match(service, /OnCookieBaselineVerified/);
  assert.match(service, /OnPasswordBaselineVerified/);

  const coordinate = service.slice(
    service.indexOf("void HeliumSyncService::MaybeCompleteEnrollment"),
    service.indexOf("void HeliumSyncService::OnEnrollmentComplete"),
  );
  const equal = coordinate.indexOf(
    "*cookie_verified_sequence_ != *password_verified_sequence_");
  const acknowledge = coordinate.indexOf("AcknowledgeApplied");
  const complete = coordinate.indexOf("enrollment_client_->CompleteEnrollment");
  assert.ok(equal >= 0 && acknowledge > equal && complete > acknowledge);
  assert.match(coordinate, /cookie_bridge_->PullAndApply\(\)/);
  assert.match(coordinate, /password_bridge_->PullAndApply\(\)/);
});

test("each bridge reports readiness only after durable readback and cursor acknowledgement", () => {
  const passwordFinish = passwords.slice(
    passwords.indexOf("void HeliumPasswordSyncBridge::FinishReconcile"),
    passwords.indexOf("bool HeliumPasswordSyncBridge::LoadState"),
  );
  assert.ok(passwordFinish.indexOf("SaveState()") >= 0);
  assert.ok(passwordFinish.indexOf("AcknowledgeApplied") >
    passwordFinish.indexOf("SaveState()"));
  assert.ok(passwordFinish.indexOf("verified_baseline_callback_.Run") >
    passwordFinish.indexOf("AcknowledgeApplied"));

  const cookieFinish = cookies.slice(
    cookies.indexOf("bool FinishVerifiedInventory"),
    cookies.indexOf("void BeginRemoteApply"),
  );
  assert.ok(cookieFinish.indexOf("SaveState()") >= 0);
  assert.ok(cookieFinish.indexOf("AcknowledgeApplied") >
    cookieFinish.indexOf("SaveState()"));
  assert.ok(cookieFinish.indexOf("verified_baseline_callback_.Run") >
    cookieFinish.indexOf("AcknowledgeApplied"));
});

test("activation reloads immutable client identity before either bridge resumes", () => {
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
  const cookieReload = activated.indexOf("cookie_bridge_->EnrollmentActivated");
  const passwordReload = activated.indexOf(
    "password_bridge_->EnrollmentActivated");
  const failureGate = activated.indexOf("!cookie_active || !password_active");
  const cookiePull = activated.indexOf("cookie_bridge_->PullAndApply");
  const passwordPull = activated.indexOf("password_bridge_->PullAndApply");
  assert.ok(cookieReload >= 0 && passwordReload > cookieReload);
  assert.ok(failureGate > passwordReload);
  assert.ok(cookiePull > failureGate && passwordPull > cookiePull);
});

test("bridge code cannot independently publish or complete pending enrollment", () => {
  assert.doesNotMatch(passwords, /CompleteEnrollment/);
  assert.doesNotMatch(cookies, /CompleteEnrollment/);
  for (const source of [passwords, cookies]) {
    const pending = source.indexOf('enrollment_phase() == "pending"');
    const push = source.indexOf("client_->Push", pending);
    assert.ok(pending >= 0 && push > pending);
  }
});
