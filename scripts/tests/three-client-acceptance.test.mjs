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
import {
  auditDeviceRuntimeEvidence,
  auditServerRuntimeEvidence,
} from "../sync-runtime/fleet-runtime-evidence.mjs";
import {writeFullGraphFixture} from "./linux-artifact-fixture.mjs";

const credentialKey = `credential/v2/${"c".repeat(64)}`;
const cookieKey = "d".repeat(64);
const keyID = "a1b2c3d4e5f60708";
const TRAIN = Object.freeze({
  source_commit: "1".repeat(40),
  passwords_commit: "5".repeat(40),
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

async function writeExecutionIdentity(root, device) {
  const file = path.join(root, `${device}-execution-identity.env`);
  let value;
  if (device === "oneplus") {
    value = {
      schema_version: 1,
      identity_schema: "helium-physical-oneplus-v1",
      adb_serial: "ONEPLUS-USB",
      adb_transport: "physical-usb",
      adb_transport_id: "1",
      adb_usb_path_sha256: "8".repeat(64),
      android_model: "CPH2655",
      android_device: "dodge",
      android_product: "dodge",
      android_manufacturer: "OnePlus",
      build_fingerprint_sha256: "9".repeat(64),
      physical_identity_sha256: "",
      captured_at: "2026-07-23T08:00:00.000Z",
    };
    value.physical_identity_sha256 = digest([
      "helium-physical-oneplus-v1",
      value.adb_serial,
      value.android_model,
      value.android_device,
      value.android_product,
      value.android_manufacturer,
      value.build_fingerprint_sha256,
      "",
    ].join("\n"));
  } else {
    value = {
      schema_version: 1,
      identity_schema: "helium-linux-host-v1",
      host: device,
      hostname: device,
      machine_id_sha256: (device === "d" ? "a" : "b").repeat(64),
      kernel_arch: "x64",
      host_identity_sha256: "",
      captured_at: "2026-07-23T08:00:00.000Z",
    };
    value.host_identity_sha256 = digest([
      "helium-linux-host-v1",
      value.host,
      value.hostname,
      value.machine_id_sha256,
      value.kernel_arch,
      "",
    ].join("\n"));
  }
  await fsp.writeFile(file,
    `${Object.entries(value).map(([key, item]) => `${key}=${item}`).join("\n")}\n`,
    {mode: 0o600});
  return file;
}

async function writeLinuxArtifactReceipt(root, artifact, arch, label = arch) {
  const artifactHash = digest(await fsp.readFile(artifact));
  const receiptRoot = path.join(root, `${label}-admission`);
  const bundle = path.join(receiptRoot, `helium-sync-linux-${arch}`);
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
  const archive = path.join(root, `helium-sync-linux-${arch}.tar.xz`);
  try {
    await fsp.writeFile(archive, `synthetic-${arch}-archive`, {
      mode: 0o600,
      flag: "wx",
    });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  const archiveStat = await fsp.stat(archive);
  const archiveHash = digest(await fsp.readFile(archive));
  const graph = await writeFullGraphFixture(
    path.join(provenance, "full-graph"));
  const manifestRaw = [
    "schema_version=4",
    "product=helium-sync",
    "platform=linux",
    `arch=${arch}`,
    "target=linux-x86_64",
    `source_commit=${TRAIN.source_commit}`,
    `source_tree=${"7".repeat(64)}`,
    `helium_passwords_commit=${TRAIN.passwords_commit}`,
    `helium_sync_commit=${TRAIN.source_commit}`,
    `helium_core_commit=${TRAIN.core_commit}`,
    `chromium_version=${TRAIN.chromium_version}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    "build_job_id=synthetic-linux-fixture",
    "platform_repository=https://github.com/helium-linux/helium-linux",
    `platform_commit=${"4".repeat(40)}`,
    "depot_tools_commit=980d6af16e06ff993a52029019dc0628c0a0e1f0",
    `gn_args_sha256=${"8".repeat(64)}`,
    `nix_provenance_sha256=${"9".repeat(64)}`,
    `patch_inventory_sha256=${"a".repeat(64)}`,
    `runtime_inventory_sha256=${digest(inventoryRaw)}`,
    `packaging_tool_commit=${"6".repeat(40)}`,
    `packaging_tool_sha256=${graph.packagingToolSha256}`,
    `full_graph_receipt_sha256=${graph.receiptSha256}`,
    `full_graph_inventory_sha256=${graph.inventorySha256}`,
    "",
  ].join("\n");
  await fsp.writeFile(path.join(provenance, "manifest.env"), manifestRaw,
    {mode: 0o600});
  const manifestHash = digest(manifestRaw);
  await fsp.writeFile(path.join(receiptRoot,
    "deployment-artifact-receipt.env"), [
    "schema_version=2",
    `artifact_sha256=${archiveHash}`,
    `artifact_size=${archiveStat.size}`,
    "target=linux-x86_64",
    `helium_sync_commit=${TRAIN.source_commit}`,
    `helium_passwords_commit=${TRAIN.passwords_commit}`,
    `helium_core_commit=${TRAIN.core_commit}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    "build_job_id=synthetic-linux-fixture",
    `provenance_sha256=${manifestHash}`,
    `full_graph_receipt_sha256=${graph.receiptSha256}`,
    `full_graph_inventory_sha256=${graph.inventorySha256}`,
    "created_at=2026-07-23T08:00:00Z",
    "",
  ].join("\n"), {mode: 0o600});
  const receipt = path.join(receiptRoot, "artifact-receipt.env");
  await fsp.writeFile(receipt, [
    "schema_version=3",
    "product=helium-sync",
    "platform=linux",
    `arch=${arch}`,
    `source_commit=${TRAIN.source_commit}`,
    `helium_core_commit=${TRAIN.core_commit}`,
    `chromium_version=${TRAIN.chromium_version}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    `platform_commit=${"4".repeat(40)}`,
    `bundle=${archive}`,
    `bundle_sha256=${archiveHash}`,
    `provenance_manifest_sha256=${manifestHash}`,
    `browser_executable=${path.relative(receiptRoot, artifact)}`,
    `browser_sha256=${artifactHash}`,
    `runtime_inventory=${path.relative(receiptRoot, inventory)}`,
    `runtime_inventory_sha256=${digest(inventoryRaw)}`,
    `full_graph_receipt=helium-sync-linux-${arch}/provenance/full-graph/receipt.env`,
    `full_graph_receipt_sha256=${graph.receiptSha256}`,
    `full_graph_inventory=helium-sync-linux-${arch}/provenance/full-graph/SHA256SUMS`,
    `full_graph_inventory_sha256=${graph.inventorySha256}`,
    `verified_at=synthetic-fixture-${label}`,
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
    "schema_version=7",
    "probe_schema_version=1",
    `helium_sync_commit=${TRAIN.source_commit}`,
    `runtime_kit_commit=${"7".repeat(40)}`,
    `runtime_kit_source_sha256=${"8".repeat(64)}`,
    `chromium_commit=${TRAIN.chromium_commit}`,
    "manifest_package=computer.helium.sync.test",
    "version_code=787500005",
    `version_name=${TRAIN.chromium_version}`,
    "target_cpu=arm64",
    "artifact_target=chrome_public_apk",
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
    schema_version: 6,
    identity_schema: "password-form-unique-key-v2",
    verified_sequence: String(revision),
    credentials: {
      [credentialKey]: {
        fingerprint,
        remote_seq: String(revision),
        revision: String(revision),
        deleted,
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
    payload: deleted ? {} : {
      format: "chromium-password-specifics-v1",
      password_specifics_data_b64: `synthetic-${sequence}`,
    },
  });
}

const secondCookieKey = "e".repeat(64);
const thirdCookieKey = "f".repeat(64);

function fleetRecords() {
  const passwordPayload = revision => ({
    format: "chromium-password-specifics-v1",
    password_specifics_data_b64: `synthetic-${revision}`,
  });
  const cookiePayload = key => ({
    format: "chromium-cookie-specifics-v1",
    canonical_cookie: key,
  });
  return [
    {seq: "1", kind: "passwords", key: credentialKey, revision: "1",
      deleted: false, device_id: "d", payload: passwordPayload("1")},
    {seq: "2", kind: "cookies", key: cookieKey, revision: "1",
      deleted: false, device_id: "d", payload: cookiePayload(cookieKey)},
    {seq: "3", kind: "cookies", key: secondCookieKey, revision: "1",
      deleted: false, device_id: "d", payload: cookiePayload(secondCookieKey)},
    {seq: "4", kind: "cookies", key: thirdCookieKey, revision: "1",
      deleted: false, device_id: "d", payload: cookiePayload(thirdCookieKey)},
    {seq: "5", kind: "passwords", key: credentialKey, revision: "2",
      deleted: false, device_id: "da", payload: passwordPayload("2")},
    {seq: "6", kind: "passwords", key: credentialKey, revision: "3",
      deleted: true, device_id: "da", payload: {}},
    {seq: "7", kind: "cookies", key: cookieKey, revision: "2",
      deleted: false, device_id: "d", payload: cookiePayload(cookieKey)},
    {seq: "8", kind: "cookies", key: cookieKey, revision: "3",
      deleted: false, device_id: "d", payload: cookiePayload(cookieKey)},
    {seq: "9", kind: "cookies", key: cookieKey, revision: "4",
      deleted: false, device_id: "d", payload: cookiePayload(cookieKey)},
  ];
}

function runtimePasswordState(sequence, revision, deleted) {
  return {
    schema_version: 6,
    identity_schema: "password-form-unique-key-v2",
    verified_sequence: sequence,
    credentials: {
      [credentialKey]: {
        fingerprint: deleted ? "" : revision.repeat(64),
        remote_seq: revision === "1" ? "1" : revision === "2" ? "5" : "6",
        revision,
        deleted,
      },
    },
  };
}

function runtimeCookieState(sequence, terminal = false) {
  const record = (revision, key) => ({
    remote_revision: revision,
    device_id: "d",
    remote_payload_fingerprint: digest(`remote-${key}-${revision}`),
    baseline_cookie_fingerprint: digest(`baseline-${key}-${revision}`),
    remote_deleted: false,
  });
  return {
    schema_version: 5,
    verified_sequence: sequence,
    blocked_reason: "",
    records: {
      [cookieKey]: record(terminal ? "4" : "1", cookieKey),
      [secondCookieKey]: record("1", secondCookieKey),
      [thirdCookieKey]: record("1", thirdCookieKey),
    },
  };
}

function runtimeClient(device, sequence) {
  return {
    version: 2,
    device_id: device,
    role: device === "d" ? "seed" : "join",
    phase: "active",
    revisions: {
      [`passwords\0${credentialKey}`]: sequence === "4" ? "1" : "3",
      [`cookies\0${cookieKey}`]: sequence === "4" ? "1" : "4",
    },
    sequence,
  };
}

async function writeEvidenceBundle(directory, files) {
  await fsp.mkdir(directory, {mode: 0o700});
  await fsp.chmod(directory, 0o700);
  for (const [name, contents] of Object.entries(files)) {
    await fsp.writeFile(path.join(directory, name), contents, {mode: 0o600});
  }
  const inventory = `${(await Promise.all(Object.keys(files).sort()
    .map(async name =>
      `${digest(await fsp.readFile(path.join(directory, name)))}  ${name}`)))
    .join("\n")}\n`;
  await fsp.writeFile(path.join(directory, "EVIDENCE_SHA256SUMS"), inventory,
    {mode: 0o600});
}

async function writeDeviceRuntimeEvidence(root, device, identityFile) {
  const directory = path.join(root, `runtime-${device}`);
  const initialRecords = fleetRecords().slice(0, 4);
  const journal = `${initialRecords.map(JSON.stringify).join("\n")}\n`;
  const initialClient = `${JSON.stringify(runtimeClient(device, "4"))}\n`;
  const initialPassword = `${JSON.stringify(
    runtimePasswordState("4", "1", false))}\n`;
  const initialCookie = `${JSON.stringify(runtimeCookieState("4"))}\n`;
  const terminalClient = `${JSON.stringify(runtimeClient(device, "9"))}\n`;
  const terminalPassword = `${JSON.stringify(
    runtimePasswordState("9", "3", true))}\n`;
  const terminalCookie = `${JSON.stringify(runtimeCookieState("9", true))}\n`;
  const requests = device === "d" ? "\n" : `${JSON.stringify({
    device,
    origin: "https://session.fixture.invalid",
    response_status: 200,
    result: "authenticated",
    evidence_ref: `${device}-authenticated-request`,
    evidence_sha256: (device === "da" ? "7" : "8").repeat(64),
    authorization_scheme: "Bearer",
    authorization_sha256: digest(`authorization-${device}`),
    completed_at: "2026-07-23T08:00:00.000Z",
  })}\n`;
  const collector = digest(await fsp.readFile(
    new URL("../sync-runtime/fleet-runtime-evidence.mjs", import.meta.url)));
  await writeEvidenceBundle(directory, {
    "identity.env": await fsp.readFile(identityFile),
    "client-initial.json": initialClient,
    "client-restart.json": initialClient,
    "client-terminal.json": terminalClient,
    "password-initial.json": initialPassword,
    "password-restart.json": initialPassword,
    "password-terminal.json": terminalPassword,
    "cookie-initial.json": initialCookie,
    "cookie-restart.json": initialCookie,
    "cookie-terminal.json": terminalCookie,
    "journal-initial.jsonl": journal,
    "journal-restart.jsonl": journal,
    "authenticated-requests.jsonl": requests,
    "browser.log": `synthetic ${device} metadata-only browser log\n`,
    "capture.env": [
      "schema_version=1",
      `device=${device}`,
      `collector_sha256=${collector}`,
      "captured_at=2026-07-23T08:00:01.000Z",
      "",
    ].join("\n"),
  });
  return directory;
}

function conflictReceipt(kind, key, expected, current) {
  const endpoint = "http://100.64.0.1:44719/";
  return {
    schema_version: 1,
    device: "oneplus",
    request: {
      kind,
      key,
      expected_revision: expected,
      deleted: false,
      payload_sha256: digest(`stale-${kind}`),
      endpoint,
      authorization_scheme: "Bearer",
      authorization_sha256: digest(`authorization-${kind}`),
    },
    response: {
      http_status: 409,
      body: {
        code: "revision_conflict",
        error: `revision conflict for ${kind}/${key}: expected ${expected}, current ${current}`,
        kind,
        key,
        current_revision: current,
      },
    },
    completed_at: "2026-07-23T08:00:00.000Z",
  };
}

async function writeServerRuntimeEvidence(root) {
  const directory = path.join(root, "runtime-server");
  const collector = digest(await fsp.readFile(
    new URL("../sync-runtime/fleet-runtime-evidence.mjs", import.meta.url)));
  const records = `${fleetRecords().map(JSON.stringify).join("\n")}\n`;
  await writeEvidenceBundle(directory, {
    "records.jsonl": records,
    "server.log": "synthetic metadata-only server log\n",
    "password-conflict.json": `${JSON.stringify(
      conflictReceipt("passwords", credentialKey, "1", "2"))}\n`,
    "cookie-conflict.json": `${JSON.stringify(
      conflictReceipt("cookies", cookieKey, "3", "4"))}\n`,
    "capture.env": [
      "schema_version=1",
      "endpoint=http://100.64.0.1:44719/",
      `collector_sha256=${collector}`,
      "captured_at=2026-07-23T08:00:01.000Z",
      "",
    ].join("\n"),
  });
  return directory;
}

function syntheticRuntimeDevices() {
  return Object.fromEntries(["d", "da", "oneplus"].map((device, index) => {
    const stateHash = String(index + 1).repeat(64);
    return [device, {
      bundle_sha256: String(index + 4).repeat(64),
      identity_sha256: String(index + 7).repeat(64),
      initial: {client: {sequence: "4"}, state_sha256: stateHash},
      restart: {client: {sequence: "4"}, state_sha256: stateHash},
      terminal: {
        client: {sequence: "9"},
        password: {credentials: [{
          key: credentialKey, revision: "3", deleted: true,
        }]},
        cookie: {records: {
          [cookieKey]: {remote_revision: "4", device_id: "d"},
        }},
      },
      initial_journal_sha256: "a".repeat(64),
      restart_journal_sha256: "a".repeat(64),
      initial_publications: {
        passwords: device === "d" ? "1" : "0",
        cookies: device === "d" ? "3" : "0",
      },
      requests: device === "d" ? [] : [{
        origin: "https://session.fixture.invalid",
        response_status: 200,
        result: "authenticated",
        evidence_ref: `${device}-authenticated-request`,
        evidence_sha256: (device === "da" ? "7" : "8").repeat(64),
      }],
    }];
  }));
}

function syntheticServerRuntime() {
  return {
    bundle_sha256: "b".repeat(64),
    endpoint: "http://100.64.0.1:44719/",
    journal_sha256: "9".repeat(64),
    records: fleetRecords(),
    max_sequence: "9",
    password_conflict: conflictReceipt(
      "passwords", credentialKey, "1", "2"),
    cookie_conflict: conflictReceipt("cookies", cookieKey, "3", "4"),
  };
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

function browserEvidence(manifest, runtimeEvidence, nativeUIReceiptSHA256 = {
  d: "6".repeat(64),
  da: "7".repeat(64),
  oneplus: "8".repeat(64),
}) {
  const restart = device => {
    const admitted = manifest.devices[device];
    const runtime = runtimeEvidence[device];
    return {
      device,
      platform: admitted.platform,
      target: admitted.target,
      package: admitted.package,
      artifact_sha256: admitted.artifact_sha256,
      admission_sha256: {
        receipt: admitted.admission.receipt_sha256,
        deployment_receipt: admitted.admission.deployment_receipt_sha256,
        provenance_manifest: admitted.admission.provenance_manifest_sha256,
        returned_archive: admitted.admission.returned_archive_sha256,
        full_graph_receipt: admitted.admission.full_graph_receipt_sha256,
        full_graph_inventory: admitted.admission.full_graph_inventory_sha256,
        inventory: admitted.admission.inventory_sha256,
      },
      profile_marker_sha256: admitted.profile_marker_sha256,
      native_ui_receipt_sha256: nativeUIReceiptSHA256[device],
      execution_identity_sha256: runtime.identity_sha256,
      role: device === "d" ? "seed" : "join",
      phase_before: device === "d" ? "new" : "pending",
      phase_after: "active",
      initial_sync: {
        server_sequence: runtime.initial.client.sequence,
        password_revision: "1",
        cookie_revision: "1",
        password_apply: "verified",
        cookie_apply: "verified",
        password_readback: "exact",
        cookie_readback: "exact",
        initial_publications: {
          passwords: runtime.initial_publications.passwords,
          cookies: runtime.initial_publications.cookies,
        },
      },
      unchanged_restart: {
        before_sequence: runtime.initial.client.sequence,
        after_sequence: runtime.restart.client.sequence,
        before_state_sha256: runtime.initial.state_sha256,
        after_state_sha256: runtime.restart.state_sha256,
        before_journal_sha256: runtime.initial_journal_sha256,
        after_journal_sha256: runtime.restart_journal_sha256,
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
    schema_version: 2,
    evidence_scope: "disposable-browser",
    writer: "native-password-store-and-cookie-manager",
    source_train: manifest.source_train,
    tabs_observed: false,
    runtime_evidence_sha256: Object.fromEntries(
      ["d", "da", "oneplus"].map(device =>
        [device, runtimeEvidence[device].bundle_sha256])),
    devices: [
      restart("d"),
      restart("da"),
      restart("oneplus"),
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

function serverEvidence(manifest, browser, runtimeEvidence) {
  return {
    schema_version: 2,
    source_train: manifest.source_train,
    evidence_scope: "disposable-tailnet-http-service",
    transport: {
      endpoint: "http://100.64.0.1:44719/",
      network: "tailscale-private",
      device_auth: "per-device-bearer",
      payload_visibility: "readable-private-journal",
    },
    enrollment_order: ["d", "da", "oneplus"],
    join_cursors: {da: "4", oneplus: "4"},
    runtime_evidence_sha256: runtimeEvidence.bundle_sha256,
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
      sha256: runtimeEvidence.journal_sha256,
      schema_version: "2",
      tabs_records: "0",
      payload_storage: "readable",
      bearer_tokens_present: false,
      private_mode: true,
    },
    logs: {
      password_values_detected: false,
      bearer_tokens_detected: false,
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
      deployment_receipt_path: platform === "linux" ?
        `/synthetic/${target}/deployment-receipt` : null,
      deployment_receipt_sha256: platform === "linux" ? "3".repeat(64) : null,
      provenance_manifest_path: platform === "linux" ?
        `/synthetic/${target}/manifest` : null,
      provenance_manifest_sha256: platform === "linux" ? "4".repeat(64) : null,
      returned_archive_path: platform === "linux" ?
        "/synthetic/helium-sync-linux-x86_64.tar.xz" : null,
      returned_archive_sha256: platform === "linux" ? "5".repeat(64) : null,
      build_job_id: platform === "linux" ? "synthetic-x86_64" : null,
      depot_tools_commit: platform === "linux" ?
        "980d6af16e06ff993a52029019dc0628c0a0e1f0" : null,
      full_graph_root_path: platform === "linux" ?
        `/synthetic/${target}/full-graph` : null,
      full_graph_receipt_path: platform === "linux" ?
        `/synthetic/${target}/full-graph/receipt.env` : null,
      full_graph_receipt_sha256: platform === "linux" ?
        "6".repeat(64) : null,
      full_graph_inventory_path: platform === "linux" ?
        `/synthetic/${target}/full-graph/SHA256SUMS` : null,
      full_graph_inventory_sha256: platform === "linux" ?
        "7".repeat(64) : null,
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
        target: "linux-x86_64",
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
    root, "d-admission", "helium-sync-linux-x86_64", "runtime",
    "helium-wrapper");
  const daArtifact = path.join(
    root, "da-admission", "helium-sync-linux-x86_64", "runtime",
    "helium-wrapper");
  await fsp.mkdir(path.dirname(dArtifact), {recursive: true});
  await fsp.mkdir(path.dirname(daArtifact), {recursive: true});
  await fsp.writeFile(dArtifact, "synthetic x86_64 browser", {mode: 0o700});
  await fsp.writeFile(daArtifact, "synthetic x86_64 browser", {mode: 0o700});
  const dArtifactReceipt = await writeLinuxArtifactReceipt(
    root, dArtifact, "x86_64", "d");
  const daArtifactReceipt = await writeLinuxArtifactReceipt(
    root, daArtifact, "x86_64", "da");
  const oneplusArtifact = await writeAndroidAdmission(root);
  const dExecutionIdentity = await writeExecutionIdentity(root, "d");
  const daExecutionIdentity = await writeExecutionIdentity(root, "da");
  const oneplusExecutionIdentity = await writeExecutionIdentity(
    root, "oneplus");
  return {
    dArtifact,
    dArtifactReceipt,
    daArtifact,
    daArtifactReceipt,
    oneplusArtifact,
    dExecutionIdentity,
    daExecutionIdentity,
    oneplusExecutionIdentity,
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
  const runtimePaths = {};
  const runtime = {};
  for (const device of ["d", "da", "oneplus"]) {
    const identity = inputs[`${device}ExecutionIdentity`];
    runtimePaths[device] = await writeDeviceRuntimeEvidence(
      root, device, identity);
    runtime[device] = await auditDeviceRuntimeEvidence(
      runtimePaths[device], device, manifest.devices[device].execution_identity);
  }
  runtimePaths.server = await writeServerRuntimeEvidence(root);
  runtime.server = await auditServerRuntimeEvidence(runtimePaths.server);
  return {
    manifest,
    runRoot,
    inputs,
    runtime,
    runtimePaths,
  };
}

test("initialization rejects the wrong per-device target and a split source train", async () => {
  const wrongTargetRoot = await fsp.mkdtemp(
    path.join(os.tmpdir(), "helium-three-client-target-"));
  const splitTrainRoot = await fsp.mkdtemp(
    path.join(os.tmpdir(), "helium-three-client-train-"));
  try {
    const wrongTarget = await preparedInputs(wrongTargetRoot);
    const wrongReceipt = await fsp.readFile(
      wrongTarget.dArtifactReceipt, "utf8");
    await fsp.writeFile(
      wrongTarget.dArtifactReceipt,
      wrongReceipt.replace("arch=x86_64", "arch=arm64"),
      {mode: 0o600},
    );
    await assert.rejects(initializeThreeClientRun({
      ...wrongTarget,
      output: path.join(wrongTargetRoot, "run"),
    }), /wrong architecture|does not admit this audited browser executable/);

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
    }), /deployment receipt or provenance|shared source train|full-graph helium_sync_commit/);
  } finally {
    await fsp.rm(wrongTargetRoot, {recursive: true, force: true});
    await fsp.rm(splitTrainRoot, {recursive: true, force: true});
  }
});

test("three-client gate binds native UI, pull-only joins, conflicts, sessions, and int64 evidence", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-three-client-"));
  try {
    const {manifest, runRoot, inputs, runtime, runtimePaths} =
      await preparedRun(root);
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
    assert.equal(manifest.devices.d.target, "linux-x86_64");
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
    const browser = browserEvidence(manifest, runtime, nativeUIReceiptSHA256);
    const server = serverEvidence(manifest, browser, runtime.server);
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
      dRuntimeEvidence: runtimePaths.d,
      daRuntimeEvidence: runtimePaths.da,
      oneplusRuntimeEvidence: runtimePaths.oneplus,
      serverRuntimeEvidence: runtimePaths.server,
      daOriginAudit: files.da,
      oneplusOriginAudit: files.oneplus,
    }), /OnePlus|oneplus browser evidence is not bound/);
    const receipt = await verifyThreeClientRun({
      runRoot,
      browserEvidence: files.browser,
      serverEvidence: files.server,
      dRuntimeEvidence: runtimePaths.d,
      daRuntimeEvidence: runtimePaths.da,
      oneplusRuntimeEvidence: runtimePaths.oneplus,
      serverRuntimeEvidence: runtimePaths.server,
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
      /receipt no longer matches its evidence|server journal violates/);
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
  const runtime = syntheticRuntimeDevices();
  const baseline = browserEvidence(manifest, runtime);
  validateBrowserEvidence(baseline, manifest, runtime);

  const wrongArtifact = structuredClone(baseline);
  wrongArtifact.devices.find(entry => entry.device === "d").artifact_sha256 =
    manifest.devices.da.artifact_sha256;
  assert.throws(() => validateBrowserEvidence(wrongArtifact, manifest, runtime),
    /device identity/);

  const inventedOnePlusProfile = structuredClone(baseline);
  inventedOnePlusProfile.devices.find(entry => entry.device === "oneplus")
    .profile_marker_sha256 = "9".repeat(64);
  assert.throws(() => validateBrowserEvidence(
    inventedOnePlusProfile, manifest, runtime),
    /device identity|invented .*filesystem profile/);

  const joinPublished = structuredClone(baseline);
  joinPublished.devices.find(entry => entry.device === "da")
    .initial_sync.initial_publications.passwords = "1";
  assert.throws(() => validateBrowserEvidence(joinPublished, manifest, runtime),
    /initial pull-only join published/);

  const staleWon = structuredClone(baseline);
  staleWon.password.stale_conflict.authoritative_preserved = false;
  assert.throws(() => validateBrowserEvidence(staleWon, manifest, runtime),
    /stale device password overwrite/);

  const restartPublished = structuredClone(baseline);
  restartPublished.devices[2].unchanged_restart.cookie_publications = "1";
  assert.throws(() => validateBrowserEvidence(
    restartPublished, manifest, runtime),
    /unchanged restart mutated or published/);

  const missingPartition = structuredClone(baseline);
  missingPartition.cookies.attribute_coverage.partitioned = false;
  assert.throws(() => validateBrowserEvidence(
    missingPartition, manifest, runtime),
    /canonical cookie attributes/);

  const noAuthentication = structuredClone(baseline);
  noAuthentication.cookies.imports[0].authenticated_request.result =
    "reauth-required";
  assert.throws(() => validateBrowserEvidence(
    noAuthentication, manifest, runtime),
    /authenticated destination request/);

  const echo = structuredClone(baseline);
  echo.cookies.rotations[0].destinations[0].echo_publications = "1";
  assert.throws(() => validateBrowserEvidence(echo, manifest, runtime),
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
  assert.throws(() => validateBrowserEvidence(
    vagueException, manifest, runtime),
    /lacks exact destination rejection/);

  const tabs = structuredClone(baseline);
  tabs.tabs_observed = true;
  assert.throws(() => validateBrowserEvidence(tabs, manifest, runtime),
    /browser evidence boundary/);
});

test("server evidence rejects reorder, stale writes, 32-bit counters, secret logs, and tabs", () => {
  const manifest = manifestFixture();
  const devices = syntheticRuntimeDevices();
  const runtime = syntheticServerRuntime();
  const browser = browserEvidence(manifest, devices);
  const baseline = serverEvidence(manifest, browser, runtime);
  validateServerEvidence(baseline, manifest, browser, runtime);

  const reordered = structuredClone(baseline);
  reordered.enrollment_order = ["d", "oneplus", "da"];
  assert.throws(() => validateServerEvidence(
    reordered, manifest, browser, runtime),
    /enrollment order/);

  const wrongSource = structuredClone(baseline);
  wrongSource.source_train.core_commit = "9".repeat(40);
  assert.throws(() => validateServerEvidence(
    wrongSource, manifest, browser, runtime),
    /identity or enrollment order/);

  const staleAccepted = structuredClone(baseline);
  staleAccepted.password.stale_conflict.accepted_publications = "1";
  assert.throws(() => validateServerEvidence(
    staleAccepted, manifest, browser, runtime),
    /stale password mutation/);

  const uint32 = structuredClone(baseline);
  uint32.counter_probe.uint32_plus_one = "4294967295";
  assert.throws(() => validateServerEvidence(uint32, manifest, browser, runtime),
    /64-bit sequence/);

  const secretLog = structuredClone(baseline);
  secretLog.logs.password_values_detected = true;
  assert.throws(() => validateServerEvidence(
    secretLog, manifest, browser, runtime),
    /password value/);

  const tabs = structuredClone(baseline);
  tabs.journal.tabs_records = "1";
  assert.throws(() => validateServerEvidence(tabs, manifest, browser, runtime),
    /schema-2 boundary/);
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
