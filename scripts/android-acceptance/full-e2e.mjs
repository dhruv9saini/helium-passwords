#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {auditVerifiedThreeClientRun} from
  "../sync-runtime/three-client-acceptance.mjs";
import {auditDeviceFinal as auditNativeRecoveryDevice} from
  "../native-recovery/acceptance.mjs";
import {auditProbePair} from "../android-media/audit-probe-pair.mjs";
import {auditLinuxFullGraphEvidence} from "../linux-full-graph-audit.mjs";
import {validatePhysicalDeviceIdentity} from
  "./physical-device-identity.mjs";
import {validateLinuxHostIdentity} from
  "../sync-runtime/execution-identity.mjs";
import {
  loadSigningKey,
  readAuthenticatedEvidence,
  sha256,
} from "../tabs/tab-proof-lib.mjs";
import {readAuthenticatedFaultOperation} from
  "../tabs/tab-fault-operation.mjs";

const HASH = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const TEST_PACKAGE = "computer.helium.sync.test";
const CONTROL_PACKAGE = "computer.helium.control.test";
const LINUX_DEPOT_TOOLS_COMMIT =
  "980d6af16e06ff993a52029019dc0628c0a0e1f0";
const TAB_DESTINATIONS = Object.freeze(["da-copy", "nas-on-lm"]);
const TAB_MECHANISMS = Object.freeze([
  "chromium-native-session",
  "neutral-topology",
  "full-profile",
]);
const DESKTOP_TAB_DESTINATIONS = Object.freeze({
  d: Object.freeze(["da-copy", "nas-on-lm"]),
  da: Object.freeze(["d-copy", "nas-on-lm"]),
});

function fail(message) {
  throw new Error(message);
}

function equal(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !equal(Object.keys(value).sort(), [...expected].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
}

function requireHash(value, label) {
  if (typeof value !== "string" || !HASH.test(value)) {
    fail(`${label} must be a SHA-256 value`);
  }
  return value;
}

function requireCommit(value, label) {
  if (typeof value !== "string" || !COMMIT.test(value)) {
    fail(`${label} must be a full commit`);
  }
  return value;
}

async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function regularFile(file, label, maximum = 2 * 1024 * 1024 * 1024) {
  const resolved = path.resolve(file);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
      stat.size > maximum) {
    fail(`${label} must be a nonempty regular file within its size limit`);
  }
  return {resolved, stat};
}

async function realDirectory(directory, label) {
  const resolved = path.resolve(directory);
  const stat = await fsp.lstat(resolved);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      await fsp.realpath(resolved) !== resolved) {
    fail(`${label} must be a canonical real directory`);
  }
  return resolved;
}

async function readJSON(file, label) {
  const admitted = await regularFile(file, label, 8 * 1024 * 1024);
  const raw = await fsp.readFile(admitted.resolved, "utf8");
  return {file: admitted.resolved, raw, value: JSON.parse(raw)};
}

async function readEnv(file, expected, label) {
  const admitted = await regularFile(file, label, 1024 * 1024);
  const raw = await fsp.readFile(admitted.resolved, "utf8");
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (separator < 1 || !value || values.has(key) || /[\r\n\0]/.test(value)) {
      fail(`${label} is malformed`);
    }
    values.set(key, value);
  }
  if (expected && !equal([...values.keys()].sort(), [...expected].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
  return {file: admitted.resolved, raw, values};
}

async function walkFiles(root, relative = "") {
  const result = [];
  const directory = path.join(root, relative);
  for (const entry of await fsp.readdir(directory, {withFileTypes: true})) {
    const child = relative ? path.posix.join(relative, entry.name) : entry.name;
    if (entry.isDirectory()) {
      result.push(...await walkFiles(root, child));
    } else if (entry.isFile() && !entry.isSymbolicLink()) {
      result.push(child);
    } else {
      fail(`unsafe file-system entry in admitted directory: ${child}`);
    }
  }
  return result.sort();
}

async function auditChecksumDirectory(root, inventoryName, label) {
  const inventory = await regularFile(
    path.join(root, inventoryName), `${label} checksum inventory`, 16 * 1024 * 1024);
  const raw = await fsp.readFile(inventory.resolved, "utf8");
  const recorded = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  \.\/(.+)$/.exec(line);
    if (!match || match[2].startsWith("/") || match[2].includes("\\") ||
        match[2].split("/").some(part => !part || part === "." || part === "..") ||
        recorded.has(match[2])) {
      fail(`${label} checksum inventory is malformed`);
    }
    recorded.set(match[2], match[1]);
  }
  const actual = (await walkFiles(root)).filter(name => name !== inventoryName);
  if (!equal([...recorded.keys()].sort(), actual)) {
    fail(`${label} checksum inventory is incomplete or unexpected`);
  }
  for (const relative of actual) {
    if (await sha256File(path.join(root, relative)) !== recorded.get(relative)) {
      fail(`${label} file changed after admission: ${relative}`);
    }
  }
  return {raw, sha256: sha256(Buffer.from(raw))};
}

async function auditFlatEvidence(directory, label) {
  const root = await realDirectory(directory, label);
  const inventory = await readEnv(
    path.join(root, "acceptance.env"), null, `${label} embedded acceptance`);
  const sums = await regularFile(
    path.join(root, "EVIDENCE_SHA256SUMS"), `${label} evidence inventory`);
  const raw = await fsp.readFile(sums.resolved, "utf8");
  const recorded = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
    if (!match || recorded.has(match[2]) || match[2] === "EVIDENCE_SHA256SUMS") {
      fail(`${label} evidence inventory is malformed`);
    }
    recorded.set(match[2], match[1]);
  }
  const entries = await fsp.readdir(root, {withFileTypes: true});
  if (entries.some(entry => !entry.isFile() || entry.isSymbolicLink())) {
    fail(`${label} evidence contains a non-file entry`);
  }
  const actual = entries.map(entry => entry.name)
    .filter(name => name !== "EVIDENCE_SHA256SUMS").sort();
  if (!equal([...recorded.keys()].sort(), actual)) {
    fail(`${label} evidence inventory is incomplete or unexpected`);
  }
  for (const name of actual) {
    if (await sha256File(path.join(root, name)) !== recorded.get(name)) {
      fail(`${label} evidence changed after capture: ${name}`);
    }
  }
  return {root, embeddedAcceptance: inventory};
}

const ACCEPTANCE_FIELDS = Object.freeze([
  "schema_version", "package", "helium_sync_commit", "chromium_commit",
  "version_code", "version_name", "source_archive_sha256", "apk_sha256",
  "runtime_kit_sha256", "prepared_at",
]);

