import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import {
  applyCookieTransaction,
  canonicalCookieIdentity,
  EMPTY_COOKIE_FINGERPRINT,
  decideCookieReconcile,
  migrateCookieStateV2,
  previewCookieTransaction,
  scopeDestinationRejection,
} from "./cookie-whole-profile-model.mjs";

const repoFile = relative => fs.readFileSync(
  new URL(`../../${relative}`, import.meta.url), "utf8");

const cookie = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc");
const client = repoFile(
  "chromium/overlay/components/helium_sync/helium_sync_client.cc");
const clientHeader = repoFile(
  "chromium/overlay/components/helium_sync/helium_sync_client.h");
const enrollmentCLI = repoFile("cmd/helium-sync/main.go");
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
const reconcile = input => decideCookieReconcile({
  activeKeyId: "key-a",
  ...input,
});

const firstCookie = {
  name: "session",
  value: "generation-one",
  domain: ".fixture.invalid",
  path: "/",
  sourceScheme: 2,
  sourcePort: 443,
  secure: true,
  httpOnly: true,
  partitionKey: null,
};

test("disposable canonical identity preserves partition and source dimensions", () => {
  const partitioned = {
    ...firstCookie,
    partitionKey: {
      topLevelSite: "https://top.fixture",
      hasCrossSiteAncestor: false,
    },
  };
  const crossSitePartitioned = {
    ...partitioned,
    partitionKey: { ...partitioned.partitionKey, hasCrossSiteAncestor: true },
  };
  const identities = [
    firstCookie,
    { ...firstCookie, domain: "fixture.invalid" },
    { ...firstCookie, sourcePort: 8443 },
    partitioned,
    crossSitePartitioned,
  ].map(canonicalCookieIdentity);
  assert.equal(new Set(identities).size, identities.length);
});

test("disposable cookie preview commits exact target and rolls back rejection", () => {
  const secondCookie = {
    ...firstCookie,
    name: "rotation",
    value: "generation-two",
  };
  const replacement = { ...firstCookie, value: "generation-three" };
  const preview = previewCookieTransaction(
    [firstCookie, secondCookie],
    [
      { action: "set", cookie: replacement },
      { action: "delete", cookie: secondCookie },
    ],
  );
  assert.equal(preview.setCount, 1);
  assert.equal(preview.deleteCount, 1);
  assert.notEqual(preview.beforeFingerprint, preview.targetFingerprint);
  assert.deepEqual(applyCookieTransaction(preview), {
    status: "committed",
    cookies: preview.targetCookies,
  });

  const rejected = applyCookieTransaction(preview, {
    rejectIdentity: canonicalCookieIdentity(secondCookie),
  });
  assert.equal(rejected.status, "rolled-back");
  assert.deepEqual(rejected.cookies, preview.beforeCookies);
});

test("restart with no cookie mutation publishes nothing", () => {
  assert.deepEqual(reconcile({
    state: baseline,
    remote,
    localFingerprint: "cookies-a",
  }), { action: "none" });
});

test("stale local state cannot overwrite a newer remote cookie revision", () => {
  assert.deepEqual(reconcile({
    state: baseline,
    remote: { ...remote, revision: 8, payloadFingerprint: "payload-new" },
    localFingerprint: "stale-local-edit",
  }), { action: "stop", reason: "concurrent-local-and-remote-change" });
});

test("active-epoch CAS rekey advances while stale and same-revision epochs stop", () => {
  assert.deepEqual(reconcile({
    state: baseline,
    remote: { ...remote, keyId: "key-b" },
    localFingerprint: "cookies-a",
  }), { action: "stop", reason: "same-revision-key-epoch-changed" });
  assert.deepEqual(reconcile({
    state: baseline,
    remote: {
      ...remote,
      revision: 8,
      keyId: "key-b",
      payloadFingerprint: "payload-rekeyed",
    },
    localFingerprint: "cookies-a",
    activeKeyId: "key-b",
  }), { action: "apply" });
  assert.deepEqual(reconcile({
    state: baseline,
    remote: {
      ...remote,
      revision: 8,
      payloadFingerprint: "payload-stale-epoch",
    },
    localFingerprint: "cookies-a",
    activeKeyId: "key-b",
  }), { action: "stop", reason: "newer-record-uses-stale-key-epoch" });
  assert.deepEqual(reconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "stale" },
    localFingerprint: EMPTY_COOKIE_FINGERPRINT,
    activeKeyId: "key-b",
  }), { action: "stop", reason: "initial-record-uses-stale-key-epoch" });
  assert.deepEqual(reconcile({
    state: baseline,
    remote: { ...remote, payloadFingerprint: "tampered" },
    localFingerprint: "cookies-a",
  }), { action: "stop", reason: "same-revision-payload-changed" });
});

