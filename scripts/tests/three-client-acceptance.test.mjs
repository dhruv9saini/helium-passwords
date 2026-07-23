import assert from "node:assert/strict";
import crypto from "node:crypto";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  captureStep,
  NATIVE_PASSWORD_STEPS,
  verifyRun,
} from "../password-runtime/acceptance.mjs";
import {
  auditVerifiedSyncRun,
  captureSyncStep,
  verifySyncRun,
} from "../password-runtime/sync-acceptance.mjs";
import {
  acceptanceStatus,
  auditVerifiedThreeClientRun,
  initializeThreeClientRun,
  validateBrowserEvidence,
  validateServerEvidence,
  verifyThreeClientRun,
} from "../sync-runtime/three-client-acceptance.mjs";

const credentialKey = `credential/v2/${"c".repeat(64)}`;
const cookieKey = "d".repeat(64);
const keyID = "a1b2c3d4e5f60708";
const TRAIN = Object.freeze({
  source_commit: "1".repeat(40),
  core_commit: "2".repeat(40),
  chromium_commit: "3".repeat(40),
  chromium_version: "150.0.7871.181",
});
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

function digest(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

async function writeJSON(filePath, value) {
  await fsp.writeFile(filePath, `${JSON.stringify(value)}\n`, {mode: 0o600});
}

async function writeLinuxArtifactReceipt(root, artifact, arch) {
  const artifactHash = digest(await fsp.readFile(artifact));
  const bundle = path.join(root, `helium-passwords-linux-${arch}`);
  const runtime = path.join(bundle, "runtime");
  const provenance = path.join(bundle, "provenance");
  const browser = path.join(runtime, "helium");
  await fsp.mkdir(runtime, {recursive: true});
  await fsp.mkdir(provenance, {recursive: true});
  await fsp.writeFile(browser, "synthetic browser binary", {mode: 0o700});
  const inventory = path.join(provenance, "runtime.sha256");
  const entries = [artifact, browser].sort();
  const inventoryRaw = `${(await Promise.all(entries.map(async file => {
    const hash = digest(await fsp.readFile(file));
    return `${hash}  ${path.relative(bundle, file)}`;
  }))).join("\n")}\n`;
  await fsp.writeFile(inventory, inventoryRaw, {mode: 0o600});
  const receipt = path.join(root, `${arch}-artifact-receipt.env`);
  await fsp.writeFile(receipt, [
    "schema_version=2",
    "product=helium-passwords",
    "platform=linux",
    `arch=${arch}`,
    `source_commit=${TRAIN.source_commit}`,
    `helium_core_commit=${TRAIN.core_commit}`,
    `chromium_version=${TRAIN.chromium_version}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    `platform_commit=${"4".repeat(40)}`,
    `bundle=${path.join(root, "bundle.tar.xz")}`,
    `bundle_sha256=${"5".repeat(64)}`,
    `provenance_manifest_sha256=${"6".repeat(64)}`,
    `browser_executable=${path.relative(root, artifact)}`,
    `browser_sha256=${artifactHash}`,
    `runtime_inventory=${path.relative(root, inventory)}`,
    `runtime_inventory_sha256=${digest(inventoryRaw)}`,
    "verified_at=synthetic-fixture",
    "",
  ].join("\n"), {mode: 0o600});
  return receipt;
}

async function writeAndroidAdmission(root) {
  const prepared = path.join(root, "oneplus-prepared");
  const provenance = path.join(prepared, "build-provenance");
  const runtime = path.join(prepared, "runtime-acceptance");
  const artifact = path.join(prepared, "Browser-test.apk");
  await fsp.mkdir(provenance, {recursive: true});
  await fsp.mkdir(runtime, {recursive: true});
  await fsp.writeFile(artifact, "synthetic OnePlus APK", {mode: 0o600});
  await fsp.writeFile(path.join(runtime, "fixture.txt"),
    "synthetic Android runtime kit\n", {mode: 0o600});
  await fsp.writeFile(path.join(runtime, "kit.env"), [
    "schema_version=6",
    `helium_sync_commit=${TRAIN.source_commit}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    "manifest_package=computer.helium.sync.test",
    "target_cpu=arm64",
    "",
  ].join("\n"), {mode: 0o600});
  await fsp.writeFile(path.join(provenance, "helium-sync-commit.txt"),
    `${TRAIN.source_commit}\n`, {mode: 0o600});
  await fsp.writeFile(path.join(provenance, "helium-core-commit.txt"),
    `${TRAIN.core_commit}\n`, {mode: 0o600});
  await fsp.writeFile(path.join(provenance, "chromium-source-commit.txt"),
    `${TRAIN.chromium_commit}\n`, {mode: 0o600});
  const artifactHash = digest(await fsp.readFile(artifact));
  await fsp.writeFile(path.join(prepared, "acceptance.env"), [
    "schema_version=2",
    "package=computer.helium.sync.test",
    `helium_sync_commit=${TRAIN.source_commit}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    "version_code=787500005",
    `version_name=${TRAIN.chromium_version}`,
    `source_archive_sha256=${"3".repeat(64)}`,
    `apk_sha256=${artifactHash}`,
    `runtime_kit_sha256=${"4".repeat(64)}`,
    "prepared_at=2026-07-23T08:00:00Z",
    "",
  ].join("\n"), {mode: 0o600});
  const files = [
    "Browser-test.apk",
    "acceptance.env",
    "build-provenance/chromium-source-commit.txt",
    "build-provenance/helium-core-commit.txt",
    "build-provenance/helium-sync-commit.txt",
    "runtime-acceptance/fixture.txt",
    "runtime-acceptance/kit.env",
  ];
  const inventory = `${(await Promise.all(files.map(async relative =>
    `${digest(await fsp.readFile(path.join(prepared, relative)))}  ./${relative}`
  ))).join("\n")}\n`;
  await fsp.writeFile(
    path.join(prepared, "PACKAGE_SHA256SUMS"), inventory, {mode: 0o600});
  return artifact;
}

function passwordState(revision, fingerprint, deleted) {
  return {
    schema_version: 4,
    identity_schema: "password-form-unique-key-v2",
    migration_status: "complete",
    legacy_credentials: {},
    verified_sequence: String(revision),
    credentials: {
      [credentialKey]: {
        fingerprint,
        remote_seq: String(revision),
        revision: String(revision),
        deleted,
        key_id: keyID,
      },
    },
  };
}

function journalRecord(sequence, revision, deleted, device) {
  return JSON.stringify({
    seq: String(sequence),
    kind: "passwords",
    key: credentialKey,
    revision: String(revision),
    deleted,
    device_id: device,
    key_id: keyID,
    nonce: `opaque-nonce-${sequence}`,
    ciphertext: `opaque-ciphertext-${sequence}`,
  });
}

function fixtureEvidence(runNonce) {
  return {
    schema_version: 2,
    completed_at: new Date().toISOString(),
    fixture_origin: "http://127.0.0.1:44722",
    observations: {
      initial_login_accepted: true,
      saved_restart_matches: true,
      update_current_matches: true,
      update_changes_password: true,
      generated_candidate_minimum_length: true,
      updated_restart_matches: true,
      deleted_restart_empty: true,
    },
    evidence_contains_submitted_values: false,
    run_nonce: runNonce,
  };
}

async function completeNativeUI(manifest, root, device) {
  const nativeRun = manifest.devices[device].native_run;
  const screenshot = path.join(root, `${device}-native-screen.png`);
  const statePath = path.join(root, `${device}-password-state.json`);
  const journalPath = path.join(root, `${device}-records.jsonl`);
  await fsp.writeFile(screenshot, PNG, {mode: 0o600});
  const snapshots = {
    saved_store: {
      state: passwordState(1, "1".repeat(64), false),
      journal: `${journalRecord(1, 1, false, device)}\n`,
    },
    saved_restart_autofill: {
      state: passwordState(1, "1".repeat(64), false),
      journal: `${journalRecord(1, 1, false, device)}\n`,
    },
    updated_store: {
      state: passwordState(2, "2".repeat(64), false),
      journal: `${journalRecord(1, 1, false, device)}\n${journalRecord(2, 2, false, device)}\n`,
    },
    updated_restart_autofill: {
      state: passwordState(2, "2".repeat(64), false),
      journal: `${journalRecord(1, 1, false, device)}\n${journalRecord(2, 2, false, device)}\n`,
    },
    deleted_store: {
      state: passwordState(3, "", true),
      journal: `${journalRecord(1, 1, false, device)}\n${journalRecord(2, 2, false, device)}\n${journalRecord(3, 3, true, device)}\n`,
    },
    deleted_restart_empty: {
      state: passwordState(3, "", true),
      journal: `${journalRecord(1, 1, false, device)}\n${journalRecord(2, 2, false, device)}\n${journalRecord(3, 3, true, device)}\n`,
    },
  };
  for (const step of NATIVE_PASSWORD_STEPS) {
    await captureStep({
      runRoot: nativeRun,
      step,
      screenshot,
    });
    const snapshot = snapshots[step];
    if (!snapshot) continue;
    await writeJSON(statePath, snapshot.state);
    await fsp.writeFile(journalPath, snapshot.journal, {mode: 0o600});
    await captureSyncStep({
      runRoot: nativeRun,
      step,
      passwordState: statePath,
      journal: journalPath,
    });
  }
  const publicRun = JSON.parse(
    await fsp.readFile(path.join(nativeRun, "run.json"), "utf8"),
  );
  const evidencePath = path.join(nativeRun, "fixture-evidence.json");
  await writeJSON(evidencePath, fixtureEvidence(publicRun.run_nonce));
  await verifyRun({
    runRoot: nativeRun,
    fixtureEvidence: evidencePath,
  });
  await verifySyncRun({
    runRoot: nativeRun,
    fixtureEvidence: evidencePath,
  });
}

function browserEvidence(manifest, nativeUIReceiptSHA256 = {
  d: "6".repeat(64),
  da: "7".repeat(64),
  oneplus: "8".repeat(64),
}) {
  const restart = (device, sequence, hash) => {
    const admitted = manifest.devices[device];
    return {
      device,
      platform: admitted.platform,
      target: admitted.target,
      package: admitted.package,
      artifact_sha256: admitted.artifact_sha256,
      admission_sha256: {
        receipt: admitted.admission.receipt_sha256,
        inventory: admitted.admission.inventory_sha256,
      },
      profile_marker_sha256: admitted.profile_marker_sha256,
      native_ui_receipt_sha256: nativeUIReceiptSHA256[device],
      role: device === "d" ? "seed" : "join",
      phase_before: device === "d" ? "new" : "pending",
      phase_after: "active",
      initial_sync: {
        server_sequence: device === "d" ? "3" : "4",
        password_revision: "1",
        cookie_revision: "1",
        password_apply: "verified",
        cookie_apply: "verified",
        password_readback: "exact",
        cookie_readback: "exact",
        initial_publications: {
          passwords: device === "d" ? "1" : "0",
          cookies: device === "d" ? "3" : "0",
        },
      },
      unchanged_restart: {
        before_sequence: sequence,
        after_sequence: sequence,
        before_state_sha256: hash,
        after_state_sha256: hash,
        before_journal_sha256: "e".repeat(64),
        after_journal_sha256: "e".repeat(64),
        password_publications: "0",
        cookie_publications: "0",
      },
    };
  };
  const applications = [];
  for (const device of ["d", "da", "oneplus"]) {
    for (const revision of ["1", "2", "3"]) {
      applications.push({
        device,
        revision,
        deleted: revision === "3",
        apply: "verified",
        store_readback: "exact",
      });
    }
  }
  const imported = device => ({
    device,
    revision: "1",
    transaction: {
      preview: "verified",
      apply: "verified",
      readback: "exact",
      destination_snapshot: "sealed",
      rollback: "not-needed",
    },
    authenticated_request: {
      origin: "https://session.fixture.invalid",
      response_status: 200,
      result: "authenticated",
      evidence_ref: `${device}-authenticated-request`,
      evidence_sha256: (device === "da" ? "7" : "8").repeat(64),
    },
  });
  const rotation = (expected, revision) => ({
    source_device: "d",
    expected_revision: expected,
    revision,
    destinations: ["da", "oneplus"].map(device => ({
      device,
      apply: "verified",
      readback: "exact",
      echo_publications: "0",
    })),
  });
  return {
    schema_version: 1,
    evidence_scope: "disposable-browser",
    writer: "native-password-store-and-cookie-manager",
    source_train: manifest.source_train,
    tabs_observed: false,
    devices: [
      restart("d", "9", "a".repeat(64)),
      restart("da", "10", "b".repeat(64)),
      restart("oneplus", "10", "c".repeat(64)),
    ],
    password: {
      record_key: credentialKey,
      seed_source: "d",
      seed_revision: "1",
      update_source: "da",
      update_revision: "2",
      delete_source: "da",
      tombstone_revision: "3",
      applications,
      stale_conflict: {
        device: "oneplus",
        expected_revision: "1",
        authoritative_revision: "2",
        result: "revision-conflict",
        accepted_publications: "0",
        authoritative_preserved: true,
        local_preserved: true,
      },
    },
    cookies: {
      record_set_sha256: "f".repeat(64),
      rotating_record_key: cookieKey,
      record_count: 3,
      attribute_coverage: {
        session: true,
        persistent: true,
        http_only: true,
        secure: true,
        same_site: true,
        host_only: true,
        domain: true,
        partitioned: true,
        unpartitioned: true,
        source_scheme_port: true,
      },
      canonical_keys_unique: true,
      partitioned_unpartitioned_distinct: true,
      imports: [imported("da"), imported("oneplus")],
      rotations: [rotation("1", "2"), rotation("2", "3")],
      conflict: {
        device: "oneplus",
        baseline_revision: "3",
        remote_revision: "4",
        remote_source: "d",
        action: "stop",
        reason: "concurrent-local-and-remote-change",
        transaction: {
          preview: "verified",
          apply: "stopped",
          readback: "not-run",
          destination_snapshot: "sealed",
          rollback: "exact",
        },
        last_good_local_preserved: true,
        accepted_publications: "0",
      },
      loop_prevention: {
        device: "oneplus",
        remote_revision: "4",
        repeated_apply_count: "0",
        echo_publications: "0",
        last_good_local_preserved: true,
      },
      destination_exceptions: [],
      origin_state_adapter_count: 0,
      arbitrary_database_merge: false,
    },
  };
}

function serverEvidence(manifest, browser) {
  return {
    schema_version: 1,
    source_train: manifest.source_train,
    evidence_scope: "disposable-tls-service",
    transport: {
      tls: "verified",
      network: "tailscale",
      device_auth: "per-device",
      payload_visibility: "ciphertext-only",
    },
    enrollment_order: ["d", "da", "oneplus"],
    join_cursors: {da: "4", oneplus: "4"},
    initial_publications: Object.fromEntries(browser.devices.map(entry => [
      entry.device,
      structuredClone(entry.initial_sync.initial_publications),
    ])),
    restarts: browser.devices.map(entry => ({
      device: entry.device,
      before_sequence: entry.unchanged_restart.before_sequence,
      after_sequence: entry.unchanged_restart.after_sequence,
      password_publications: "0",
      cookie_publications: "0",
    })),
    password: {
      record_key: credentialKey,
      revisions: [
        {revision: "1", device: "d", deleted: false},
        {revision: "2", device: "da", deleted: false},
        {revision: "3", device: "da", deleted: true},
      ],
      stale_conflict: {
        device: "oneplus",
        expected_revision: "1",
        current_revision: "2",
        result: "revision-conflict",
        accepted_publications: "0",
      },
    },
    cookies: {
      record_key: cookieKey,
      authoritative_source: "d",
      revisions: ["1", "2", "3", "4"].map(revision => ({
        revision,
        device: "d",
        deleted: false,
      })),
      rejected_conflict: {
        device: "oneplus",
        expected_revision: "3",
        current_revision: "4",
        result: "revision-conflict",
        accepted_publications: "0",
      },
    },
    counter_probe: {
      encoding: "int64-string",
      uint32_plus_one: "4294967296",
      round_trip: true,
      overflow_rejected: true,
    },
    journal: {
      sha256: "9".repeat(64),
      tabs_records: "0",
      plaintext_detected: false,
      secret_fields_logged: false,
    },
  };
}

function originAudit(manifest, device) {
  return {
    schema_version: 2,
    audit_id: `${device}-session-import-v1`,
    evidence_scope: "disposable-browser",
    artifact_sha256: manifest.devices[device].artifact_sha256,
    target_device: device,
    origins: [{
      origin: "https://session.fixture.invalid",
      cookie: {
        apply_result: "verified",
        auth_result: "authenticated",
        device_bound_session: "not-observed",
        evidence_ref: `${device}-authenticated-request`,
      },
      state: [
        "local-storage",
        "indexed-db",
        "service-worker",
        "cache-storage",
        "other-origin-state",
      ].map(kind => ({
        kind,
        need: "not-required",
        adapter: "none",
        preview_result: "not-tested",
        apply_result: "not-tested",
        readback_result: "not-tested",
        rollback_result: "not-tested",
        evidence_ref: `${device}-${kind}`,
      })),
    }],
  };
}

function manifestFixture() {
  const device = ({
    platform,
    target,
    packageName,
    artifact,
    receipt,
    inventory,
    marker,
  }) => ({
    native_run: `/synthetic/native-${target}`,
    platform,
    target,
    package: packageName,
    artifact_path: `/synthetic/${target}/browser`,
    artifact_sha256: artifact,
    admission: {
      kind: platform === "android" ?
        "prepared-android-inventory" : "linux-runtime-receipt",
      receipt_path: `/synthetic/${target}/receipt`,
      receipt_sha256: receipt,
      inventory_path: platform === "android" ?
        `/synthetic/${target}/inventory` : null,
      inventory_sha256: inventory,
    },
    profile_path: platform === "linux" ?
      `/synthetic/native-${target}/profile` : null,
    profile_marker_sha256: marker,
  });
  return {
    source_train: TRAIN,
    devices: {
      d: device({
        platform: "linux",
        target: "linux-arm64-chroot",
        packageName: "",
        artifact: "a".repeat(64),
        receipt: "b".repeat(64),
        inventory: null,
        marker: "c".repeat(64),
      }),
      da: device({
        platform: "linux",
        target: "linux-x86_64",
        packageName: "",
        artifact: "d".repeat(64),
        receipt: "e".repeat(64),
        inventory: null,
        marker: "f".repeat(64),
      }),
      oneplus: device({
        platform: "android",
        target: "android-arm64",
        packageName: "computer.helium.sync.test",
        artifact: "0".repeat(64),
        receipt: "1".repeat(64),
        inventory: "2".repeat(64),
        marker: null,
      }),
    },
  };
}

async function preparedInputs(root) {
  const dArtifact = path.join(
    root, "helium-passwords-linux-arm64", "runtime", "helium-wrapper");
  const daArtifact = path.join(
    root, "helium-passwords-linux-x86_64", "runtime", "helium-wrapper");
  await fsp.mkdir(path.dirname(dArtifact), {recursive: true});
  await fsp.mkdir(path.dirname(daArtifact), {recursive: true});
  await fsp.writeFile(dArtifact, "synthetic d arm64 browser", {mode: 0o700});
  await fsp.writeFile(daArtifact, "synthetic da x86_64 browser", {mode: 0o700});
  const dArtifactReceipt = await writeLinuxArtifactReceipt(
    root, dArtifact, "arm64");
  const daArtifactReceipt = await writeLinuxArtifactReceipt(
    root, daArtifact, "x86_64");
  const oneplusArtifact = await writeAndroidAdmission(root);
  return {
    dArtifact,
    dArtifactReceipt,
    daArtifact,
    daArtifactReceipt,
    oneplusArtifact,
  };
}

async function preparedRun(root) {
  const inputs = await preparedInputs(root);
  const runRoot = path.join(root, "three-client");
  const manifest = await initializeThreeClientRun({
    ...inputs,
    output: runRoot,
  });
  for (const device of ["d", "da", "oneplus"]) {
    await completeNativeUI(manifest, root, device);
  }
  return {
    manifest,
    runRoot,
    inputs,
  };
}

test("initialization rejects the wrong per-device target and a split source train", async () => {
  const wrongTargetRoot = await fsp.mkdtemp(
    path.join(os.tmpdir(), "helium-three-client-target-"));
  const splitTrainRoot = await fsp.mkdtemp(
    path.join(os.tmpdir(), "helium-three-client-train-"));
  try {
    const wrongTarget = await preparedInputs(wrongTargetRoot);
    await assert.rejects(initializeThreeClientRun({
      ...wrongTarget,
      dArtifact: wrongTarget.daArtifact,
      dArtifactReceipt: wrongTarget.daArtifactReceipt,
      output: path.join(wrongTargetRoot, "run"),
    }), /wrong architecture/);

    const splitTrain = await preparedInputs(splitTrainRoot);
    const receiptRaw = await fsp.readFile(
      splitTrain.daArtifactReceipt, "utf8");
    await fsp.writeFile(
      splitTrain.daArtifactReceipt,
      receiptRaw.replace(
        `source_commit=${TRAIN.source_commit}`,
        `source_commit=${"9".repeat(40)}`,
      ),
      {mode: 0o600},
    );
    await assert.rejects(initializeThreeClientRun({
      ...splitTrain,
      output: path.join(splitTrainRoot, "run"),
    }), /shared source train/);
  } finally {
    await fsp.rm(wrongTargetRoot, {recursive: true, force: true});
    await fsp.rm(splitTrainRoot, {recursive: true, force: true});
  }
});

test("three-client gate binds native UI, pull-only joins, conflicts, sessions, and int64 evidence", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-three-client-"));
  try {
    const {manifest, runRoot, inputs} = await preparedRun(root);
    assert.equal((await acceptanceStatus(runRoot)).state, "flow-evidence-required");
    for (const device of ["d", "da"]) {
      const profile = manifest.devices[device].profile_path;
      assert.equal((await fsp.stat(profile)).mode & 0o777, 0o700);
      assert.equal(
        await fsp.readFile(path.join(profile, "SYNTHETIC_ONLY"), "utf8"),
        "helium-password-runtime-v2\n",
      );
      assert.equal(
        await fsp.readFile(path.join(profile, "HELIUM_SYNC_DEVICE"), "utf8"),
        `helium-three-client-device-v1:${device}\n`,
      );
    }
    assert.equal(manifest.devices.d.target, "linux-arm64-chroot");
    assert.equal(manifest.devices.da.target, "linux-x86_64");
    assert.equal(manifest.devices.oneplus.target, "android-arm64");
    assert.equal(manifest.devices.oneplus.package, "computer.helium.sync.test");
    assert.equal(manifest.devices.oneplus.profile_path, null);
    assert.equal(manifest.devices.oneplus.profile_marker_sha256, null);
    assert.match(manifest.devices.oneplus.admission.inventory_sha256,
      /^[0-9a-f]{64}$/);
    assert.deepEqual(manifest.source_train, TRAIN);
    await assert.rejects(initializeThreeClientRun({
      ...inputs,
      output: runRoot,
    }), /already exists/);

    const nativeUIReceiptSHA256 = Object.fromEntries(
      await Promise.all(["d", "da", "oneplus"].map(async device => [
        device,
        digest(await fsp.readFile(
          path.join(manifest.devices[device].native_run, "sync-receipt.json"))),
      ])),
    );
    const browser = browserEvidence(manifest, nativeUIReceiptSHA256);
    const server = serverEvidence(manifest, browser);
    const files = {
      browser: path.join(root, "browser-evidence.json"),
      server: path.join(root, "server-evidence.json"),
      da: path.join(root, "da-origin.json"),
      oneplus: path.join(root, "oneplus-origin.json"),
    };
    await writeJSON(files.browser, browser);
    await writeJSON(files.server, server);
    await writeJSON(files.da, originAudit(manifest, "da"));
    await writeJSON(files.oneplus, originAudit(manifest, "oneplus"));
    const wrongBrowser = path.join(root, "wrong-browser-evidence.json");
    const wrongBrowserEvidence = structuredClone(browser);
    wrongBrowserEvidence.devices.find(entry => entry.device === "oneplus")
      .native_ui_receipt_sha256 = "9".repeat(64);
    await writeJSON(wrongBrowser, wrongBrowserEvidence);
    await assert.rejects(verifyThreeClientRun({
      runRoot,
      browserEvidence: wrongBrowser,
      serverEvidence: files.server,
      daOriginAudit: files.da,
      oneplusOriginAudit: files.oneplus,
    }), /OnePlus|oneplus browser evidence is not bound/);
    const receipt = await verifyThreeClientRun({
      runRoot,
      browserEvidence: files.browser,
      serverEvidence: files.server,
      daOriginAudit: files.da,
      oneplusOriginAudit: files.oneplus,
    });
    assert.equal(receipt.result, "passed");
    assert.deepEqual(receipt.source_train, manifest.source_train);
    assert.deepEqual(receipt.artifact_sha256, Object.fromEntries(
      ["d", "da", "oneplus"].map(device => [
        device, manifest.devices[device].artifact_sha256,
      ]),
    ));
    assert.equal(receipt.profile_marker_sha256.oneplus, null);
    assert.deepEqual(receipt.enrollment_order, ["d", "da", "oneplus"]);
    assert.equal(receipt.password_revisions.tombstone, "3");
    assert.equal(receipt.cookie_authoritative_revision, "4");
    assert.equal(receipt.uint32_plus_one_sequence, "4294967296");
    assert.equal(receipt.tabs_policy, "excluded");
    assert.equal((await acceptanceStatus(runRoot)).state, "passed");
    assert.equal((await auditVerifiedThreeClientRun(runRoot)).receipt.result, "passed");
    assert.equal((await fsp.stat(path.join(
      runRoot, "verified", "receipt.json"))).mode & 0o777, 0o600);
    const verifiedServer = path.join(
      runRoot, "verified", "server-evidence.json");
    const verifiedServerRaw = await fsp.readFile(verifiedServer, "utf8");
    const changedServer = JSON.parse(verifiedServerRaw);
    changedServer.journal.sha256 = "0".repeat(64);
    await writeJSON(verifiedServer, changedServer);
    await assert.rejects(acceptanceStatus(runRoot),
      /receipt no longer matches its evidence/);
    await fsp.writeFile(verifiedServer, verifiedServerRaw, {mode: 0o600});
    assert.equal((await acceptanceStatus(runRoot)).state, "passed");
    for (const device of ["d", "da", "oneplus"]) {
      const nativeRun = manifest.devices[device].native_run;
      await auditVerifiedSyncRun({
        runRoot: nativeRun,
        fixtureEvidence: path.join(nativeRun, "fixture-evidence.json"),
      });
    }
  } finally {
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("browser evidence fails closed on join publication, stale overwrite, cookie gaps, loops, and tabs", async () => {
  const manifest = manifestFixture();
  const baseline = browserEvidence(manifest);
  validateBrowserEvidence(baseline, manifest);

  const wrongArtifact = structuredClone(baseline);
  wrongArtifact.devices.find(entry => entry.device === "d").artifact_sha256 =
    manifest.devices.da.artifact_sha256;
  assert.throws(() => validateBrowserEvidence(wrongArtifact, manifest),
    /device identity/);

  const inventedOnePlusProfile = structuredClone(baseline);
  inventedOnePlusProfile.devices.find(entry => entry.device === "oneplus")
    .profile_marker_sha256 = "9".repeat(64);
  assert.throws(() => validateBrowserEvidence(inventedOnePlusProfile, manifest),
    /device identity|invented a filesystem profile/);

  const joinPublished = structuredClone(baseline);
  joinPublished.devices.find(entry => entry.device === "da")
    .initial_sync.initial_publications.passwords = "1";
  assert.throws(() => validateBrowserEvidence(joinPublished, manifest),
    /initial pull-only join published/);

  const staleWon = structuredClone(baseline);
  staleWon.password.stale_conflict.authoritative_preserved = false;
  assert.throws(() => validateBrowserEvidence(staleWon, manifest),
    /stale device password overwrite/);

  const restartPublished = structuredClone(baseline);
  restartPublished.devices[2].unchanged_restart.cookie_publications = "1";
  assert.throws(() => validateBrowserEvidence(restartPublished, manifest),
    /unchanged restart mutated or published/);

  const missingPartition = structuredClone(baseline);
  missingPartition.cookies.attribute_coverage.partitioned = false;
  assert.throws(() => validateBrowserEvidence(missingPartition, manifest),
    /canonical cookie attributes/);

  const noAuthentication = structuredClone(baseline);
  noAuthentication.cookies.imports[0].authenticated_request.result =
    "reauth-required";
  assert.throws(() => validateBrowserEvidence(noAuthentication, manifest),
    /authenticated destination request/);

  const echo = structuredClone(baseline);
  echo.cookies.rotations[0].destinations[0].echo_publications = "1";
  assert.throws(() => validateBrowserEvidence(echo, manifest),
    /without an echo/);

  const vagueException = structuredClone(baseline);
  vagueException.cookies.destination_exceptions.push({
    device: "da",
    record_key: cookieKey,
    remote_revision: "2",
    payload_sha256: "c".repeat(64),
    observed_result: "assumed-device-bound",
    classification: "non-clonable",
    rollback: "exact",
    local_preserved: true,
    evidence_ref: "assumed",
    evidence_sha256: "d".repeat(64),
  });
  assert.throws(() => validateBrowserEvidence(vagueException, manifest),
    /lacks exact destination rejection/);

  const tabs = structuredClone(baseline);
  tabs.tabs_observed = true;
  assert.throws(() => validateBrowserEvidence(tabs, manifest),
    /browser evidence boundary/);
});

test("server evidence rejects enrollment reorder, stale acceptance, 32-bit counters, plaintext, and tabs", () => {
  const manifest = manifestFixture();
  const browser = browserEvidence(manifest);
  const baseline = serverEvidence(manifest, browser);
  validateServerEvidence(baseline, manifest, browser);

  const reordered = structuredClone(baseline);
  reordered.enrollment_order = ["d", "oneplus", "da"];
  assert.throws(() => validateServerEvidence(reordered, manifest, browser),
    /enrollment order/);

  const wrongSource = structuredClone(baseline);
  wrongSource.source_train.core_commit = "9".repeat(40);
  assert.throws(() => validateServerEvidence(wrongSource, manifest, browser),
    /identity or enrollment order/);

  const staleAccepted = structuredClone(baseline);
  staleAccepted.password.stale_conflict.accepted_publications = "1";
  assert.throws(() => validateServerEvidence(staleAccepted, manifest, browser),
    /stale password mutation/);

  const uint32 = structuredClone(baseline);
  uint32.counter_probe.uint32_plus_one = "4294967295";
  assert.throws(() => validateServerEvidence(uint32, manifest, browser),
    /64-bit sequence/);

  const plaintext = structuredClone(baseline);
  plaintext.journal.plaintext_detected = true;
  assert.throws(() => validateServerEvidence(plaintext, manifest, browser),
    /plaintext/);

  const tabs = structuredClone(baseline);
  tabs.journal.tabs_records = "1";
  assert.throws(() => validateServerEvidence(tabs, manifest, browser),
    /contains tabs/);
});

test("orchestrator source contains no alternate browser writer or tab transport", async () => {
  const source = await fsp.readFile(new URL(
    "../sync-runtime/three-client-acceptance.mjs",
    import.meta.url,
  ), "utf8");
  assert.doesNotMatch(source,
    /passwordsPrivate|AddLogin|UpdateLogin|CookieCloud|Network\.setCookies|CDP.*(?:password|cookie)/i);
  assert.doesNotMatch(source, /KindTabs|tab-sync|tabs_endpoint/);
  assert.match(source, /value\.journal\.tabs_records !== "0"/);
  assert.match(source, /native-password-store-and-cookie-manager/);
  assert.match(source, /tabs_policy: "excluded"/);
});