async function auditPreparedAcceptance(directory, archivePath, expectedPackage,
  expectedSourceCommit) {
  const root = await realDirectory(directory, `${expectedPackage} acceptance`);
  const inventory = await auditChecksumDirectory(
    root, "PACKAGE_SHA256SUMS", `${expectedPackage} acceptance`);
  const metadata = await readEnv(
    path.join(root, "acceptance.env"), ACCEPTANCE_FIELDS,
    `${expectedPackage} acceptance metadata`);
  const value = name => metadata.values.get(name);
  if (value("schema_version") !== "2" || value("package") !== expectedPackage ||
      value("helium_sync_commit") !== expectedSourceCommit ||
      !COMMIT.test(value("chromium_commit")) ||
      !/^[1-9][0-9]*$/.test(value("version_code")) ||
      !/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(value("version_name")) ||
      !Number.isFinite(Date.parse(value("prepared_at")))) {
    fail(`${expectedPackage} acceptance identity is invalid`);
  }
  for (const name of [
    "source_archive_sha256", "apk_sha256", "runtime_kit_sha256",
  ]) requireHash(value(name), `${expectedPackage} ${name}`);
  const archive = await regularFile(
    archivePath, `${expectedPackage} returned Android archive`,
    16 * 1024 * 1024 * 1024,
  );
  const archiveSHA256 = await sha256File(archive.resolved);
  if (archiveSHA256 !== value("source_archive_sha256")) {
    fail(`${expectedPackage} prepared acceptance does not admit its returned archive`);
  }
  const apk = path.join(root, "Browser-test.apk");
  if (await sha256File(apk) !== value("apk_sha256")) {
    fail(`${expectedPackage} APK changed after preparation`);
  }
  const kit = await readEnv(path.join(root, "runtime-acceptance", "kit.env"), [
    "schema_version", "probe_schema_version", "helium_sync_commit",
    "runtime_kit_commit", "runtime_kit_source_sha256", "chromium_commit",
    "manifest_package", "version_code", "version_name", "target_cpu",
    "artifact_target",
  ], `${expectedPackage} runtime kit`);
  if (kit.values.get("schema_version") !== "7" ||
      kit.values.get("helium_sync_commit") !== expectedSourceCommit ||
      kit.values.get("chromium_commit") !== value("chromium_commit") ||
      kit.values.get("manifest_package") !== expectedPackage ||
      kit.values.get("version_code") !== value("version_code") ||
      kit.values.get("version_name") !== value("version_name") ||
      kit.values.get("target_cpu") !== "arm64" ||
      kit.values.get("artifact_target") !== "chrome_public_apk") {
    fail(`${expectedPackage} runtime kit disagrees with its acceptance`);
  }
  requireCommit(kit.values.get("runtime_kit_commit"),
    `${expectedPackage} runtime-kit commit`);
  requireHash(kit.values.get("runtime_kit_source_sha256"),
    `${expectedPackage} runtime-kit source inventory`);
  const tooling = await readEnv(
    path.join(root, "build-provenance", "android-tooling.env"), null,
    `${expectedPackage} Android tooling receipt`);
  requireCommit(tooling.values.get("tooling_commit"),
    `${expectedPackage} tooling commit`);
  if (tooling.values.get("runtime_kit_commit") !==
        kit.values.get("runtime_kit_commit") ||
      tooling.values.get("runtime_kit_source_sha256") !==
        kit.values.get("runtime_kit_source_sha256")) {
    fail(`${expectedPackage} tooling and runtime-kit bindings disagree`);
  }
  const runtimeKitInventory = path.join(
    root, "runtime-acceptance", "SHA256SUMS");
  if (await sha256File(runtimeKitInventory) !== value("runtime_kit_sha256")) {
    fail(`${expectedPackage} runtime-kit inventory changed after preparation`);
  }
  const recordedSourceCommit = (await fsp.readFile(path.join(
    root, "build-provenance", "helium-sync-commit.txt"), "utf8")).trim();
  if (recordedSourceCommit !== expectedSourceCommit) {
    fail(`${expectedPackage} source provenance disagrees with its acceptance`);
  }
  let coreCommit = null;
  const coreCommitPath = path.join(
    root, "build-provenance", "helium-core-commit.txt");
  if (expectedPackage === TEST_PACKAGE) {
    coreCommit = (await fsp.readFile(coreCommitPath, "utf8")).trim();
    requireCommit(coreCommit, `${expectedPackage} Helium core commit`);
  } else {
    try {
      await fsp.lstat(coreCommitPath);
      fail("control acceptance unexpectedly carries patched core provenance");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  return {
    root,
    inventory_sha256: inventory.sha256,
    metadata_sha256: sha256(Buffer.from(metadata.raw)),
    package: expectedPackage,
    helium_sync_commit: expectedSourceCommit,
    helium_core_commit: coreCommit,
    chromium_commit: value("chromium_commit"),
    version_code: value("version_code"),
    version_name: value("version_name"),
    source_archive_sha256: value("source_archive_sha256"),
    source_archive_path: archive.resolved,
    source_archive_size: archive.stat.size,
    apk_sha256: value("apk_sha256"),
    runtime_kit_sha256: value("runtime_kit_sha256"),
    runtime_kit_commit: kit.values.get("runtime_kit_commit"),
    runtime_kit_source_sha256: kit.values.get("runtime_kit_source_sha256"),
    tooling_commit: tooling.values.get("tooling_commit"),
  };
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map(key =>
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function auditMediaPair(options, sync, control) {
  const replayed = await auditProbePair({
    syncAcceptance: sync.root,
    syncEvidence: options.syncEvidence,
    controlAcceptance: control.root,
    controlEvidence: options.controlEvidence,
  });
  const syncEvidence = await auditFlatEvidence(options.syncEvidence,
    "Sync device evidence");
  const controlEvidence = await auditFlatEvidence(options.controlEvidence,
    "control device evidence");
  if (syncEvidence.embeddedAcceptance.raw !==
        await fsp.readFile(path.join(sync.root, "acceptance.env"), "utf8") ||
      controlEvidence.embeddedAcceptance.raw !==
        await fsp.readFile(path.join(control.root, "acceptance.env"), "utf8")) {
    fail("device evidence is not bound to its prepared acceptance");
  }
  const pair = await readEnv(options.mediaPairReceipt, [
    "schema_version", "helium_sync_commit", "chromium_commit",
    "sync_archive_sha256", "sync_apk_sha256", "sync_result_sha256",
    "control_archive_sha256", "control_apk_sha256",
    "control_result_sha256", "shared_flags_gn_sha256",
    "shared_locked_gn_args_sha256", "fixture_receipt_sha256",
    "media_manifest_sha256", "physical_identity_sha256",
    "offline_auditor_sha256", "verified_at",
  ], "Android media A/B receipt");
  const value = name => pair.values.get(name);
  if (value("schema_version") !== "2" ||
      value("helium_sync_commit") !== sync.helium_sync_commit ||
      value("chromium_commit") !== sync.chromium_commit ||
      value("sync_archive_sha256") !== sync.source_archive_sha256 ||
      value("sync_apk_sha256") !== sync.apk_sha256 ||
      value("control_archive_sha256") !== control.source_archive_sha256 ||
      value("control_apk_sha256") !== control.apk_sha256 ||
      value("physical_identity_sha256") !==
        replayed.physical_identity_sha256 ||
      value("offline_auditor_sha256") !== replayed.offline_auditor_sha256 ||
      !Number.isFinite(Date.parse(value("verified_at")))) {
    fail("Android media A/B receipt identity is invalid");
  }
  for (const field of [
    "sync_result_sha256", "control_result_sha256",
    "shared_flags_gn_sha256", "shared_locked_gn_args_sha256",
    "fixture_receipt_sha256", "media_manifest_sha256",
    "physical_identity_sha256", "offline_auditor_sha256",
  ]) requireHash(value(field), `media pair ${field}`);
  for (const field of [
    "helium_sync_commit", "chromium_commit", "sync_archive_sha256",
    "sync_apk_sha256", "sync_result_sha256", "control_archive_sha256",
    "control_apk_sha256", "control_result_sha256", "shared_flags_gn_sha256",
    "shared_locked_gn_args_sha256", "fixture_receipt_sha256",
    "media_manifest_sha256", "physical_identity_sha256",
    "offline_auditor_sha256",
  ]) {
    if (value(field) !== replayed[field]) {
      fail(`Android media receipt is not reproducible from ${field}`);
    }
  }
  const syncResult = await readJSON(path.join(
    syncEvidence.root, "result.json"), "Sync device result");
  const controlResult = await readJSON(path.join(
    controlEvidence.root, "result.json"), "control device result");
  if (sha256(Buffer.from(syncResult.raw)) !== value("sync_result_sha256") ||
      sha256(Buffer.from(controlResult.raw)) !== value("control_result_sha256")) {
    fail("Android media result changed after pair verification");
  }
  const flags = path.join(sync.root, "build-provenance", "flags.gn");
  const locked = path.join(
    sync.root, "build-provenance", "locked-gn-args-resolved.txt");
  if (await sha256File(flags) !== value("shared_flags_gn_sha256") ||
      await sha256File(path.join(control.root, "build-provenance", "flags.gn")) !==
        value("shared_flags_gn_sha256") ||
      await sha256File(locked) !== value("shared_locked_gn_args_sha256") ||
      await sha256File(path.join(control.root, "build-provenance",
        "locked-gn-args-resolved.txt")) !==
        value("shared_locked_gn_args_sha256")) {
    fail("Sync/control locked GN provenance changed after pair verification");
  }
  const fixture = path.join(syncEvidence.root, "fixture-provenance.json");
  if (await sha256File(fixture) !== value("fixture_receipt_sha256") ||
      await sha256File(path.join(controlEvidence.root,
        "fixture-provenance.json")) !== value("fixture_receipt_sha256")) {
    fail("Sync/control protocol fixture binding changed");
  }
  const syncMedia = canonicalJSON(syncResult.value.media_manifest);
  const controlMedia = canonicalJSON(controlResult.value.media_manifest);
  if (syncMedia !== controlMedia ||
      sha256(Buffer.from(syncMedia)) !== value("media_manifest_sha256")) {
    fail("Sync/control media manifests no longer match the pair receipt");
  }
  for (const [label, evidence, expectedPackage] of [
    ["Sync", syncEvidence, TEST_PACKAGE],
    ["control", controlEvidence, CONTROL_PACKAGE],
  ]) {
    const actions = await readEnv(path.join(evidence.root, "actions.env"), null,
      `${label} device actions`);
    if (actions.values.get("package") !== expectedPackage ||
        actions.values.get("background_foreground") !== "true" ||
        actions.values.get("network_handoff") !== "wifi-to-cellular") {
      fail(`${label} evidence does not contain the complete device lifecycle`);
    }
  }
  return {
    receipt_sha256: sha256(Buffer.from(pair.raw)),
    fixture_receipt_sha256: value("fixture_receipt_sha256"),
    media_manifest_sha256: value("media_manifest_sha256"),
    physical_identity: replayed.sync.physical_identity,
    offline_auditor_sha256: value("offline_auditor_sha256"),
    verified_at: value("verified_at"),
  };
}

async function auditFullGraphReceipt(file, expected) {
  const admitted = await regularFile(file, "returned Linux full-graph receipt");
  if (path.basename(admitted.resolved) !== "receipt.env") {
    fail("returned Linux full-graph input must be the schema-3 evidence receipt");
  }
  const graph = await auditLinuxFullGraphEvidence(
    path.dirname(admitted.resolved), expected);
  return {
    ...graph,
    receipt_sha256: graph.receiptSha256,
    inventory_sha256: graph.inventorySha256,
    job: graph.receipt.job,
    validated_at: graph.receipt.captured_at,
  };
}

async function auditThreeClient(runRoot, sync, expectedSourceCommit,
  linuxInputs) {
  const audited = await auditVerifiedThreeClientRun(runRoot);
  if (audited.receipt.result !== "passed" ||
      audited.receipt.source_train.source_commit !== expectedSourceCommit ||
      audited.receipt.source_train.core_commit !== sync.helium_core_commit ||
      audited.receipt.source_train.chromium_commit !== sync.chromium_commit ||
      audited.receipt.artifact_sha256.oneplus !== sync.apk_sha256 ||
      audited.receipt.enrollment_order.join(",") !== "d,da,oneplus" ||
      audited.receipt.tabs_policy !== "excluded") {
    fail("three-client password/sync receipt does not match the Android artifact");
  }
  const archive = await regularFile(
    linuxInputs.artifact, "returned Linux x86_64 archive",
    16 * 1024 * 1024 * 1024,
  );
  const deployment = await readEnv(linuxInputs.deploymentReceipt, [
    "schema_version", "artifact_sha256", "artifact_size", "target",
    "helium_sync_commit", "helium_passwords_commit", "helium_core_commit",
    "chromium_commit", "build_job_id", "provenance_sha256",
    "full_graph_receipt_sha256", "full_graph_inventory_sha256", "created_at",
  ], "returned Linux deployment receipt");
  const deploymentValue = name => deployment.values.get(name);
  const archiveSHA256 = await sha256File(archive.resolved);
  if (path.basename(archive.resolved) !==
        "helium-sync-linux-x86_64.tar.xz" ||
      path.basename(deployment.file) !==
        "helium-sync-linux-x86_64.receipt.env" ||
      deploymentValue("schema_version") !== "2" ||
      deploymentValue("artifact_sha256") !== archiveSHA256 ||
      deploymentValue("artifact_size") !== String(archive.stat.size) ||
      deploymentValue("target") !== "linux-x86_64" ||
      deploymentValue("helium_sync_commit") !== expectedSourceCommit ||
      deploymentValue("helium_passwords_commit") !==
        audited.receipt.source_train.passwords_commit ||
      deploymentValue("helium_core_commit") !== sync.helium_core_commit ||
      deploymentValue("chromium_commit") !== sync.chromium_commit ||
      !COMMIT.test(deploymentValue("helium_passwords_commit")) ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(
        deploymentValue("build_job_id") || "") ||
      !/^[1-9][0-9]*$/.test(deploymentValue("artifact_size") || "") ||
      !Number.isFinite(Date.parse(deploymentValue("created_at")))) {
    fail("returned Linux deployment receipt is invalid or source-mismatched");
  }
  requireHash(deploymentValue("provenance_sha256"),
    "Linux deployment provenance");
  requireHash(deploymentValue("full_graph_receipt_sha256"),
    "Linux deployment full-graph receipt");
  requireHash(deploymentValue("full_graph_inventory_sha256"),
    "Linux deployment full-graph inventory");
  const deploymentSHA256 = sha256(Buffer.from(deployment.raw));
  const graph = await auditFullGraphReceipt(
    linuxInputs.fullGraphReceipt, {
      job: deploymentValue("build_job_id"),
      sourceCommit: expectedSourceCommit,
      passwordsCommit: deploymentValue("helium_passwords_commit"),
      coreCommit: sync.helium_core_commit,
      chromiumCommit: sync.chromium_commit,
    });
  if (deploymentValue("full_graph_receipt_sha256") !== graph.receipt_sha256 ||
      deploymentValue("full_graph_inventory_sha256") !== graph.inventory_sha256) {
    fail("returned deployment receipt does not bind its full-graph evidence");
  }
  const linux = {};
  for (const device of ["d", "da"]) {
    const admitted = audited.manifest.devices[device];
    const admittedArtifact = await regularFile(admitted.artifact_path,
      `${device} admitted Linux browser`);
    const internalGraph = await auditLinuxFullGraphEvidence(
      admitted.admission.full_graph_root_path, {
        job: deploymentValue("build_job_id"),
        sourceCommit: expectedSourceCommit,
        passwordsCommit: deploymentValue("helium_passwords_commit"),
        coreCommit: sync.helium_core_commit,
        chromiumCommit: sync.chromium_commit,
      });
    if (admitted.platform !== "linux" || admitted.target !== "linux-x86_64" ||
        admitted.artifact_sha256 !== await sha256File(admittedArtifact.resolved) ||
        admitted.admission.returned_archive_sha256 !== archiveSHA256 ||
        admitted.admission.deployment_receipt_sha256 !== deploymentSHA256 ||
        admitted.admission.provenance_manifest_sha256 !==
          deploymentValue("provenance_sha256") ||
        admitted.admission.full_graph_receipt_sha256 !== graph.receipt_sha256 ||
        admitted.admission.full_graph_inventory_sha256 !==
          graph.inventory_sha256 ||
        internalGraph.receiptSha256 !== graph.receipt_sha256 ||
        internalGraph.inventorySha256 !== graph.inventory_sha256 ||
        admitted.admission.build_job_id !== deploymentValue("build_job_id") ||
        admitted.admission.depot_tools_commit !== LINUX_DEPOT_TOOLS_COMMIT) {
      fail(`${device} three-client run does not use the supplied Linux provenance`);
    }
    linux[device] = {
      browser_sha256: admitted.artifact_sha256,
      browser_size: admittedArtifact.stat.size,
      runtime_receipt_sha256: admitted.admission.receipt_sha256,
      returned_archive_sha256: admitted.admission.returned_archive_sha256,
      deployment_receipt_sha256: deploymentSHA256,
      provenance_manifest_sha256: admitted.admission.provenance_manifest_sha256,
      full_graph_receipt_sha256: internalGraph.receiptSha256,
      full_graph_inventory_sha256: internalGraph.inventorySha256,
      depot_tools_commit: admitted.admission.depot_tools_commit,
      build_job_id: admitted.admission.build_job_id,
    };
  }
  for (const field of [
    "browser_sha256", "browser_size", "returned_archive_sha256",
    "deployment_receipt_sha256", "provenance_manifest_sha256",
    "full_graph_receipt_sha256", "full_graph_inventory_sha256",
    "depot_tools_commit", "build_job_id",
  ]) {
    if (linux.d[field] !== linux.da[field]) {
      fail(`d and da do not share the Linux runtime field: ${field}`);
    }
  }
  const receiptFile = path.join(audited.root, "verified", "receipt.json");
  return {
    receipt_sha256: await sha256File(receiptFile),
    d_apk_or_browser_sha256: audited.receipt.artifact_sha256.d,
    da_apk_or_browser_sha256: audited.receipt.artifact_sha256.da,
    oneplus_apk_sha256: audited.receipt.artifact_sha256.oneplus,
    returned_artifact: {
      path: archive.resolved,
      sha256: archiveSHA256,
      size: archive.stat.size,
      deployment_receipt_sha256: deploymentSHA256,
      full_graph_receipt_sha256: graph.receipt_sha256,
      full_graph_inventory_sha256: graph.inventory_sha256,
      build_job_id: deploymentValue("build_job_id"),
      helium_passwords_commit: deploymentValue("helium_passwords_commit"),
      depot_tools_commit: linux.d.depot_tools_commit,
    },
    linux,
    execution_identity: Object.fromEntries(["d", "da", "oneplus"].map(
      device => [device, audited.manifest.devices[device].execution_identity])),
    verified_at: audited.receipt.verified_at,
  };
}

const TAB_STATUS_FIELDS = Object.freeze([
  "version", "mechanism", "state", "platform", "package_id",
  "browser_sha256", "source_generation", "source_device", "profile",
  "completed_unix", "generation", "evidence",
]);

async function auditDesktopTabEvidence(directories, statusFiles, keyFile,
  device, linuxRuntime) {
  if (!Array.isArray(directories) || directories.length !== 5) {
    fail(`${device} requires exactly five authenticated desktop tab proofs`);
  }
  if (!Array.isArray(statusFiles) || statusFiles.length !== 3) {
    fail(`${device} requires exactly three emitted tab status receipts`);
  }
  const key = loadSigningKey(keyFile);
  const evidence = directories.map(directory =>
    readAuthenticatedEvidence(path.resolve(directory), key));
  const executionIdentity = validateLinuxHostIdentity(
    evidence[0].value.execution_identity, device);
  if (evidence.some(item => item.value.execution_identity.host_identity_sha256 !==
      executionIdentity.host_identity_sha256)) {
    fail(`${device} desktop proofs do not share one executing host identity`);
  }
  const groups = new Map(TAB_MECHANISMS.map(mechanism => [mechanism, []]));
  for (const item of evidence) {
    const value = item.value;
    if (value.platform !== "desktop" || value.package_id !== "desktop" ||
        value.source_device !== device || value.profile !== "default" ||
        value.browser.sha256 !== linuxRuntime.browser_sha256 ||
        value.browser.size !== linuxRuntime.browser_size) {
      fail(`${device} tab proof does not match its admitted Linux runtime`);
    }
    groups.get(value.mechanism)?.push(item);
  }
  const expectedCounts = new Map([
    ["chromium-native-session", 1],
    ["neutral-topology", 2],
    ["full-profile", 2],
  ]);
  const expectedDestinations = DESKTOP_TAB_DESTINATIONS[device];
  for (const [mechanism, count] of expectedCounts) {
    const items = groups.get(mechanism);
    if (items.length !== count) {
      fail(`${device} ${mechanism} requires exactly ${count} proofs`);
    }
    const first = items[0].value;
    for (const item of items) {
      if (item.value.generation !== first.generation ||
          !equal(item.value.expected_topology, first.expected_topology)) {
        fail(`${device} ${mechanism} proofs do not describe one generation`);
      }
    }
    if (count === 2) {
      const destinations = items.map(item =>
        item.value.source_binding.source_destination).sort();
      if (!equal(destinations, expectedDestinations)) {
        fail(`${device} ${mechanism} did not use both required destinations`);
      }
      if (new Set(items.map(item =>
        item.value.source_binding.archive_sha256)).size !== 1) {
        fail(`${device} ${mechanism} replicas do not bind one archive`);
      }
    }
  }
  const native = groups.get("chromium-native-session")[0];
  if (native.value.browser.display_mode !== "headed") {
    fail(`${device} native tab recovery did not exercise a headed desktop`);
  }
  for (const full of groups.get("full-profile")) {
    if (full.value.source_binding.expected_evidence_sha256 !== native.sha256) {
      fail(`${device} full-profile proof is not bound to its native topology`);
    }
  }

  const statusByMechanism = new Map();
  const statusHashes = [];
  const maximumAge = new Map([
    ["chromium-native-session", 2592000],
    ["neutral-topology", 1800],
    ["full-profile", 604800],
  ]);
  const now = Math.floor(Date.now() / 1000);
  for (const file of statusFiles) {
    const status = await readEnv(file, TAB_STATUS_FIELDS,
      `${device} tab status receipt`);
    const value = name => status.values.get(name);
    const mechanism = value("mechanism");
    const items = groups.get(mechanism);
    if (!items || statusByMechanism.has(mechanism)) {
      fail(`${device} tab status inventory is invalid`);
    }
    const stat = await fsp.lstat(status.file);
    const completed = Math.min(...items.map(item => item.value.completed_unix));
    const evidenceSHA256 = sha256(Buffer.from(
      `${items.map(item => item.sha256).sort().join("\n")}\n`));
    if ((stat.mode & 0o077) !== 0 || stat.isSymbolicLink() ||
        (typeof process.getuid === "function" && stat.uid !== process.getuid()) ||
        value("version") !== "2" || value("state") !== "healthy" ||
        value("platform") !== "desktop" || value("package_id") !== "desktop" ||
        value("browser_sha256") !== linuxRuntime.browser_sha256 ||
        value("source_generation") !== linuxRuntime.browser_sha256 ||
        value("source_device") !== device || value("profile") !== "default" ||
        value("completed_unix") !== String(completed) ||
        value("generation") !== items[0].value.generation ||
        value("evidence") !== evidenceSHA256 || completed > now ||
        now - completed > maximumAge.get(mechanism)) {
      fail(`${device} ${mechanism} status is stale, unsafe, or proof-mismatched`);
    }
    statusByMechanism.set(mechanism, status);
    statusHashes.push(sha256(Buffer.from(status.raw)));
  }
  if (statusByMechanism.size !== 3) {
    fail(`${device} tab statuses do not cover all three mechanisms`);
  }
  const full = groups.get("full-profile")[0].value;
  const neutral = groups.get("neutral-topology")[0].value;
  const fullCompleted = groups.get("full-profile")
    .map(item => item.value.completed_unix);
  return {
    evidence_set_sha256: sha256(Buffer.from(
      `${evidence.map(item => item.sha256).sort().join("\n")}\n`)),
    status_set_sha256: sha256(Buffer.from(
      `${statusHashes.sort().join("\n")}\n`)),
    native_evidence_sha256: native.sha256,
    neutral_evidence_sha256: groups.get("neutral-topology")
      .map(item => item.sha256).sort(),
    full_profile_evidence_sha256: groups.get("full-profile")
      .map(item => item.sha256).sort(),
    neutral_generation: neutral.generation,
    neutral_archive_sha256: neutral.source_binding.archive_sha256,
    full_profile_generation: full.generation,
    full_profile_archive_sha256: full.source_binding.archive_sha256,
    execution_identity: executionIdentity,
    first_completed_at: new Date(Math.min(...evidence.map(
      item => item.value.completed_unix)) * 1000).toISOString(),
    last_completed_at: new Date(Math.max(...evidence.map(
      item => item.value.completed_unix)) * 1000).toISOString(),
    native_completed_at: new Date(native.value.completed_unix * 1000).toISOString(),
    first_full_profile_completed_at: new Date(
      Math.min(...fullCompleted) * 1000).toISOString(),
  };
}

async function auditFaultOperationSet(operationDirectories, key, platform,
  device, normalTabs, fallbackProofs, matrixCases, matrixCompletedAt) {
  if (!Array.isArray(operationDirectories) || operationDirectories.length !== 4) {
    fail(`${device} tab fault recovery requires four authenticated operations`);
  }
  const producer = path.join(
    path.dirname(fileURLToPath(import.meta.url)), "..", "tabs",
    "tab-fault-operation.mjs");
  const producerSHA256 = await sha256File(producer);
  const operations = operationDirectories.map(directory =>
    readAuthenticatedFaultOperation(path.resolve(directory), key,
      producerSHA256));
  const byIdentity = new Map();
  for (const operation of operations) {
    const value = operation.value;
    const identity = `${value.fault}:${value.operation}`;
    const expectedIdentity = platform === "desktop"
      ? normalTabs.execution_identity.host_identity_sha256
      : normalTabs.execution_identity.physical_identity_sha256;
    if (byIdentity.has(identity) || value.platform !== platform ||
        value.source_device !== device || value.profile !== "default" ||
        value.execution_identity_sha256 !== expectedIdentity ||
        value.started_unix * 1000 < Date.parse(normalTabs.last_completed_at) ||
        value.completed_unix * 1000 > Date.parse(matrixCompletedAt)) {
      fail(`${device} tab fault operation identity or chronology is invalid`);
    }
    byIdentity.set(identity, operation);
  }
  for (const entry of matrixCases) {
    const rejection = byIdentity.get(`${entry.fault}:rejection`);
    const quarantine = byIdentity.get(`${entry.fault}:quarantine`);
    const proof = fallbackProofs.find(item =>
      item.value.mechanism === entry.affected_mechanism);
    const expectedPreFault = entry.affected_mechanism === "neutral-topology"
      ? normalTabs.neutral_archive_sha256
      : normalTabs.full_profile_archive_sha256;
    if (!rejection || !quarantine || !proof ||
        rejection.sha256 !== entry.rejection_receipt_sha256 ||
        quarantine.sha256 !== entry.quarantine_receipt_sha256) {
      fail(`${device} fault matrix does not reference its authenticated operations`);
    }
    const left = {...rejection.value};
    const right = {...quarantine.value};
    delete left.operation;
    delete right.operation;
    if (!equal(left, right) ||
        left.affected_mechanism !== entry.affected_mechanism ||
        left.damaged_generation !== entry.damaged_generation ||
        left.recovery_generation !== entry.recovery_generation ||
        left.pre_fault_archive_sha256 !== expectedPreFault ||
        left.fallback_evidence_sha256 !== proof.sha256 ||
        left.recovery_destination !==
          proof.value.source_binding.source_destination ||
        left.recovered_unix > proof.value.completed_unix ||
        (entry.damaged_destination !== undefined &&
          left.damaged_destination !== entry.damaged_destination) ||
        (entry.recovery_destination !== undefined &&
          left.recovery_destination !== entry.recovery_destination)) {
      fail(`${device} fault operations do not prove rejection, quarantine, and recovery`);
    }
  }
  if (byIdentity.size !== 4) {
    fail(`${device} tab fault operation inventory is incomplete`);
  }
  const hashes = operations.map(item => item.sha256).sort();
  return {
    hashes,
    set_sha256: sha256(Buffer.from(`${hashes.join("\n")}\n`)),
    first_started_at: new Date(Math.min(...operations.map(
      item => item.value.started_unix)) * 1000).toISOString(),
  };
}

async function auditDesktopTabFaultEvidence(file, fallbackDirectories,
  operationFiles, keyFile, device, linuxRuntime, normalTabs) {
  const evidence = await readJSON(file, `${device} desktop tab fault evidence`);
  exactKeys(evidence.value, [
    "schema_version", "evidence_type", "result", "platform", "package",
    "browser_sha256", "source_device", "profile",
    "personal_profile_touched", "cases", "completed_at",
  ], `${device} desktop tab fault evidence`);
  if (evidence.value.schema_version !== 1 ||
      evidence.value.evidence_type !== "helium-desktop-tab-fault-matrix-v1" ||
      evidence.value.result !== "passed" || evidence.value.platform !== "desktop" ||
      evidence.value.package !== "desktop" ||
      evidence.value.browser_sha256 !== linuxRuntime.browser_sha256 ||
      evidence.value.source_device !== device || evidence.value.profile !== "default" ||
      evidence.value.personal_profile_touched !== false ||
      !Number.isFinite(Date.parse(evidence.value.completed_at)) ||
      !Array.isArray(evidence.value.cases) || evidence.value.cases.length !== 2) {
    fail(`${device} desktop tab fault evidence identity is invalid`);
  }
  const expected = new Map([
    ["neutral-corrupt-newest-generation", {
      mechanism: "neutral-topology",
      rejection: "create-new-rejected",
      fallback: "previous-generation-restored",
      keys: [
        "fault", "affected_mechanism", "damaged_generation",
        "recovery_generation", "damaged_input_rejection",
        "rejection_receipt_sha256", "quarantine_receipt_sha256",
        "fallback_result", "fallback_evidence_sha256",
        "sibling_mechanisms_unchanged", "live_profile_touched",
      ],
    }],
    ["full-profile-corrupt-destination", {
      mechanism: "full-profile",
      rejection: "create-new-rejected",
      fallback: "independent-replica-restored",
      keys: [
        "fault", "affected_mechanism", "damaged_generation",
        "recovery_generation", "damaged_destination", "recovery_destination",
        "damaged_input_rejection", "rejection_receipt_sha256",
        "quarantine_receipt_sha256", "fallback_result",
        "fallback_evidence_sha256", "sibling_mechanisms_unchanged",
        "live_profile_touched",
      ],
    }],
  ]);
  if (!Array.isArray(fallbackDirectories) || fallbackDirectories.length !== 2) {
    fail(`${device} tab fault recovery requires exactly two fallback proofs`);
  }
  const key = loadSigningKey(keyFile);
  const fallbackProofs = fallbackDirectories.map(directory =>
    readAuthenticatedEvidence(path.resolve(directory), key));
  const normalHashes = new Set([
    normalTabs.native_evidence_sha256,
    ...normalTabs.neutral_evidence_sha256,
    ...normalTabs.full_profile_evidence_sha256,
  ]);
  const proofsByMechanism = new Map();
  for (const proof of fallbackProofs) {
    const value = proof.value;
    if (normalHashes.has(proof.sha256) || proofsByMechanism.has(value.mechanism) ||
        !new Set(["neutral-topology", "full-profile"]).has(value.mechanism) ||
        value.platform !== "desktop" || value.package_id !== "desktop" ||
        value.source_device !== device || value.profile !== "default" ||
        value.execution_identity.host_identity_sha256 !==
          normalTabs.execution_identity.host_identity_sha256 ||
        value.browser.sha256 !== linuxRuntime.browser_sha256 ||
        value.browser.size !== linuxRuntime.browser_size ||
        !DESKTOP_TAB_DESTINATIONS[device].includes(
          value.source_binding.source_destination) ||
        (value.mechanism === "full-profile" &&
          value.source_binding.expected_evidence_sha256 !==
            normalTabs.native_evidence_sha256)) {
      fail(`${device} tab fallback proof is not the admitted Linux runtime`);
    }
    proofsByMechanism.set(value.mechanism, proof);
  }
  const seen = new Set();
  const operationHashesReferenced = [];
  for (const entry of evidence.value.cases) {
    const wanted = expected.get(entry.fault);
    if (!wanted) fail(`${device} desktop tab fault case is unknown`);
    exactKeys(entry, wanted.keys, `${device} desktop tab fault case`);
    const proof = proofsByMechanism.get(wanted.mechanism);
    if (!proof || seen.has(entry.fault) ||
        entry.affected_mechanism !== wanted.mechanism ||
        entry.damaged_input_rejection !== wanted.rejection ||
        entry.fallback_result !== wanted.fallback ||
        entry.fallback_evidence_sha256 !== proof.sha256 ||
        entry.recovery_generation !== proof.value.generation ||
        typeof entry.damaged_generation !== "string" ||
        entry.sibling_mechanisms_unchanged !== true ||
        entry.live_profile_touched !== false) {
      fail(`${device} desktop tab fault did not fail independently and recover`);
    }
    requireHash(entry.rejection_receipt_sha256,
      `${device} ${entry.fault} rejection receipt`);
    requireHash(entry.quarantine_receipt_sha256,
      `${device} ${entry.fault} quarantine receipt`);
    requireHash(entry.fallback_evidence_sha256,
      `${device} ${entry.fault} fallback proof`);
    operationHashesReferenced.push(
      entry.rejection_receipt_sha256,
      entry.quarantine_receipt_sha256,
    );
    if (entry.fault === "neutral-corrupt-newest-generation") {
      if (entry.damaged_generation !== normalTabs.neutral_generation ||
          entry.damaged_generation === entry.recovery_generation) {
        fail(`${device} neutral fault did not use a prior valid generation`);
      }
    } else {
      const destinations = DESKTOP_TAB_DESTINATIONS[device];
      if (!destinations.includes(entry.damaged_destination) ||
          !destinations.includes(entry.recovery_destination) ||
          entry.damaged_destination === entry.recovery_destination ||
          entry.damaged_generation !== normalTabs.full_profile_generation ||
          entry.recovery_generation !== normalTabs.full_profile_generation ||
          proof.value.source_binding.source_destination !==
            entry.recovery_destination ||
          proof.value.source_binding.archive_sha256 !==
            normalTabs.full_profile_archive_sha256) {
        fail(`${device} full-profile fault did not use its independent replica`);
      }
    }
    seen.add(entry.fault);
  }
  const operationSet = await auditFaultOperationSet(
    operationFiles, key, "desktop", device, normalTabs, fallbackProofs,
    evidence.value.cases, evidence.value.completed_at);
  if (!equal(operationSet.hashes, operationHashesReferenced.sort())) {
    fail(`${device} authenticated fault operations do not match its matrix`);
  }
  const latestFallback = Math.max(...fallbackProofs.map(
    proof => proof.value.completed_unix)) * 1000;
  if (latestFallback > Date.parse(evidence.value.completed_at)) {
    fail(`${device} tab fault matrix predates its fallback proofs`);
  }
  return {
    receipt_sha256: sha256(Buffer.from(evidence.raw)),
    fallback_evidence_set_sha256: sha256(Buffer.from(
      `${fallbackProofs.map(proof => proof.sha256).sort().join("\n")}\n`)),
    operation_receipt_set_sha256: sha256(Buffer.from(
      `${operationSet.hashes.join("\n")}\n`)),
    first_fallback_at: new Date(Math.min(...fallbackProofs.map(
      proof => proof.value.completed_unix)) * 1000).toISOString(),
    completed_at: evidence.value.completed_at,
  };
}

const RESET_FIELDS = Object.freeze([
  "schema_version", "result", "package", "identity_schema", "adb_serial",
  "adb_transport", "adb_transport_id", "adb_usb_path_sha256",
  "android_model", "android_device", "android_product",
  "android_manufacturer", "build_fingerprint_sha256",
  "physical_identity_sha256", "physical_identity_captured_at",
  "physical_identity_tool_sha256",
  "from_phase", "to_phase", "helium_sync_commit", "chromium_commit",
  "source_archive_sha256", "acceptance_inventory_sha256", "apk_sha256",
  "version_code", "version_name", "production_package", "production_state",
  "production_identity_sha256", "global_state_sha256",
  "reset_boundary_sha256", "cleared_at",
]);

async function auditPhaseResets(files, sync) {
  if (!Array.isArray(files) || files.length !== 2) {
    fail("full Android acceptance requires exactly two package-reset receipts");
  }
  const resetBoundary = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "reset-disposable-package.sh",
  );
  const boundarySHA256 = await sha256File(resetBoundary);
  const identityBoundary = path.join(
    path.dirname(fileURLToPath(import.meta.url)),
    "physical-device-identity.mjs",
  );
  const identityBoundarySHA256 = await sha256File(identityBoundary);
  const transitions = new Map();
  for (const file of files) {
    const receipt = await readEnv(file, RESET_FIELDS,
      "Android package-reset receipt");
    const value = name => receipt.values.get(name);
    const transition = `${value("from_phase")}->${value("to_phase")}`;
    if (transitions.has(transition) ||
        !new Set([
          "media-cookie->password-sync",
          "password-sync->tab-recovery",
        ]).has(transition) ||
        value("schema_version") !== "2" || value("result") !== "passed" ||
        value("package") !== TEST_PACKAGE ||
        value("adb_transport") !== "physical-usb" ||
        !/^[A-Za-z0-9._-]+$/.test(value("adb_serial")) ||
        value("physical_identity_tool_sha256") !== identityBoundarySHA256 ||
        value("helium_sync_commit") !== sync.helium_sync_commit ||
        value("chromium_commit") !== sync.chromium_commit ||
        value("source_archive_sha256") !== sync.source_archive_sha256 ||
        value("acceptance_inventory_sha256") !== sync.inventory_sha256 ||
        value("apk_sha256") !== sync.apk_sha256 ||
        value("version_code") !== sync.version_code ||
        value("version_name") !== sync.version_name ||
        value("production_package") !== "computer.helium.sync" ||
        !new Set(["present", "absent"]).has(value("production_state")) ||
        value("reset_boundary_sha256") !== boundarySHA256 ||
        !Number.isFinite(Date.parse(value("cleared_at")))) {
      fail("Android package-reset receipt is invalid or artifact-mismatched");
    }
    requireHash(value("production_identity_sha256"),
      "production package identity");
    requireHash(value("global_state_sha256"), "Android global-state identity");
    const physicalIdentity = validatePhysicalDeviceIdentity({
      schema_version: 1,
      identity_schema: value("identity_schema"),
      adb_serial: value("adb_serial"),
      adb_transport: value("adb_transport"),
      adb_transport_id: value("adb_transport_id"),
      adb_usb_path_sha256: value("adb_usb_path_sha256"),
      android_model: value("android_model"),
      android_device: value("android_device"),
      android_product: value("android_product"),
      android_manufacturer: value("android_manufacturer"),
      build_fingerprint_sha256: value("build_fingerprint_sha256"),
      physical_identity_sha256: value("physical_identity_sha256"),
      captured_at: value("physical_identity_captured_at"),
    });
    transitions.set(transition, {
      receipt_sha256: sha256(Buffer.from(receipt.raw)),
      adb_serial: value("adb_serial"),
      production_state: value("production_state"),
      production_identity_sha256: value("production_identity_sha256"),
      global_state_sha256: value("global_state_sha256"),
      physical_identity: physicalIdentity,
      cleared_at: value("cleared_at"),
    });
  }
  const first = transitions.get("media-cookie->password-sync");
  const second = transitions.get("password-sync->tab-recovery");
  for (const field of [
    "adb_serial", "production_state", "production_identity_sha256",
    "global_state_sha256",
  ]) {
    if (first[field] !== second[field]) {
      fail(`Android package resets disagree on ${field}`);
    }
  }
  if (first.physical_identity.physical_identity_sha256 !==
      second.physical_identity.physical_identity_sha256) {
    fail("Android package resets used different physical OnePlus devices");
  }
  if (Date.parse(first.cleared_at) > Date.parse(second.cleared_at)) {
    fail("Android package-reset phase order is invalid");
  }
  return {
    adb_serial: first.adb_serial,
    physical_identity: first.physical_identity,
    media_to_sync: first,
    sync_to_tabs: second,
  };
}

async function auditTabEvidence(directories, statusFiles, keyFile, sync,
  adbSerial) {
  if (!Array.isArray(directories) || directories.length !== 5) {
    fail("full Android tab acceptance requires exactly five evidence directories");
  }
  if (!Array.isArray(statusFiles) || statusFiles.length !== 3) {
    fail("full Android tab acceptance requires exactly three status receipts");
  }
  const key = loadSigningKey(keyFile);
  const evidence = directories.map(directory =>
    readAuthenticatedEvidence(path.resolve(directory), key));
  const executionIdentity = validatePhysicalDeviceIdentity(
    evidence[0].value.execution_identity);
  if (new Set(evidence.map(item => item.value.browser.adb_serial)).size !== 1 ||
      evidence[0].value.browser.adb_serial !== adbSerial ||
      evidence.some(item => item.value.execution_identity.physical_identity_sha256 !==
        executionIdentity.physical_identity_sha256)) {
    fail("tab evidence did not use the package-reset physical USB ADB device");
  }
  const groups = new Map(TAB_MECHANISMS.map(mechanism => [mechanism, []]));
  for (const item of evidence) {
    const value = item.value;
    if (value.platform !== "android" || value.package_id !== TEST_PACKAGE ||
        value.source_device !== "oneplus" || value.profile !== "default" ||
        value.browser.sha256 !== sync.apk_sha256 ||
        value.browser.source_archive_sha256 !== sync.source_archive_sha256 ||
        value.browser.helium_sync_commit !== sync.helium_sync_commit ||
        value.browser.chromium_commit !== sync.chromium_commit ||
        value.browser.acceptance_dir !== sync.root ||
        value.browser.adb_serial.includes(":")) {
      fail("tab runtime evidence does not match one non-network Android admission");
    }
    groups.get(value.mechanism)?.push(item);
  }
  const expectedCounts = new Map([
    ["chromium-native-session", 1],
    ["neutral-topology", 2],
    ["full-profile", 2],
  ]);
  for (const [mechanism, count] of expectedCounts) {
    const items = groups.get(mechanism);
    if (items.length !== count) {
      fail(`${mechanism} requires exactly ${count} authenticated Android proofs`);
    }
    const first = items[0].value;
    for (const item of items) {
      if (item.value.generation !== first.generation ||
          !equal(item.value.expected_topology, first.expected_topology)) {
        fail(`${mechanism} proofs do not describe one recovery generation`);
      }
    }
    if (count === 2) {
      const destinations = items.map(item =>
        item.value.source_binding.source_destination).sort();
      if (!equal(destinations, TAB_DESTINATIONS)) {
        fail(`${mechanism} did not restore from NAS and da independently`);
      }
      const archives = new Set(items.map(item =>
        item.value.source_binding.archive_sha256));
      if (archives.size !== 1) {
        fail(`${mechanism} replica proofs do not bind one archive`);
      }
    }
  }
  const full = groups.get("full-profile")[0].value;
  const native = groups.get("chromium-native-session")[0].value;
  const neutral = groups.get("neutral-topology")[0].value;
  const nativeSHA256 = groups.get("chromium-native-session")[0].sha256;
  for (const item of groups.get("full-profile")) {
    if (item.value.source_binding.expected_evidence_sha256 !== nativeSHA256) {
      fail("Android full-profile proof is not bound to its native topology");
    }
  }

  const statusByMechanism = new Map();
  const statusHashes = [];
  const maximumAge = new Map([
    ["chromium-native-session", 2592000],
    ["neutral-topology", 1800],
    ["full-profile", 604800],
  ]);
  const now = Math.floor(Date.now() / 1000);
  for (const file of statusFiles) {
    const status = await readEnv(file, TAB_STATUS_FIELDS,
      "Android tab status receipt");
    const value = name => status.values.get(name);
    const mechanism = value("mechanism");
    const items = groups.get(mechanism);
    if (!items || statusByMechanism.has(mechanism)) {
      fail("Android tab status inventory is invalid");
    }
    const stat = await fsp.lstat(status.file);
    const completed = Math.min(...items.map(item => item.value.completed_unix));
    const evidenceSHA256 = sha256(Buffer.from(
      `${items.map(item => item.sha256).sort().join("\n")}\n`));
    if ((stat.mode & 0o077) !== 0 || stat.isSymbolicLink() ||
        (typeof process.getuid === "function" && stat.uid !== process.getuid()) ||
        value("version") !== "2" || value("state") !== "healthy" ||
        value("platform") !== "android" || value("package_id") !== TEST_PACKAGE ||
        value("browser_sha256") !== sync.apk_sha256 ||
        value("source_generation") !== sync.source_archive_sha256 ||
        value("source_device") !== "oneplus" || value("profile") !== "default" ||
        value("completed_unix") !== String(completed) ||
        value("generation") !== items[0].value.generation ||
        value("evidence") !== evidenceSHA256 || completed > now ||
        now - completed > maximumAge.get(mechanism)) {
      fail(`Android ${mechanism} status is stale, unsafe, or proof-mismatched`);
    }
    statusByMechanism.set(mechanism, status);
    statusHashes.push(sha256(Buffer.from(status.raw)));
  }
  if (statusByMechanism.size !== 3) {
    fail("Android tab statuses do not cover all three mechanisms");
  }
  const fullCompleted = groups.get("full-profile")
    .map(item => item.value.completed_unix);
  return {
    evidence_set_sha256: sha256(Buffer.from(
      `${evidence.map(item => item.sha256).sort().join("\n")}\n`)),
    status_set_sha256: sha256(Buffer.from(
      `${statusHashes.sort().join("\n")}\n`)),
    native_evidence_sha256: nativeSHA256,
    neutral_evidence_sha256: groups.get("neutral-topology")
      .map(item => item.sha256).sort(),
    full_profile_evidence_sha256: groups.get("full-profile")
      .map(item => item.sha256).sort(),
    full_profile_generation: full.generation,
    full_profile_archive_sha256: full.source_binding.archive_sha256,
    execution_identity: executionIdentity,
    neutral_generation: neutral.generation,
    neutral_archive_sha256: neutral.source_binding.archive_sha256,
    first_completed_at: new Date(Math.min(...evidence.map(
      item => item.value.completed_unix)) * 1000).toISOString(),
    last_completed_at: new Date(Math.max(...evidence.map(
      item => item.value.completed_unix)) * 1000).toISOString(),
    native_completed_at: new Date(native.completed_unix * 1000).toISOString(),
    first_full_profile_completed_at: new Date(
      Math.min(...fullCompleted) * 1000).toISOString(),
  };
}

async function auditTabFaultEvidence(file, fallbackDirectories, operationFiles,
  keyFile, sync, adbSerial, normalTabs) {
  const evidence = await readJSON(file, "Android tab fault evidence");
  exactKeys(evidence.value, [
    "schema_version", "evidence_type", "result", "platform", "package",
    "apk_sha256", "source_archive_sha256", "source_device", "profile",
    "production_package_touched", "personal_profile_touched", "cases",
    "completed_at",
  ], "Android tab fault evidence");
  if (evidence.value.schema_version !== 2 ||
      evidence.value.evidence_type !== "helium-android-tab-fault-matrix-v2" ||
      evidence.value.result !== "passed" || evidence.value.platform !== "android" ||
      evidence.value.package !== TEST_PACKAGE ||
      evidence.value.apk_sha256 !== sync.apk_sha256 ||
      evidence.value.source_archive_sha256 !== sync.source_archive_sha256 ||
      evidence.value.source_device !== "oneplus" ||
      evidence.value.profile !== "default" ||
      evidence.value.production_package_touched !== false ||
      evidence.value.personal_profile_touched !== false ||
      !Number.isFinite(Date.parse(evidence.value.completed_at)) ||
      !Array.isArray(evidence.value.cases) || evidence.value.cases.length !== 2) {
    fail("Android tab fault evidence identity is invalid");
  }
  const expected = new Map([
    ["neutral-corrupt-newest-generation", {
      mechanism: "neutral-topology",
      rejection: "create-new-rejected",
      fallback: "previous-generation-restored",
      keys: [
        "fault", "affected_mechanism", "damaged_generation",
        "recovery_generation", "damaged_input_rejection",
        "rejection_receipt_sha256", "quarantine_receipt_sha256",
        "fallback_result", "fallback_evidence_sha256",
        "sibling_mechanisms_unchanged", "live_profile_touched",
      ],
    }],
    ["full-profile-corrupt-destination", {
      mechanism: "full-profile",
      rejection: "create-new-rejected",
      fallback: "independent-replica-restored",
      keys: [
        "fault", "affected_mechanism", "damaged_generation",
        "recovery_generation", "damaged_destination", "recovery_destination",
        "damaged_input_rejection", "rejection_receipt_sha256",
        "quarantine_receipt_sha256", "fallback_result",
        "fallback_evidence_sha256", "sibling_mechanisms_unchanged",
        "live_profile_touched",
      ],
    }],
  ]);
  if (!Array.isArray(fallbackDirectories) || fallbackDirectories.length !== 2) {
    fail("tab fault recovery requires exactly two authenticated fallback proofs");
  }
  const key = loadSigningKey(keyFile);
  const fallbackProofs = fallbackDirectories.map(directory =>
    readAuthenticatedEvidence(path.resolve(directory), key));
  const normalProofHashes = new Set([
    normalTabs.native_evidence_sha256,
    ...normalTabs.neutral_evidence_sha256,
    ...normalTabs.full_profile_evidence_sha256,
  ]);
  const proofsByMechanism = new Map();
  for (const proof of fallbackProofs) {
    const value = proof.value;
    if (normalProofHashes.has(proof.sha256) ||
        proofsByMechanism.has(value.mechanism) ||
        !new Set(["neutral-topology", "full-profile"]).has(value.mechanism) ||
        value.platform !== "android" || value.package_id !== TEST_PACKAGE ||
        value.source_device !== "oneplus" || value.profile !== "default" ||
        value.browser.sha256 !== sync.apk_sha256 ||
        value.browser.source_archive_sha256 !== sync.source_archive_sha256 ||
        value.browser.helium_sync_commit !== sync.helium_sync_commit ||
        value.browser.chromium_commit !== sync.chromium_commit ||
        value.browser.acceptance_dir !== sync.root ||
        value.browser.adb_serial !== adbSerial ||
        value.execution_identity.physical_identity_sha256 !==
          normalTabs.execution_identity.physical_identity_sha256 ||
        !TAB_DESTINATIONS.includes(value.source_binding.source_destination) ||
        (value.mechanism === "full-profile" &&
          value.source_binding.expected_evidence_sha256 !==
            normalTabs.native_evidence_sha256)) {
      fail("tab fault fallback proof is not the admitted Android artifact");
    }
    proofsByMechanism.set(value.mechanism, proof);
  }
  const seen = new Set();
  const referencedOperationHashes = [];
  for (const entry of evidence.value.cases) {
    const wanted = expected.get(entry.fault);
    if (!wanted) fail("Android tab fault case is unknown");
    exactKeys(entry, wanted.keys, "Android tab fault case");
    const proof = proofsByMechanism.get(wanted.mechanism);
    if (!proof || seen.has(entry.fault) ||
        entry.affected_mechanism !== wanted.mechanism ||
        entry.damaged_input_rejection !== wanted.rejection ||
        entry.fallback_result !== wanted.fallback ||
        entry.fallback_evidence_sha256 !== proof.sha256 ||
        entry.recovery_generation !== proof.value.generation ||
        typeof entry.damaged_generation !== "string" ||
        entry.sibling_mechanisms_unchanged !== true ||
        entry.live_profile_touched !== false) {
      fail("Android tab fault case did not fail independently and recover");
    }
    requireHash(entry.rejection_receipt_sha256,
      `${entry.fault} rejection receipt`);
    requireHash(entry.quarantine_receipt_sha256,
      `${entry.fault} quarantine receipt`);
    referencedOperationHashes.push(
      entry.rejection_receipt_sha256,
      entry.quarantine_receipt_sha256,
    );
    requireHash(entry.fallback_evidence_sha256,
      `${entry.fault} fallback evidence`);
    if (entry.fault === "neutral-corrupt-newest-generation") {
      if (entry.damaged_generation !== normalTabs.neutral_generation ||
          entry.damaged_generation === entry.recovery_generation) {
        fail("neutral fault did not restore a distinct previous generation");
      }
    } else {
      if (!TAB_DESTINATIONS.includes(entry.damaged_destination) ||
          !TAB_DESTINATIONS.includes(entry.recovery_destination) ||
          entry.damaged_destination === entry.recovery_destination ||
          entry.damaged_generation !== normalTabs.full_profile_generation ||
          entry.recovery_generation !== normalTabs.full_profile_generation ||
          proof.value.source_binding.source_destination !==
            entry.recovery_destination ||
          proof.value.source_binding.archive_sha256 !==
            normalTabs.full_profile_archive_sha256) {
        fail("full-profile fault did not recover from the independent replica");
      }
    }
    seen.add(entry.fault);
  }
  const operationSet = await auditFaultOperationSet(
    operationFiles, key, "android", "oneplus", normalTabs, fallbackProofs,
    evidence.value.cases, evidence.value.completed_at);
  if (!equal(operationSet.hashes, referencedOperationHashes.sort())) {
    fail("authenticated Android fault operations do not match the matrix");
  }
  const latestFallback = Math.max(...fallbackProofs.map(
    proof => proof.value.completed_unix)) * 1000;
  if (latestFallback > Date.parse(evidence.value.completed_at)) {
    fail("tab fault matrix predates its authenticated fallback proof");
  }
  return {
    receipt_sha256: sha256(Buffer.from(evidence.raw)),
    fallback_evidence_set_sha256: sha256(Buffer.from(
      `${fallbackProofs.map(proof => proof.sha256).sort().join("\n")}\n`)),
    operation_receipt_set_sha256: sha256(Buffer.from(
      `${operationSet.hashes.join("\n")}\n`)),
    first_fallback_at: new Date(Math.min(...fallbackProofs.map(
      proof => proof.value.completed_unix)) * 1000).toISOString(),
    completed_at: evidence.value.completed_at,
  };
}

async function auditProfileBackupReceipt(file, tabs, sourceDevice,
  fingerprintKind) {
  const receipt = await readEnv(file, [
    "schema_version", "source_device", "profile_id", "profile_path_sha256",
    "source_tree_sha256", "source_fingerprint_kind", "archive_root",
    "generation", "archive_sha256", "archive_size", "source_bytes",
    "topology_sha256", "created_at",
  ], "Android test-profile backup receipt");
  const value = name => receipt.values.get(name);
  if (value("schema_version") !== "3" ||
      value("source_device") !== sourceDevice ||
      value("profile_id") !== "default" ||
      !/^[^/.][^/]*$/.test(value("archive_root") || "") ||
      value("source_fingerprint_kind") !== fingerprintKind ||
      value("generation") !== tabs.full_profile_generation ||
      value("archive_sha256") !== tabs.full_profile_archive_sha256 ||
      !/^[1-9][0-9]*$/.test(value("archive_size")) ||
      !/^[1-9][0-9]*$/.test(value("source_bytes")) ||
      !Number.isFinite(Date.parse(value("created_at")))) {
    fail(`${sourceDevice} profile-backup receipt does not match its tab proofs`);
  }
  if (sourceDevice === "oneplus" && value("archive_root") !== "app_chrome") {
    fail("Android test-profile backup receipt has the wrong archive root");
  }
  for (const field of [
    "profile_path_sha256", "source_tree_sha256", "archive_sha256",
    "topology_sha256",
  ]) requireHash(value(field), `profile backup ${field}`);
  return {
    receipt_sha256: sha256(Buffer.from(receipt.raw)),
    created_at: value("created_at"),
  };
}

async function auditServeReceipt(file) {
  const receipt = await readEnv(file, [
    "schema_version", "result", "sync_port", "before_serve_config_sha256",
    "after_serve_config_sha256", "exposure_verifier_sha256", "verified_at",
  ], "Tailnet Serve acceptance receipt");
  const value = name => receipt.values.get(name);
  if (value("schema_version") !== "1" || value("result") !== "passed" ||
      value("sync_port") !== "44719" ||
      value("before_serve_config_sha256") !==
        value("after_serve_config_sha256") ||
      !Number.isFinite(Date.parse(value("verified_at")))) {
    fail("Tailnet Serve acceptance receipt is invalid");
  }
  requireHash(value("before_serve_config_sha256"), "Serve config hash");
  requireHash(value("exposure_verifier_sha256"), "Serve verifier hash");
  const parent = path.dirname(receipt.file);
  const begin = await readEnv(path.join(parent, "begin.env"), [
    "schema_version", "sync_port", "serve_config_sha256",
    "exposure_verifier_sha256", "began_at",
  ], "Tailnet Serve begin receipt");
  if (begin.values.get("schema_version") !== "1" ||
      begin.values.get("sync_port") !== "44719" ||
      begin.values.get("serve_config_sha256") !==
        value("before_serve_config_sha256") ||
      begin.values.get("exposure_verifier_sha256") !==
        value("exposure_verifier_sha256") ||
      !Number.isFinite(Date.parse(begin.values.get("began_at")))) {
    fail("Tailnet Serve begin receipt does not match final verification");
  }
  const before = path.join(parent, "serve-before.json");
  const after = path.join(parent, "serve-after.json");
  if (await sha256File(before) !== value("before_serve_config_sha256") ||
      await sha256File(after) !== value("after_serve_config_sha256") ||
      await fsp.readFile(before, "utf8") !== await fsp.readFile(after, "utf8")) {
    fail("Tailnet Serve configuration changed during full Android acceptance");
  }
  return {
    receipt_sha256: sha256(Buffer.from(receipt.raw)),
    began_at: begin.values.get("began_at"),
    verified_at: value("verified_at"),
  };
}

async function publishExclusive(output, value) {
  const destination = path.resolve(output);
  const parent = path.dirname(destination);
  const parentStat = await fsp.lstat(parent);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink() ||
      (parentStat.mode & 0o077) !== 0 || await fsp.realpath(parent) !== parent ||
      (typeof process.getuid === "function" &&
       parentStat.uid !== process.getuid())) {
    fail("full-E2E receipt parent must be a private owned real directory");
  }
  try {
    await fsp.lstat(destination);
    fail("full-E2E receipt already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = path.join(parent,
    `.helium-sync-fleet-full-e2e.${process.pid}.${crypto.randomUUID()}`);
  const handle = await fsp.open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await fsp.link(temporary, destination);
  } finally {
    await fsp.unlink(temporary).catch(() => {});
  }
  return destination;
}

function parseOptions(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail("options must be --name value pairs");
    }
    if (new Set([
      "--phase-reset-receipt",
      "--tab-evidence", "--tab-status", "--fault-tab-evidence",
      "--fault-operation-receipt",
      "--d-tab-evidence", "--d-tab-status", "--d-fault-tab-evidence",
      "--d-fault-operation-receipt",
      "--da-tab-evidence", "--da-tab-status", "--da-fault-tab-evidence",
      "--da-fault-operation-receipt",
    ]).has(key)) {
      values.set(key, [...(values.get(key) ?? []), value]);
    } else if (values.has(key)) {
      fail(`duplicate option: ${key}`);
    } else {
      values.set(key, value);
    }
  }
  return values;
}

