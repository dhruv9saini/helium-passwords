import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

import {
  applyCookieTransaction,
  buildReauthenticationIntent,
  canonicalCookieIdentity,
  EMPTY_COOKIE_FINGERPRINT,
  decideCookieReconcile,
  migrateCookieStateToV4,
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

test("pending join transactionally replaces a colliding local cookie", () => {
  assert.deepEqual(reconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "seed-value" },
    localFingerprint: "joiner-local-value",
    pendingEnrollment: true,
  }), { action: "apply" });
  assert.deepEqual(reconcile({
    state: null,
    remote: { revision: 1, keyId: "key-a", payloadFingerprint: "seed-value" },
    localFingerprint: "joiner-local-value",
  }), { action: "stop", reason: "uninitialized-local-and-remote-state" });

  const initial = cookie.slice(
    cookie.indexOf("if (state_it == state_.records.end()"),
    cookie.indexOf("RecordState& established"),
  );
  assert.match(initial, /client_->enrollment_phase\(\) == "pending"/);
  assert.ok(initial.indexOf('enrollment_phase() == "pending"') <
    initial.indexOf("apply_updates.emplace"));
});

test("whole-profile cookie publication drains in bounded batches", () => {
  const keys = Array.from({ length: 70 }, (_, index) =>
    index.toString().padStart(3, "0"));
  const batches = [];
  while (keys.length > 0) batches.push(keys.splice(0, 32));
  assert.deepEqual(batches.map(batch => batch.length), [32, 32, 6]);

  const nonceBytes = 12;
  const authenticationTagBytes = 16;
  const maximumPayloadBytes = 64 * 1024;
  const base64Bytes = bytes => 4 * Math.ceil(bytes / 3);
  const conservativeRecordMetadataBytes = 1024;
  const worstBatchBytes = 128 + 32 * (
    base64Bytes(maximumPayloadBytes + authenticationTagBytes) +
    base64Bytes(nonceBytes) + conservativeRecordMetadataBytes
  );
  assert.ok(worstBatchBytes < 4 * 1024 * 1024);
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
    schemefulSite: "https://fixture.invalid",
    observedSessions: [
      { schemefulSite: "https://fixture.invalid", sessionId: "session-b" },
      { schemefulSite: "https://fixture.invalid", sessionId: "session-a" },
      { schemefulSite: "https://other.invalid", sessionId: "other-session" },
    ],
  });
  assert.equal(destinationException.recordKey, recordKey);
  assert.deepEqual(destinationException.observedSessions.map(item => item.sessionId),
    ["session-a", "session-b"]);
  assert.throws(() => scopeDestinationRejection({
    cookie: firstCookie,
    remote: { recordKey, revision: 7, payloadFingerprint: "payload-a" },
    schemefulSite: "https://fixture.invalid",
    observedSessions: [
      { schemefulSite: "https://fixture.invalid", sessionId: "duplicate" },
      { schemefulSite: "https://fixture.invalid", sessionId: "duplicate" },
    ],
  }), /duplicate observed device-bound session identity/);
  assert.notEqual(scopeDestinationRejection({
    cookie: { ...firstCookie, name: "other" },
    remote: {
      recordKey: canonicalCookieIdentity({ ...firstCookie, name: "other" }),
      revision: 7,
      payloadFingerprint: "payload-other",
    },
    schemefulSite: "https://fixture.invalid",
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
  }), {
    action: "hold-local",
    reason: "destination-exception-local-change-unverified",
  });
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

  const publishStart = cookie.indexOf("void PublishLocalMutations");
  const publishEnd = cookie.indexOf("void OnPushComplete", publishStart);
  const publish = cookie.slice(publishStart, publishEnd);
  assert.match(publish,
    /state_it->second\.destination_exception[\s\S]*continue;/);
  assert.match(publish,
    /record_state\.destination_exception[\s\S]*continue;/);
});

test("reauthentication intent cannot guess an origin, navigate, or submit", () => {
  const recordKey = canonicalCookieIdentity(firstCookie);
  const intent = buildReauthenticationIntent([{
    recordKey,
    remoteRevision: 7,
    remotePayloadFingerprint: "a".repeat(64),
    reason: "destination-set-rejected",
    schemefulSite: "https://fixture.invalid",
    observedSessions: [{
      schemefulSite: "https://fixture.invalid",
      sessionId: "dbsc-fixture-session",
    }],
    unverifiedLocalChange: true,
  }]);
  assert.equal(intent.schema_version, 3);
  assert.equal(intent.status,
    "blocked-no-exact-origin-or-login-entry-evidence");
  assert.equal(intent.navigation_allowed, false);
  assert.equal(intent.automatic_form_submission_allowed, false);
  assert.equal(intent.targets[0].schemeful_site, "https://fixture.invalid");
  assert.equal(intent.targets[0].origin_status, "unavailable-not-observed");
  assert.equal(intent.targets[0].login_entry_status,
    "unavailable-not-observed");
  assert.equal(intent.targets[0].unverified_local_cookie_change, true);
  assert.equal("origin" in intent.targets[0], false);
  assert.equal("login_entry" in intent.targets[0], false);

  assert.deepEqual(buildReauthenticationIntent([]), {
    schema_version: 3,
    action: "browser-native-password-reauthentication",
    status: "idle",
    reason: "destination-cookie-rejected",
    navigation_allowed: false,
    automatic_form_submission_allowed: false,
    targets: [],
  });
  assert.throws(() => buildReauthenticationIntent([{
    recordKey,
    remoteRevision: 7,
    remotePayloadFingerprint: "a".repeat(64),
    reason: "destination-set-rejected",
    schemefulSite: "https://fixture.invalid/login",
    observedSessions: [],
    unverifiedLocalChange: false,
  }]), /invalid schemeful site/);
});

