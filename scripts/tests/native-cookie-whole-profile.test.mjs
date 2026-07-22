import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import {
  EMPTY_COOKIE_FINGERPRINT,
  decideCookieReconcile,
} from "./cookie-whole-profile-model.mjs";

const repoFile = relative => fs.readFileSync(
  new URL(`../../${relative}`, import.meta.url), "utf8");

const cookie = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc");
const service = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");

const baseline = {
  remoteRevision: 7,
  keyId: "key-a",
  remotePayloadFingerprint: "payload-a",
  baselineLocalFingerprint: "cookies-a",
};
const remote = {
  revision: 7,
  keyId: "key-a",
  payloadFingerprint: "payload-a",
};

test("restart with no cookie mutation publishes nothing", () => {
  assert.deepEqual(decideCookieReconcile({
    state: baseline,
    remote,
    localFingerprint: "cookies-a",
  }), { action: "none" });
});

test("stale local state cannot overwrite a newer remote cookie revision", () => {
  assert.deepEqual(decideCookieReconcile({
    state: baseline,
    remote: { ...remote, revision: 8, payloadFingerprint: "payload-new" },
    localFingerprint: "stale-local-edit",
  }), { action: "stop", reason: "concurrent-local-and-remote-change" });
});

test("key rotation and same-revision payload substitution stop reconciliation", () => {
  assert.deepEqual(decideCookieReconcile({
    state: baseline,
    remote: { ...remote, keyId: "key-b" },
    localFingerprint: "cookies-a",
  }), { action: "stop", reason: "key-epoch-changed" });
  assert.deepEqual(decideCookieReconcile({
    state: baseline,
    remote: { ...remote, payloadFingerprint: "tampered" },
    localFingerprint: "cookies-a",
  }), { action: "stop", reason: "same-revision-payload-changed" });
});

test("fresh profiles never merge unknown local and remote sessions", () => {
  assert.deepEqual(decideCookieReconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "remote" },
    localFingerprint: "unknown-local",
  }), { action: "stop", reason: "uninitialized-local-and-remote-state" });
  assert.deepEqual(decideCookieReconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "remote" },
    localFingerprint: EMPTY_COOKIE_FINGERPRINT,
  }), { action: "apply" });
});