function requireOptions(options) {
  const expected = [
    "--expected-source-commit", "--expected-runtime-kit-commit",
    "--sync-archive", "--sync-acceptance", "--sync-evidence",
    "--control-archive", "--control-acceptance",
    "--control-evidence", "--media-pair-receipt", "--three-client-run",
    "--linux-artifact", "--linux-deployment-receipt",
    "--linux-full-graph-receipt",
    "--d-tab-signing-key", "--d-tab-evidence", "--d-tab-status",
    "--d-tab-fault-evidence", "--d-fault-tab-evidence",
    "--d-fault-operation-receipt", "--d-profile-backup-receipt",
    "--da-tab-signing-key", "--da-tab-evidence", "--da-tab-status",
    "--da-tab-fault-evidence", "--da-fault-tab-evidence",
    "--da-fault-operation-receipt", "--da-profile-backup-receipt",
    "--d-native-recovery-receipt", "--da-native-recovery-receipt",
    "--oneplus-native-recovery-receipt",
    "--phase-reset-receipt", "--tab-signing-key", "--tab-evidence",
    "--tab-status",
    "--tab-fault-evidence", "--fault-tab-evidence",
    "--fault-operation-receipt",
    "--profile-backup-receipt", "--tailnet-serve-receipt", "--output",
  ];
  if (!equal([...options.keys()].sort(), expected.sort())) {
    fail(`expected options: ${expected.sort().join(", ")}`);
  }
}