test("fresh profiles never merge unknown local and remote sessions", () => {
  assert.deepEqual(reconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "remote" },
    localFingerprint: "unknown-local",
  }), { action: "stop", reason: "uninitialized-local-and-remote-state" });
  assert.deepEqual(reconcile({
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
  assert.deepEqual(reconcile({
    state,
    remote: { revision: 8, keyId: "key-a", payloadFingerprint: "payload-b" },
    localFingerprint: "cookies-b",
  }), { action: "accept-publication" });
  assert.deepEqual(reconcile({
    state,
    remote: { revision: 8, keyId: "key-a", payloadFingerprint: "other" },
    localFingerprint: "cookies-b",
  }), { action: "stop", reason: "publication-cas-conflict" });
});

test("destination rejection is exact and revision-scoped, then later state retries", () => {
  const recordKey = canonicalCookieIdentity(firstCookie);
  const destinationException = scopeDestinationRejection({
    cookie: firstCookie,
    remote: { recordKey, revision: 7, payloadFingerprint: "payload-a" },
    site: "https://fixture.invalid",
    observedSessions: [
      { site: "https://fixture.invalid", sessionId: "session-b" },
      { site: "https://fixture.invalid", sessionId: "session-a" },
      { site: "https://other.invalid", sessionId: "other-session" },
    ],
  });
  assert.equal(destinationException.recordKey, recordKey);
  assert.deepEqual(destinationException.observedSessions.map(item => item.sessionId),
    ["session-a", "session-b"]);
  assert.throws(() => scopeDestinationRejection({
    cookie: firstCookie,
    remote: { recordKey, revision: 7, payloadFingerprint: "payload-a" },
    site: "https://fixture.invalid",
    observedSessions: [
      { site: "https://fixture.invalid", sessionId: "duplicate" },
      { site: "https://fixture.invalid", sessionId: "duplicate" },
    ],
  }), /duplicate observed device-bound session identity/);
  assert.notEqual(scopeDestinationRejection({
    cookie: { ...firstCookie, name: "other" },
    remote: {
      recordKey: canonicalCookieIdentity({ ...firstCookie, name: "other" }),
      revision: 7,
      payloadFingerprint: "payload-other",
    },
    site: "https://fixture.invalid",
  }).recordKey, recordKey);

  const rejectedState = { ...baseline, destinationException };
  assert.deepEqual(reconcile({
    state: rejectedState,
    remote,
    recordKey,
    localFingerprint: "cookies-a",
  }), { action: "none" });
  assert.deepEqual(reconcile({
    state: rejectedState,
    remote,
    recordKey,
    localFingerprint: "reauthenticated-local",
  }), { action: "publish", expectedRevision: 7 });
  assert.deepEqual(reconcile({
    state: rejectedState,
    remote: { ...remote, revision: 8, payloadFingerprint: "payload-later" },
    recordKey,
    localFingerprint: "cookies-a",
  }), { action: "apply" });
  assert.deepEqual(reconcile({
    state: {
      ...rejectedState,
      destinationException: {
        ...destinationException,
        remoteRevision: 6,
      },
    },
    remote,
    recordKey,
    localFingerprint: "cookies-a",
  }), { action: "stop", reason: "destination-exception-scope-mismatch" });
});

test("schema-2 cookie state migrates without preserving site-wide exceptions", () => {
  const migrated = migrateCookieStateV2({
    schema_version: 2,
    verified_sequence: "91",
    records: {
      [canonicalCookieIdentity(firstCookie)]: {
        remote_revision: "7",
        key_id: "key-a",
        device_id: "device-a",
        remote_payload_fingerprint: "payload-a",
        baseline_cookie_fingerprint: "cookies-a",
        remote_deleted: false,
        non_clonable: true,
        non_clonable_reason: "device-bound-session",
        site: "https://fixture.invalid",
        pending_publish: {
          expected_revision: "7",
          target_revision: "8",
          payload_fingerprint: "pending-payload",
          cookie_fingerprint: "pending-cookie",
          deleted: false,
        },
      },
    },
  });
  const migratedRecord = migrated.records[canonicalCookieIdentity(firstCookie)];
  assert.equal(migrated.schema_version, 3);
  assert.equal(migrated.verified_sequence, "91");
  assert.equal(migratedRecord.remote_revision, "7");
  assert.equal(migratedRecord.remote_payload_fingerprint, "payload-a");
  assert.equal(migratedRecord.pending_publish.target_revision, "8");
  assert.equal("non_clonable" in migratedRecord, false);
  assert.equal("non_clonable_reason" in migratedRecord, false);
  assert.equal("site" in migratedRecord, false);
  assert.throws(() => migrateCookieStateV2({
    schema_version: 2,
    records: [],
  }), /invalid cookie state schema 2 document/);
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
  assert.match(cookie, /cookie-post-apply-verification-mismatch/);
  assert.match(cookie, /cookie-rollback-verification-failed/);
  assert.match(cookie, /canonical_cookie_record_key/);
  assert.match(cookie, /remote_revision/);
  assert.match(cookie, /observed_site_sessions/);
  assert.match(cookie, /session->id/);
  assert.match(cookie, /pending-browser-integration/);
  assert.match(cookie, /client_->active_key_id\(\)/);
  assert.match(cookie, /cookie-newer-record-uses-stale-key-epoch/);
  assert.match(cookie, /schema-v2\.bak/);
  assert.match(cookie, /return !migrate_schema_v2 \|\| SaveState\(\)/);
  assert.match(clientHeader, /active_key_id\(\) const/);
  assert.match(client, /sync response uses an unknown content key epoch/);
  assert.match(enrollmentCLI, /const cookieBridgeStateSchema = 3/);
  assert.equal((enrollmentCLI.match(/cookieBridgeStateSchema/g) ?? []).length, 3);
  assert.doesNotMatch(cookie, /device_bound_sites|non_clonable|auxiliary_state/);
  assert.match(cookie, /expected_revision/);
  assert.match(cookie, /key_id/);
  assert.match(cookie, /enrollment_phase\(\) == "pending"/);
  assert.match(cookie, /verified_sequence/);
  assert.doesNotMatch(cookie, /cookie-policies|CookieCloud|DevTools|CDP/);
  assert.doesNotMatch(service, /cookie-policies/);
});

test("normal composition contains only the native password and cookie path", () => {
  const forbidden =
    /CookieCloud|cdp-cookiecloud|cdp-password-sync|helium-local-syncd|cookiecloud-extension|start-helium-local-sync|seed-chroot-profile|browserpass|helium-prepare-profile|helium-cleanup-startup-tabs/i;
  for (const script of [
    ".github/workflows/go-sync.yml",
    "scripts/laptop/install-laptop-sync.sh",
    "scripts/laptop/start-helium-sync-local.sh",
    "scripts/android-local/install-phone-sync.sh",
    "scripts/android-local/configure-android-chromium-sync.sh",
    "scripts/android-local/install-chroot-helium.sh",
    "scripts/android-local/chromium-helium-local-root.sh",
    "scripts/android-local/start-arch-xmonad-root.sh",
    "scripts/android-local/arch-desktop-resume-root.sh",
    "scripts/android-local/arch-desktop-attach-root.sh",
    "scripts/android-local/restart-chroot-helium-browser-root.sh",
    "scripts/android-local/stop-arch-x11-root.sh",
  ]) {
    assert.doesNotMatch(repoFile(script), forbidden, script);
  }
  for (const obsolete of [
    "cmd/helium-local-syncd/main.go",
    "cmd/helium-local-syncd/main_test.go",
    "scripts/android-local/cdp-cookiecloud.mjs",
    "scripts/android-local/cdp-password-sync.mjs",
    "scripts/android-local/cookie-replication.mjs",
    "scripts/android-local/password-reconcile.mjs",
    "scripts/android-local/fetch-cookiecloud-extension.sh",
    "scripts/android-local/start-helium-local-sync-root.sh",
    "scripts/android-local/seed-chroot-profile-root.sh",
    "scripts/android-local/helium-prepare-profile-root.py",
    "scripts/android-local/helium-cleanup-startup-tabs-root.py",
  ]) {
    assert.equal(fs.existsSync(new URL(`../../${obsolete}`, import.meta.url)),
      false, obsolete);
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
});