test("cookie state migrations remove broad exceptions and name schemeful sites exactly", () => {
  const migrated = migrateCookieStateToV4({
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
  assert.equal(migrated.schema_version, 4);
  assert.equal(migrated.verified_sequence, "91");
  assert.equal(migratedRecord.remote_revision, "7");
  assert.equal(migratedRecord.remote_payload_fingerprint, "payload-a");
  assert.equal(migratedRecord.pending_publish.target_revision, "8");
  assert.equal("non_clonable" in migratedRecord, false);
  assert.equal("non_clonable_reason" in migratedRecord, false);
  assert.equal("site" in migratedRecord, false);
  const migratedV3 = migrateCookieStateToV4({
    schema_version: 3,
    verified_sequence: "92",
    records: {
      [canonicalCookieIdentity(firstCookie)]: {
        remote_revision: "8",
        key_id: "key-a",
        device_id: "device-a",
        remote_payload_fingerprint: "b".repeat(64),
        baseline_cookie_fingerprint: "cookies-b",
        remote_deleted: false,
        destination_exception: {
          remote_revision: "8",
          remote_payload_fingerprint: "b".repeat(64),
          reason: "destination-set-rejected",
          site: "https://fixture.invalid",
          observed_session_ids: [],
        },
      },
    },
  });
  assert.equal(migratedV3.schema_version, 4);
  const migratedV3Exception =
    migratedV3.records[canonicalCookieIdentity(firstCookie)].destination_exception;
  assert.equal(migratedV3Exception.schemeful_site, "https://fixture.invalid");
  assert.equal(migratedV3Exception.unverified_local_change, false);
  assert.equal("site" in migratedV3Exception, false);

  assert.throws(() => migrateCookieStateToV4({
    schema_version: 2,
    records: [],
  }), /invalid cookie state migration document/);
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
  assert.match(cookie, /blocked-no-exact-origin-or-login-entry-evidence/);
  assert.match(cookie, /navigation_allowed", false/);
  assert.match(cookie, /automatic_form_submission_allowed", false/);
  assert.match(cookie, /origin_status", "unavailable-not-observed"/);
  assert.match(cookie, /login_entry_status", "unavailable-not-observed"/);
  assert.match(cookie, /unverified_local_change/);
  assert.match(cookie, /record_state\.destination_exception/);
  assert.match(cookie, /client_->active_key_id\(\)/);
  assert.match(cookie, /cookie-newer-record-uses-stale-key-epoch/);
  assert.match(cookie, /schema-v2\.bak/);
  assert.match(cookie, /schema-v3\.bak/);
  assert.match(cookie,
    /return \(!migrate_schema_v2 && !migrate_schema_v3\) \|\| SaveState\(\)/);
  assert.match(clientHeader, /active_key_id\(\) const/);
  assert.match(client, /sync response uses an unknown content key epoch/);
  assert.match(enrollmentCLI, /const cookieBridgeStateSchema = 4/);
  assert.equal((enrollmentCLI.match(/cookieBridgeStateSchema/g) ?? []).length, 3);
  assert.doesNotMatch(cookie, /device_bound_sites|non_clonable|auxiliary_state/);
  assert.match(cookie, /expected_revision/);
  assert.match(cookie, /kMaxCookiePushRecords = 32/);
  assert.equal((cookie.match(/mutations\.size\(\) == kMaxCookiePushRecords/g) ?? []).length, 2);
  assert.match(cookie, /key_id/);
  assert.match(cookie, /enrollment_phase\(\) == "pending"/);
  assert.match(cookie, /verified_sequence/);
  assert.doesNotMatch(cookie, /cookie-policies|CookieCloud|DevTools|CDP/);
  assert.doesNotMatch(service, /cookie-policies/);
  assert.match(client, /kMaxSyncRequestBytes = 4 \* 1024 \* 1024/);
  assert.match(client, /body_json\.size\(\) > kMaxSyncRequestBytes/);
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