function usage() {
  return `usage:
  full-e2e.mjs verify --expected-source-commit COMMIT --expected-runtime-kit-commit COMMIT \\
    --linux-artifact FILE --linux-deployment-receipt FILE \\
    --linux-full-graph-receipt FILE \\
    --d-tab-signing-key FILE --d-tab-evidence DIR [five total] \\
    --d-tab-status FILE [three total] --d-tab-fault-evidence FILE \\
    --d-fault-tab-evidence DIR [two total] \\
    --d-fault-operation-receipt DIR [four total] \\
    --d-profile-backup-receipt FILE \\
    --da-tab-signing-key FILE --da-tab-evidence DIR [five total] \\
    --da-tab-status FILE [three total] --da-tab-fault-evidence FILE \\
    --da-fault-tab-evidence DIR [two total] \\
    --da-fault-operation-receipt DIR [four total] \\
    --da-profile-backup-receipt FILE \\
    --d-native-recovery-receipt FILE \\
    --da-native-recovery-receipt FILE \\
    --oneplus-native-recovery-receipt FILE \\
    --sync-archive FILE --sync-acceptance DIR --sync-evidence DIR \\
    --control-archive FILE --control-acceptance DIR --control-evidence DIR \\
    --media-pair-receipt FILE \\
    --three-client-run DIR --phase-reset-receipt FILE [two total] \\
    --tab-signing-key FILE --tab-evidence DIR [five total] \\
    --tab-status FILE [three total] \\
    --tab-fault-evidence FILE --fault-tab-evidence DIR [two total] \\
    --fault-operation-receipt DIR [four total] \\
    --profile-backup-receipt FILE \\
    --tailnet-serve-receipt FILE --output NEW-JSON
`;
}