test("pending cookie enrollment records a verified baseline and publishes zero mutations", () => {
  const pendingStart = cookie.indexOf('if (client_->enrollment_phase() == "pending")');
  const pendingEnd = cookie.indexOf("if (!FinishVerifiedInventory())", pendingStart);
  const pendingBranch = cookie.slice(pendingStart, pendingEnd);
  assert.ok(pendingStart >= 0 && pendingEnd > pendingStart);
  assert.match(pendingBranch, /baseline_cookie_fingerprint/);
  assert.match(pendingBranch, /FinishVerifiedInventory\(\)/);
  assert.doesNotMatch(pendingBranch, /client_->Push/);

  const finishStart = cookie.indexOf("bool FinishVerifiedInventory()");
  const finishEnd = cookie.indexOf("void BeginRemoteApply", finishStart);
  const finish = cookie.slice(finishStart, finishEnd);
  assert.match(finish, /AcknowledgeApplied\(pending_next_seq_/);
  assert.match(finish, /verified_baseline_callback_\.Run\(state_\.verified_sequence\)/);
  assert.doesNotMatch(finish, /CompleteEnrollment/);
});

test("ambiguous and confirmed publications cannot create an echo loop", () => {
  const state = {
    ...baseline,
    pendingPublish: {
      expectedRevision: 7,
      targetRevision: 8,
      localFingerprint: "cookies-b",
      payloadFingerprint: "payload-b",
    },
  };
  assert.deepEqual(decideCookieReconcile({
    state,
    remote: { revision: 8, keyId: "key-a", payloadFingerprint: "payload-b" },
    localFingerprint: "cookies-b",
  }), { action: "accept-publication" });
  assert.deepEqual(decideCookieReconcile({
    state,
    remote: { revision: 8, keyId: "key-a", payloadFingerprint: "other" },
    localFingerprint: "cookies-b",
  }), { action: "stop", reason: "publication-cas-conflict" });
});

test("native source is whole-profile, partition-complete, rollback-first, and native-only", () => {
  for (const field of [
    "name", "value", "domain", "path", "creation", "expiry",
    "last_access", "last_update", "secure", "http_only", "same_site",
    "priority", "source_scheme", "source_port", "source_type",
    "partition_key", "top_level_site", "has_cross_site_ancestor",
  ]) {
    assert.match(cookie, new RegExp(`Set\\(\"${field}\"`));
  }
  assert.match(cookie, /GetAllCookies/);
  assert.match(cookie, /SetCanonicalCookie/);
  assert.match(cookie, /DeleteCanonicalCookie/);
  assert.match(cookie, /SealLocalPayload/);
  assert.match(cookie, /OpenLocalPayload/);
  assert.match(cookie, /SaveRollback/);
  assert.match(cookie, /RecoverRollback/);
  assert.match(cookie, /BeginRestore/);
  assert.match(cookie, /expected_revision/);
  assert.match(cookie, /key_id/);
  assert.match(cookie, /enrollment_phase\(\) == "pending"/);
  assert.match(cookie, /verified_sequence/);
  assert.doesNotMatch(cookie, /cookie-policies|CookieCloud|DevTools|CDP/);
  assert.doesNotMatch(service, /cookie-policies/);
});

test("normal launch and seed paths do not invoke historical CookieCloud tooling", () => {
  for (const script of [
    "scripts/laptop/start-helium-sync-local.sh",
    "scripts/android-local/chromium-helium-local-root.sh",
    "scripts/android-local/start-helium-local-sync-root.sh",
    "scripts/android-local/seed-chroot-profile-root.sh",
  ]) {
    const source = repoFile(script);
    assert.doesNotMatch(source, /cdp-cookiecloud|helium-local-syncd|COOKIECLOUD/);
  }
  assert.match(repoFile("scripts/android-local/cdp-cookiecloud.mjs"),
    /cdp-cookiecloud\.mjs/);
  for (const installer of [
    "scripts/laptop/install-laptop-sync.sh",
    "scripts/android-local/install-phone-sync.sh",
  ]) {
    const source = repoFile(installer);
    assert.doesNotMatch(source,
      /cdp-cookiecloud|cdp-password-sync|helium-local-syncd|cookiecloud-extension/);
  }
});

test("native sync has one fail-closed profile-local enrollment source", () => {
  assert.match(service, /profile->GetPath\(\)\.AppendASCII\(kConfigDir\)/);
  assert.match(service, /SchemeIs\(url::kHttpsScheme\)/);
  assert.match(service, /kClientStateFile/);
  assert.match(service, /phase != "pending".*phase != "active"/s);
  assert.doesNotMatch(service, /CandidateConfigPaths|kDefaultBaseUrl|ReadDeviceName/);
  assert.doesNotMatch(service, /DIR_HOME|DIR_USER_DATA|OperatingSystemName/);
  assert.doesNotMatch(service, /profile->GetPath\(\)\.AsUTF8Unsafe/);

  for (const script of [
    "scripts/laptop/start-helium-sync-local.sh",
    "scripts/android-local/chromium-helium-local-root.sh",
  ]) {
    const source = repoFile(script);
    assert.match(source, /client\.json/);
    assert.match(source, /\^https:\/\//);
    assert.doesNotMatch(source, />"\$sync_config_dir\/base_url"/);
    assert.doesNotMatch(source, />"\$sync_config_dir\/device_name"/);
  }
  assert.match(repoFile("scripts/android-local/seed-chroot-profile-root.sh"),
    /CDP password seeding has been removed/);
});