export async function verifyFullE2E(options) {
  requireOptions(options);
  const sourceCommit = requireCommit(options.get("--expected-source-commit"),
    "expected source commit");
  const runtimeKitCommit = requireCommit(
    options.get("--expected-runtime-kit-commit"),
    "expected runtime-kit commit");
  const sync = await auditPreparedAcceptance(
    options.get("--sync-acceptance"), options.get("--sync-archive"),
    TEST_PACKAGE, sourceCommit);
  const control = await auditPreparedAcceptance(
    options.get("--control-acceptance"), options.get("--control-archive"),
    CONTROL_PACKAGE, sourceCommit);
  for (const field of [
    "chromium_commit", "version_code", "version_name",
    "runtime_kit_commit", "runtime_kit_source_sha256", "tooling_commit",
  ]) {
    if (sync[field] !== control[field]) {
      fail(`Sync/control acceptance disagrees on ${field}`);
    }
  }
  if (sync.runtime_kit_commit !== runtimeKitCommit) {
    fail("prepared artifacts do not use the expected runtime kit");
  }
  const media = await auditMediaPair({
    syncEvidence: options.get("--sync-evidence"),
    controlEvidence: options.get("--control-evidence"),
    mediaPairReceipt: options.get("--media-pair-receipt"),
  }, sync, control);
  const threeClient = await auditThreeClient(
    options.get("--three-client-run"), sync, sourceCommit, {
      artifact: options.get("--linux-artifact"),
      deploymentReceipt: options.get("--linux-deployment-receipt"),
      fullGraphReceipt: options.get("--linux-full-graph-receipt"),
    });
  const desktopTabs = {};
  const desktopFaults = {};
  const desktopProfiles = {};
  for (const device of ["d", "da"]) {
    desktopTabs[device] = await auditDesktopTabEvidence(
      options.get(`--${device}-tab-evidence`),
      options.get(`--${device}-tab-status`),
      options.get(`--${device}-tab-signing-key`),
      device,
      threeClient.linux[device],
    );
    desktopFaults[device] = await auditDesktopTabFaultEvidence(
      options.get(`--${device}-tab-fault-evidence`),
      options.get(`--${device}-fault-tab-evidence`),
      options.get(`--${device}-fault-operation-receipt`),
      options.get(`--${device}-tab-signing-key`),
      device,
      threeClient.linux[device],
      desktopTabs[device],
    );
    desktopProfiles[device] = await auditProfileBackupReceipt(
      options.get(`--${device}-profile-backup-receipt`),
      desktopTabs[device],
      device,
      "normalized-tree-v1",
    );
  }
  const phaseResets = await auditPhaseResets(
    options.get("--phase-reset-receipt"), sync);
  const tabs = await auditTabEvidence(
    options.get("--tab-evidence"), options.get("--tab-status"),
    options.get("--tab-signing-key"), sync, phaseResets.adb_serial);
  const tabFaults = await auditTabFaultEvidence(
    options.get("--tab-fault-evidence"),
    options.get("--fault-tab-evidence"),
    options.get("--fault-operation-receipt"),
    options.get("--tab-signing-key"), sync, phaseResets.adb_serial, tabs);
  const profileBackup = await auditProfileBackupReceipt(
    options.get("--profile-backup-receipt"), tabs, "oneplus", "tar-stream-v1");
  const nativeRecovery = {};
  for (const device of ["d", "da", "oneplus"]) {
    nativeRecovery[device] = await auditNativeRecoveryDevice(
      options.get(`--${device}-native-recovery-receipt`), device);
    const expectedArtifact = device === "oneplus"
      ? sync.apk_sha256 : threeClient.linux[device].browser_sha256;
    if (nativeRecovery[device].artifact_sha256 !== expectedArtifact) {
      fail(`${device} native password/cookie recovery used the wrong browser artifact`);
    }
  }
  for (const field of ["passwords_state_sha256", "cookies_state_sha256"]) {
    if (new Set(["d", "da", "oneplus"].map(
      device => nativeRecovery[device][field])).size !== 1) {
      fail(`native recovery ${field} does not converge across the fleet`);
    }
  }
  if (desktopTabs.d.execution_identity.host_identity_sha256 !==
        threeClient.execution_identity.d.host_identity_sha256 ||
      desktopTabs.da.execution_identity.host_identity_sha256 !==
        threeClient.execution_identity.da.host_identity_sha256) {
    fail("desktop tab phases did not execute on their admitted d and da hosts");
  }
  const oneplusIdentity = media.physical_identity.physical_identity_sha256;
  if (phaseResets.physical_identity.physical_identity_sha256 !== oneplusIdentity ||
      tabs.execution_identity.physical_identity_sha256 !== oneplusIdentity ||
      threeClient.execution_identity.oneplus.physical_identity_sha256 !==
        oneplusIdentity) {
    fail("media, password, reset, and tab phases did not use one physical OnePlus");
  }
  const serve = await auditServeReceipt(options.get("--tailnet-serve-receipt"));
  const chronology = [
    [serve.began_at, media.verified_at, "Serve begin must precede media A/B"],
    [media.verified_at, phaseResets.media_to_sync.cleared_at,
      "media A/B must precede its phase reset"],
    [phaseResets.media_to_sync.cleared_at, threeClient.verified_at,
      "first reset must precede three-client Sync"],
    [threeClient.verified_at, phaseResets.sync_to_tabs.cleared_at,
      "three-client Sync must precede its phase reset"],
    [threeClient.verified_at, desktopTabs.d.first_completed_at,
      "three-client Sync must precede d tab recovery"],
    [threeClient.verified_at, desktopTabs.da.first_completed_at,
      "three-client Sync must precede da tab recovery"],
    [desktopTabs.d.native_completed_at, desktopProfiles.d.created_at,
      "d native tab proof must precede its profile backup"],
    [desktopProfiles.d.created_at, desktopTabs.d.first_full_profile_completed_at,
      "d profile backup must precede full-profile restore proofs"],
    [desktopTabs.da.native_completed_at, desktopProfiles.da.created_at,
      "da native tab proof must precede its profile backup"],
    [desktopProfiles.da.created_at, desktopTabs.da.first_full_profile_completed_at,
      "da profile backup must precede full-profile restore proofs"],
    [desktopTabs.d.last_completed_at, desktopFaults.d.first_fallback_at,
      "d normal tab proofs must precede fault recovery"],
    [desktopTabs.da.last_completed_at, desktopFaults.da.first_fallback_at,
      "da normal tab proofs must precede fault recovery"],
    [phaseResets.sync_to_tabs.cleared_at, tabs.first_completed_at,
      "second reset must precede Android tab proofs"],
    [tabs.native_completed_at, profileBackup.created_at,
      "native tab proof must precede its profile backup"],
    [profileBackup.created_at, tabs.first_full_profile_completed_at,
      "profile backup must precede full-profile restore proofs"],
    [tabs.last_completed_at, tabFaults.first_fallback_at,
      "normal tab proofs must precede fault recovery"],
    [tabFaults.completed_at, serve.verified_at,
      "fault recovery must precede final Serve verification"],
    [desktopFaults.d.completed_at, serve.verified_at,
      "d fault recovery must precede final Serve verification"],
    [desktopFaults.da.completed_at, serve.verified_at,
      "da fault recovery must precede final Serve verification"],
    [threeClient.verified_at, nativeRecovery.d.verified_at,
      "three-client Sync must precede d native password/cookie recovery"],
    [threeClient.verified_at, nativeRecovery.da.verified_at,
      "three-client Sync must precede da native password/cookie recovery"],
    [threeClient.verified_at, nativeRecovery.oneplus.verified_at,
      "three-client Sync must precede OnePlus native password/cookie recovery"],
    [nativeRecovery.d.verified_at, serve.verified_at,
      "d native password/cookie recovery must precede final Serve verification"],
    [nativeRecovery.da.verified_at, serve.verified_at,
      "da native password/cookie recovery must precede final Serve verification"],
    [nativeRecovery.oneplus.verified_at, serve.verified_at,
      "OnePlus native password/cookie recovery must precede final Serve verification"],
  ];
  for (const [before, after, message] of chronology) {
    if (Date.parse(before) > Date.parse(after)) fail(message);
  }
  const verifier = fileURLToPath(import.meta.url);
  const receipt = {
    schema_version: 4,
    evidence_type: "helium-sync-fleet-full-e2e-v4",
    result: "passed",
    source_train: {
      helium_sync_commit: sourceCommit,
      helium_passwords_commit:
        threeClient.returned_artifact.helium_passwords_commit,
      helium_core_commit: sync.helium_core_commit,
      chromium_commit: sync.chromium_commit,
      chromium_version: sync.version_name,
    },
    android_artifacts: {
      sync: {
        archive_sha256: sync.source_archive_sha256,
        archive_size: sync.source_archive_size,
        apk_sha256: sync.apk_sha256,
        acceptance_inventory_sha256: sync.inventory_sha256,
      },
      control: {
        archive_sha256: control.source_archive_sha256,
        archive_size: control.source_archive_size,
        apk_sha256: control.apk_sha256,
        acceptance_inventory_sha256: control.inventory_sha256,
      },
      version_code: sync.version_code,
      runtime_kit_commit: sync.runtime_kit_commit,
      runtime_kit_source_sha256: sync.runtime_kit_source_sha256,
      build_tooling_commit: sync.tooling_commit,
    },
    linux_artifact: threeClient.returned_artifact,
    linux_device_runtime: threeClient.linux,
    fleet_execution_identity: {
      d: threeClient.execution_identity.d.host_identity_sha256,
      da: threeClient.execution_identity.da.host_identity_sha256,
      oneplus: oneplusIdentity,
    },
    receipts: {
      media_pair: media.receipt_sha256,
      fixture: media.fixture_receipt_sha256,
      three_client_password_sync: threeClient.receipt_sha256,
      package_phase_resets: [
        phaseResets.media_to_sync.receipt_sha256,
        phaseResets.sync_to_tabs.receipt_sha256,
      ],
      tab_runtime_set: tabs.evidence_set_sha256,
      tab_status_set: tabs.status_set_sha256,
      tab_fault_matrix: tabFaults.receipt_sha256,
      tab_fault_fallback_set: tabFaults.fallback_evidence_set_sha256,
      tab_fault_operation_set: tabFaults.operation_receipt_set_sha256,
      test_profile_backup: profileBackup.receipt_sha256,
      desktop_tabs: Object.fromEntries(["d", "da"].map(device => [device, {
        runtime_set: desktopTabs[device].evidence_set_sha256,
        status_set: desktopTabs[device].status_set_sha256,
        fault_matrix: desktopFaults[device].receipt_sha256,
        fault_fallback_set: desktopFaults[device].fallback_evidence_set_sha256,
        fault_operation_set: desktopFaults[device].operation_receipt_set_sha256,
        profile_backup: desktopProfiles[device].receipt_sha256,
      }])),
      browser_native_neutral_recovery: Object.fromEntries(
        ["d", "da", "oneplus"].map(device => [device, {
          receipt: nativeRecovery[device].receipt_sha256,
          generation: nativeRecovery[device].generation,
          archive_sha256: nativeRecovery[device].archive_sha256,
          artifact_sha256: nativeRecovery[device].artifact_sha256,
          passwords_state_sha256:
            nativeRecovery[device].passwords_state_sha256,
          cookies_state_sha256: nativeRecovery[device].cookies_state_sha256,
        }])),
      tailnet_serve: serve.receipt_sha256,
    },
    requirements: {
      native_password_lifecycle: "passed",
      three_client_password_cookie_convergence: "passed",
      d_browser_native_password_cookie_restore_from_two_destinations: "passed",
      da_browser_native_password_cookie_restore_from_two_destinations: "passed",
      oneplus_browser_native_password_cookie_restore_from_two_destinations:
        "passed",
      browser_native_password_cookie_state_converged_across_fleet: "passed",
      media_streaming_matched_control: "passed",
      background_foreground_and_wifi_cellular_handoff: "passed",
      d_native_clean_crash_second_restart: "passed",
      d_neutral_restore_from_two_destinations: "passed",
      d_full_profile_restore_from_two_destinations: "passed",
      d_damaged_generation_recovery: "passed",
      da_native_clean_crash_second_restart: "passed",
      da_neutral_restore_from_two_destinations: "passed",
      da_full_profile_restore_from_two_destinations: "passed",
      da_damaged_generation_recovery: "passed",
      oneplus_native_clean_crash_second_restart: "passed",
      oneplus_neutral_restore_from_two_destinations: "passed",
      oneplus_full_profile_restore_from_two_destinations: "passed",
      oneplus_damaged_generation_recovery: "passed",
      production_package_and_personal_profile_untouched: "passed",
    },
    verifier_sha256: await sha256File(verifier),
    verified_at: new Date().toISOString(),
  };
  const output = await publishExclusive(options.get("--output"), receipt);
  return {output, receipt, receipt_sha256: await sha256File(output)};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, ...args] = process.argv.slice(2);
    if (command !== "verify") fail(usage());
    const result = await verifyFullE2E(parseOptions(args));
    process.stdout.write(`${JSON.stringify({
      event: "passed",
      receipt: result.output,
      receipt_sha256: result.receipt_sha256,
    })}\n`);
  } catch (error) {
    process.stderr.write(`Fleet full E2E: ${error.message}\n`);
    process.exitCode = 1;
  }
}
