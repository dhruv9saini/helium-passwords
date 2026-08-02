#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

import {
  auditArtifactAdmission,
  DISPOSABLE_PROFILE_MARKER,
  initializeRun,
} from "../password-runtime/acceptance.mjs";
import {auditVerifiedSyncRun} from "../password-runtime/sync-acceptance.mjs";
import {auditOriginState} from "../session-state/origin-state-audit.mjs";
import {auditLinuxFullGraphEvidence} from "../linux-full-graph-audit.mjs";
import {parsePhysicalDeviceIdentityEnv} from
  "../android-acceptance/physical-device-identity.mjs";
import {parseLinuxHostIdentityEnv} from "./execution-identity.mjs";
import {
  auditDeviceRuntimeEvidence,
  auditServerRuntimeEvidence,
} from "./fleet-runtime-evidence.mjs";

const SCHEMA_VERSION = 2;
const ROOT_MARKER = "helium-three-client-disposable-v1\n";
const DEVICE_MARKER_PREFIX = "helium-three-client-device-v1:";
const DEVICES = Object.freeze(["d", "da", "oneplus"]);
const JOINERS = Object.freeze(["da", "oneplus"]);
const DEVICE_SPECS = Object.freeze({
  d: Object.freeze({
    platform: "linux",
    target: "linux-x86_64",
    arch: "x86_64",
    packageName: "",
  }),
  da: Object.freeze({
    platform: "linux",
    target: "linux-x86_64",
    arch: "x86_64",
    packageName: "",
  }),
  oneplus: Object.freeze({
    platform: "android",
    target: "android-arm64",
    arch: "arm64",
    packageName: "computer.helium.sync.test",
  }),
});
const HASH = /^[0-9a-f]{64}$/;
const CREDENTIAL_KEY = /^credential\/v2\/[0-9a-f]{64}$/;
const COOKIE_KEY = /^[0-9a-f]{64}$/;
const EVIDENCE_REF = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const INT64_MAX = 9223372036854775807n;
const LINUX_DEPOT_TOOLS_COMMIT =
  "980d6af16e06ff993a52029019dc0628c0a0e1f0";
const ORIGIN_STATE_KINDS = Object.freeze([
  "cache-storage",
  "indexed-db",
  "local-storage",
  "other-origin-state",
  "service-worker",
]);

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

function equalJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  if (!equalJSON(Object.keys(value).sort(), [...expected].sort())) {
    throw new Error(`${label} has an unexpected field inventory`);
  }
}

function requireHash(value, label) {
  if (typeof value !== "string" || !HASH.test(value)) {
    throw new Error(`${label} must be a SHA-256 value`);
  }
  return value;
}

function int64String(value, label) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${label} must be a non-negative int64 string`);
  }
  const parsed = BigInt(value);
  if (parsed > INT64_MAX) throw new Error(`${label} exceeds int64`);
  return parsed;
}

function positiveInt64(value, label) {
  const parsed = int64String(value, label);
  if (parsed === 0n) throw new Error(`${label} must be positive`);
  return parsed;
}

function requireTailnetHTTP(value, label) {
  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new Error(`${label} must be an exact URL`);
  }
  const octets = endpoint.hostname.split(".").map(Number);
  const tailnetIPv4 = octets.length === 4 &&
    octets.every((octet, index) => Number.isInteger(octet) &&
      octet >= 0 && octet <= 255 && String(octet) ===
        endpoint.hostname.split(".")[index]) &&
    octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
  if (endpoint.protocol !== "http:" || !tailnetIPv4 ||
      endpoint.port !== "44719" || endpoint.pathname !== "/" ||
      endpoint.username || endpoint.password || endpoint.search ||
      endpoint.hash) {
    throw new Error(`${label} must be literal private-Tailnet HTTP port 44719`);
  }
  return endpoint.href;
}

async function regularFile(filePath, label, maximum = 4 * 1024 * 1024) {
  const resolved = path.resolve(filePath);
  const info = await fsp.lstat(resolved);
  if (!info.isFile() || info.isSymbolicLink() ||
      info.size <= 0 || info.size > maximum) {
    throw new Error(`${label} must be a nonempty regular file within its size limit`);
  }
  return {resolved, info};
}

async function readJSON(filePath, label) {
  const file = await regularFile(filePath, label);
  const raw = await fsp.readFile(file.resolved, "utf8");
  return {file, raw, value: JSON.parse(raw)};
}

async function writeJSONExclusive(filePath, value) {
  await fsp.writeFile(
    filePath,
    `${JSON.stringify(value, null, 2)}\n`,
    {mode: 0o600, flag: "wx"},
  );
}

async function requireDisposableProfile(profilePath, expectedPath, device) {
  const resolved = path.resolve(profilePath);
  if (resolved !== expectedPath) throw new Error("disposable profile path changed");
  const info = await fsp.lstat(resolved);
  if (!info.isDirectory() || info.isSymbolicLink() ||
      (info.mode & 0o077) !== 0) {
    throw new Error(`disposable profile is not a private real directory: ${resolved}`);
  }
  const markerPath = path.join(resolved, "SYNTHETIC_ONLY");
  const marker = await regularFile(markerPath, "disposable profile marker", 128);
  if ((marker.info.mode & 0o077) !== 0 ||
      await fsp.readFile(marker.resolved, "utf8") !== DISPOSABLE_PROFILE_MARKER) {
    throw new Error(`disposable profile marker is invalid: ${resolved}`);
  }
  const identityPath = path.join(resolved, "HELIUM_SYNC_DEVICE");
  const identity = await regularFile(
    identityPath, "disposable device marker", 128);
  const expectedIdentity = `${DEVICE_MARKER_PREFIX}${device}\n`;
  if ((identity.info.mode & 0o077) !== 0 ||
      await fsp.readFile(identity.resolved, "utf8") !== expectedIdentity) {
    throw new Error(`disposable device marker is invalid: ${resolved}`);
  }
  return sha256(Buffer.concat([
    await fsp.readFile(marker.resolved),
    Buffer.from(expectedIdentity),
  ]));
}

function nativeRunPath(root, device) {
  return path.join(root, `native-${device}`);
}

function exactCommit(value, label) {
  if (typeof value !== "string" || !/^[0-9a-f]{40}$/.test(value)) {
    throw new Error(`${label} must be a full commit`);
  }
  return value;
}

async function readEnv(filePath, label) {
  const file = await regularFile(filePath, label);
  const raw = await fsp.readFile(file.resolved, "utf8");
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    if (separator < 1 || values.has(line.slice(0, separator))) {
      throw new Error(`${label} is malformed`);
    }
    values.set(line.slice(0, separator), line.slice(separator + 1));
  }
  return {file, raw, values};
}

function requireEnvKeys(env, expected, label) {
  if (!equalJSON([...env.values.keys()].sort(), [...expected].sort())) {
    throw new Error(`${label} has an unexpected field inventory`);
  }
}

async function readCommitFile(filePath, label) {
  const file = await regularFile(filePath, label, 128);
  return {
    file,
    value: exactCommit(
      (await fsp.readFile(file.resolved, "utf8")).trim(),
      label,
    ),
  };
}

async function readExecutionIdentity(filePath, device) {
  const file = await regularFile(filePath, `${device} execution identity`, 4096);
  if ((file.info.mode & 0o077) !== 0) {
    throw new Error(`${device} execution identity must be private`);
  }
  const raw = await fsp.readFile(file.resolved, "utf8");
  const value = device === "oneplus"
    ? parsePhysicalDeviceIdentityEnv(raw)
    : parseLinuxHostIdentityEnv(raw, device);
  return {path: file.resolved, sha256: sha256(raw), value};
}

async function describeAdmittedDevice(run, device, executionIdentity) {
  const spec = DEVICE_SPECS[device];
  let admission;
  let train;
  if (spec.platform === "linux") {
    const receipt = await readEnv(
      run.artifact_receipt, `${device} Linux artifact receipt`);
    requireEnvKeys(receipt, [
      "schema_version", "product", "platform", "arch", "source_commit",
      "helium_core_commit", "chromium_version", "chromium_commit",
      "platform_commit", "bundle", "bundle_sha256",
      "provenance_manifest_sha256", "browser_executable", "browser_sha256",
      "runtime_inventory", "runtime_inventory_sha256", "full_graph_receipt",
      "full_graph_receipt_sha256", "full_graph_inventory",
      "full_graph_inventory_sha256", "verified_at",
    ], `${device} Linux artifact receipt`);
    if (receipt.values.get("arch") !== spec.arch) {
      throw new Error(`${device} Linux artifact has the wrong architecture`);
    }
    const verifiedRoot = path.dirname(receipt.file.resolved);
    const deployment = await readEnv(
      path.join(verifiedRoot, "deployment-artifact-receipt.env"),
      `${device} deployment artifact receipt`,
    );
    if ((deployment.file.info.mode & 0o077) !== 0) {
      throw new Error(
        `${device} deployment artifact receipt must be private`,
      );
    }
    requireEnvKeys(deployment, [
      "schema_version", "artifact_sha256", "artifact_size", "target",
      "helium_sync_commit", "helium_passwords_commit",
      "helium_core_commit", "chromium_commit", "build_job_id",
      "provenance_sha256", "full_graph_receipt_sha256",
      "full_graph_inventory_sha256", "created_at",
    ], `${device} deployment artifact receipt`);
    const manifest = await readEnv(
      path.join(
        verifiedRoot,
        `helium-sync-linux-${spec.arch}`,
        "provenance",
        "manifest.env",
      ),
      `${device} internal provenance manifest`,
    );
    requireEnvKeys(manifest, [
      "schema_version", "product", "platform", "arch", "target",
      "source_commit", "source_tree", "helium_passwords_commit",
      "helium_sync_commit", "helium_core_commit", "chromium_version",
      "chromium_commit", "build_job_id", "platform_repository",
      "platform_commit", "depot_tools_commit", "gn_args_sha256",
      "nix_provenance_sha256", "patch_inventory_sha256",
      "runtime_inventory_sha256", "packaging_tool_commit",
      "packaging_tool_sha256", "full_graph_receipt_sha256",
      "full_graph_inventory_sha256",
    ], `${device} internal provenance manifest`);
    const sourceCommit = exactCommit(
      receipt.values.get("source_commit"), `${device} source commit`);
    const passwordsCommit = exactCommit(
      deployment.values.get("helium_passwords_commit"),
      `${device} Passwords commit`,
    );
    const coreCommit = exactCommit(
      receipt.values.get("helium_core_commit"), `${device} core commit`);
    const chromiumCommit = exactCommit(
      receipt.values.get("chromium_commit"), `${device} Chromium commit`);
    const platformCommit = exactCommit(
      receipt.values.get("platform_commit"), `${device} platform commit`);
    const depotToolsCommit = exactCommit(
      manifest.values.get("depot_tools_commit"),
      `${device} depot_tools commit`,
    );
    const bundle = await regularFile(
      receipt.values.get("bundle"), `${device} returned Linux archive`,
      16 * 1024 * 1024 * 1024,
    );
    const bundleSHA256 = await sha256File(bundle.resolved);
    const manifestSHA256 = sha256(manifest.raw);
    const graphRoot = path.join(
      verifiedRoot, `helium-sync-linux-${spec.arch}`, "provenance", "full-graph");
    const graph = await auditLinuxFullGraphEvidence(graphRoot, {
      job: deployment.values.get("build_job_id"),
      sourceCommit,
      passwordsCommit,
      coreCommit,
      chromiumCommit,
      platformCommit,
    });
    if (receipt.values.get("schema_version") !== "3" ||
        receipt.values.get("product") !== "helium-sync" ||
        receipt.values.get("platform") !== "linux" ||
        receipt.values.get("full_graph_receipt") !==
          `helium-sync-linux-${spec.arch}/provenance/full-graph/receipt.env` ||
        receipt.values.get("full_graph_inventory") !==
          `helium-sync-linux-${spec.arch}/provenance/full-graph/SHA256SUMS` ||
        receipt.values.get("full_graph_receipt_sha256") !== graph.receiptSha256 ||
        receipt.values.get("full_graph_inventory_sha256") !==
          graph.inventorySha256 ||
        deployment.values.get("schema_version") !== "2" ||
        deployment.values.get("target") !== spec.target ||
        deployment.values.get("artifact_sha256") !== bundleSHA256 ||
        deployment.values.get("artifact_sha256") !==
          receipt.values.get("bundle_sha256") ||
        deployment.values.get("artifact_size") !== String(bundle.info.size) ||
        deployment.values.get("provenance_sha256") !== manifestSHA256 ||
        deployment.values.get("provenance_sha256") !==
          receipt.values.get("provenance_manifest_sha256") ||
        deployment.values.get("full_graph_receipt_sha256") !==
          graph.receiptSha256 ||
        deployment.values.get("full_graph_inventory_sha256") !==
          graph.inventorySha256 ||
        deployment.values.get("helium_sync_commit") !== sourceCommit ||
        deployment.values.get("helium_core_commit") !== coreCommit ||
        deployment.values.get("chromium_commit") !== chromiumCommit ||
        deployment.values.get("build_job_id") !==
          manifest.values.get("build_job_id") ||
        !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(
          deployment.values.get("build_job_id") || "") ||
        !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/.test(
          deployment.values.get("created_at") || "") ||
        manifest.values.get("schema_version") !== "4" ||
        manifest.values.get("product") !== "helium-sync" ||
        manifest.values.get("platform") !== "linux" ||
        manifest.values.get("arch") !== spec.arch ||
        manifest.values.get("target") !== spec.target ||
        manifest.values.get("source_commit") !== sourceCommit ||
        manifest.values.get("helium_sync_commit") !== sourceCommit ||
        manifest.values.get("helium_passwords_commit") !== passwordsCommit ||
        manifest.values.get("helium_core_commit") !== coreCommit ||
        manifest.values.get("chromium_commit") !== chromiumCommit ||
        manifest.values.get("chromium_version") !==
          receipt.values.get("chromium_version") ||
        manifest.values.get("platform_commit") !== platformCommit ||
        manifest.values.get("full_graph_receipt_sha256") !==
          graph.receiptSha256 ||
        manifest.values.get("full_graph_inventory_sha256") !==
          graph.inventorySha256 ||
        manifest.values.get("packaging_tool_sha256") !==
          graph.receipt.packaging_tool_sha256 ||
        !/^[0-9a-f]{40}$/.test(
          manifest.values.get("packaging_tool_commit") || "") ||
        depotToolsCommit !== LINUX_DEPOT_TOOLS_COMMIT ||
        !HASH.test(manifest.values.get("source_tree") || "") ||
        !["gn_args_sha256", "nix_provenance_sha256",
          "patch_inventory_sha256", "runtime_inventory_sha256"].every(
          field => HASH.test(manifest.values.get(field) || "")) ||
        !/^https:\/\/[^ \t\r\n]+$/.test(
          manifest.values.get("platform_repository") || "")) {
      throw new Error(`${device} deployment receipt or provenance is inconsistent`);
    }
    admission = {
      kind: "linux-runtime-receipt",
      receipt_path: receipt.file.resolved,
      receipt_sha256: sha256(receipt.raw),
      deployment_receipt_path: deployment.file.resolved,
      deployment_receipt_sha256: sha256(deployment.raw),
      provenance_manifest_path: manifest.file.resolved,
      provenance_manifest_sha256: manifestSHA256,
      returned_archive_path: bundle.resolved,
      returned_archive_sha256: bundleSHA256,
      build_job_id: manifest.values.get("build_job_id"),
      depot_tools_commit: depotToolsCommit,
      full_graph_root_path: graph.root,
      full_graph_receipt_path: path.join(graph.root, "receipt.env"),
      full_graph_receipt_sha256: graph.receiptSha256,
      full_graph_inventory_path: path.join(graph.root, "SHA256SUMS"),
      full_graph_inventory_sha256: graph.inventorySha256,
      inventory_path: null,
      inventory_sha256: null,
    };
    train = {
      source_commit: sourceCommit,
      passwords_commit: passwordsCommit,
      core_commit: coreCommit,
      chromium_commit: chromiumCommit,
      chromium_version: receipt.values.get("chromium_version"),
    };
  } else {
    const prepared = path.dirname(run.artifact_path);
    const metadata = await readEnv(
      path.join(prepared, "acceptance.env"),
      "OnePlus Android acceptance metadata",
    );
    const inventory = await regularFile(
      path.join(prepared, "PACKAGE_SHA256SUMS"),
      "OnePlus Android acceptance inventory",
    );
    const inventoryRaw = await fsp.readFile(inventory.resolved, "utf8");
    const runtimeKit = await readEnv(
      path.join(prepared, "runtime-acceptance", "kit.env"),
      "OnePlus Android runtime kit",
    );
    const source = await readCommitFile(
      path.join(prepared, "build-provenance", "helium-sync-commit.txt"),
      "OnePlus source commit",
    );
    const core = await readCommitFile(
      path.join(prepared, "build-provenance", "helium-core-commit.txt"),
      "OnePlus core commit",
    );
    const chromium = await readCommitFile(
      path.join(prepared, "build-provenance", "chromium-source-commit.txt"),
      "OnePlus Chromium commit",
    );
    if (metadata.values.get("helium_sync_commit") !== source.value ||
        metadata.values.get("chromium_commit") !== chromium.value ||
        runtimeKit.values.get("helium_sync_commit") !== source.value ||
        runtimeKit.values.get("chromium_commit") !== chromium.value ||
        runtimeKit.values.get("manifest_package") !== spec.packageName ||
        runtimeKit.values.get("target_cpu") !== spec.arch) {
      throw new Error("OnePlus prepared admission disagrees with its provenance");
    }
    admission = {
      kind: "prepared-android-inventory",
      receipt_path: metadata.file.resolved,
      receipt_sha256: sha256(metadata.raw),
      deployment_receipt_path: null,
      deployment_receipt_sha256: null,
      provenance_manifest_path: null,
      provenance_manifest_sha256: null,
      returned_archive_path: null,
      returned_archive_sha256: null,
      build_job_id: null,
      depot_tools_commit: null,
      full_graph_root_path: null,
      full_graph_receipt_path: null,
      full_graph_receipt_sha256: null,
      full_graph_inventory_path: null,
      full_graph_inventory_sha256: null,
      inventory_path: inventory.resolved,
      inventory_sha256: sha256(inventoryRaw),
    };
    train = {
      source_commit: source.value,
      passwords_commit: null,
      core_commit: core.value,
      chromium_commit: chromium.value,
      chromium_version: metadata.values.get("version_name"),
    };
  }
  if (!/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(
    train.chromium_version || "")) {
    throw new Error(`${device} Chromium version is invalid`);
  }

  let profileMarkerSHA256 = null;
  if (spec.platform === "linux") {
    profileMarkerSHA256 = await requireDisposableProfile(
      run.profile_path,
      path.join(nativeRunPath(path.dirname(run.run_root), device), "profile"),
      device,
    );
  } else if (run.profile_path !== null) {
    throw new Error("OnePlus Android admission unexpectedly has a filesystem profile");
  }
  return {
    descriptor: {
      native_run: run.run_root,
      platform: spec.platform,
      target: spec.target,
      package: spec.packageName,
      artifact_path: run.artifact_path,
      artifact_sha256: run.artifact_sha256,
      admission,
      profile_path: run.profile_path,
      profile_marker_sha256: profileMarkerSHA256,
      execution_identity: executionIdentity,
    },
    train,
  };
}

function requireOneTrain(trains) {
  const expected = trains.d;
  exactKeys(expected, [
    "source_commit", "passwords_commit", "core_commit", "chromium_commit",
    "chromium_version",
  ], "source train");
  exactCommit(expected.passwords_commit, "shared Passwords commit");
  for (const device of DEVICES) {
    const actual = trains[device];
    exactKeys(actual, Object.keys(expected), `${device} source train`);
    if (actual.source_commit !== expected.source_commit ||
        actual.core_commit !== expected.core_commit ||
        actual.chromium_commit !== expected.chromium_commit ||
        actual.chromium_version !== expected.chromium_version ||
        (actual.passwords_commit !== null &&
          actual.passwords_commit !== expected.passwords_commit)) {
      throw new Error(`${device} artifact is not on the shared source train`);
    }
  }
  return expected;
}

function requireOneLinuxRuntime(devices) {
  const fields = [
    "artifact_sha256", "returned_archive_sha256",
    "deployment_receipt_sha256", "provenance_manifest_sha256",
    "full_graph_receipt_sha256", "full_graph_inventory_sha256",
    "build_job_id", "depot_tools_commit",
  ];
  for (const field of fields) {
    const dValue = field === "artifact_sha256"
      ? devices.d.artifact_sha256
      : devices.d.admission[field];
    const daValue = field === "artifact_sha256"
      ? devices.da.artifact_sha256
      : devices.da.admission[field];
    if (dValue !== daValue) {
      throw new Error(`d and da do not use one exact returned Linux runtime: ${field}`);
    }
  }
}

export async function initializeThreeClientRun({
  dArtifact,
  dArtifactReceipt,
  daArtifact,
  daArtifactReceipt,
  oneplusArtifact,
  dExecutionIdentity,
  daExecutionIdentity,
  oneplusExecutionIdentity,
  output,
}) {
  const root = path.resolve(output);
  try {
    await fsp.lstat(root);
    throw new Error("three-client acceptance output already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const inputs = {
    d: {artifact: dArtifact, artifactReceipt: dArtifactReceipt},
    da: {artifact: daArtifact, artifactReceipt: daArtifactReceipt},
    oneplus: {artifact: oneplusArtifact, artifactReceipt: ""},
  };
  const executionIdentities = {
    d: await readExecutionIdentity(dExecutionIdentity, "d"),
    da: await readExecutionIdentity(daExecutionIdentity, "da"),
    oneplus: await readExecutionIdentity(oneplusExecutionIdentity, "oneplus"),
  };
  if (executionIdentities.d.value.machine_id_sha256 ===
      executionIdentities.da.value.machine_id_sha256) {
    throw new Error("d and da execution identities resolve to one Linux machine");
  }
  const nativeRuns = {};
  for (const device of DEVICES) {
    const spec = DEVICE_SPECS[device];
    nativeRuns[device] = await initializeRun({
      artifact: inputs[device].artifact,
      artifactReceipt: inputs[device].artifactReceipt,
      output: nativeRunPath(root, device),
      platform: spec.platform,
      packageName: spec.packageName,
    });
  }
  await fsp.chmod(root, 0o700);
  for (const device of ["d", "da"]) {
    await fsp.writeFile(
      path.join(nativeRuns[device].profile_path, "HELIUM_SYNC_DEVICE"),
      `${DEVICE_MARKER_PREFIX}${device}\n`,
      {mode: 0o600, flag: "wx"},
    );
  }
  await fsp.writeFile(
    path.join(root, "SYNTHETIC_ONLY"),
    ROOT_MARKER,
    {mode: 0o600, flag: "wx"},
  );

  const devices = {};
  const trains = {};
  for (const device of DEVICES) {
    const admitted = await describeAdmittedDevice(
      nativeRuns[device], device, executionIdentities[device].value);
    devices[device] = admitted.descriptor;
    trains[device] = admitted.train;
  }
  requireOneLinuxRuntime(devices);
  const manifest = {
    schema_version: SCHEMA_VERSION,
    root,
    created_at: new Date().toISOString(),
    devices,
    source_train: requireOneTrain(trains),
    expected_enrollment_order: DEVICES,
    tabs_policy: "excluded",
  };
  await writeJSONExclusive(path.join(root, "run.json"), manifest);
  return manifest;
}

async function loadManifest(runRoot) {
  const root = path.resolve(runRoot);
  const marker = await regularFile(
    path.join(root, "SYNTHETIC_ONLY"),
    "three-client synthetic-only marker",
    128,
  );
  if ((marker.info.mode & 0o077) !== 0 ||
      await fsp.readFile(marker.resolved, "utf8") !== ROOT_MARKER) {
    throw new Error("three-client synthetic-only marker is missing or invalid");
  }
  const manifestFile = await readJSON(path.join(root, "run.json"), "three-client run");
  const manifest = manifestFile.value;
  exactKeys(manifest, [
    "schema_version", "root", "created_at", "devices", "source_train",
    "expected_enrollment_order", "tabs_policy",
  ], "three-client run");
  exactKeys(manifest.devices, DEVICES, "three-client devices");
  if (manifest.schema_version !== SCHEMA_VERSION || manifest.root !== root ||
      !Number.isFinite(Date.parse(manifest.created_at)) ||
      !equalJSON(manifest.expected_enrollment_order, DEVICES) ||
      manifest.tabs_policy !== "excluded") {
    throw new Error("three-client run metadata is invalid");
  }
  exactKeys(manifest.source_train, [
    "source_commit", "passwords_commit", "core_commit", "chromium_commit",
    "chromium_version",
  ], "shared source train");
  const trains = {};
  for (const device of DEVICES) {
    const spec = DEVICE_SPECS[device];
    const recorded = manifest.devices[device];
    exactKeys(recorded, [
      "native_run", "platform", "target", "package", "artifact_path",
      "artifact_sha256", "admission", "profile_path",
      "profile_marker_sha256",
      "execution_identity",
    ], `${device} device admission`);
    exactKeys(recorded.admission, [
      "kind", "receipt_path", "receipt_sha256",
      "deployment_receipt_path", "deployment_receipt_sha256",
      "provenance_manifest_path", "provenance_manifest_sha256",
      "returned_archive_path", "returned_archive_sha256", "build_job_id",
      "depot_tools_commit", "full_graph_root_path",
      "full_graph_receipt_path", "full_graph_receipt_sha256",
      "full_graph_inventory_path", "full_graph_inventory_sha256",
      "inventory_path", "inventory_sha256",
    ], `${device} admission files`);
    if (recorded.native_run !== nativeRunPath(root, device) ||
        recorded.platform !== spec.platform ||
        recorded.target !== spec.target ||
        recorded.package !== spec.packageName) {
      throw new Error(`${device} platform admission changed`);
    }
    requireHash(recorded.artifact_sha256, `${device} artifact hash`);
    requireHash(recorded.admission.receipt_sha256,
      `${device} admission receipt hash`);
    if (device === "oneplus") {
      parsePhysicalDeviceIdentityEnv(Object.entries(recorded.execution_identity)
        .map(([key, value]) => `${key}=${value}`).join("\n") + "\n");
    } else {
      parseLinuxHostIdentityEnv(Object.entries(recorded.execution_identity)
        .map(([key, value]) => `${key}=${value}`).join("\n") + "\n", device);
    }
    const audited = await auditArtifactAdmission(recorded.native_run);
    const current = await describeAdmittedDevice(
      audited.run, device, recorded.execution_identity);
    if (!equalJSON(current.descriptor, recorded)) {
      throw new Error(`${device} admitted artifact or boundary changed`);
    }
    trains[device] = current.train;
  }
  requireOneLinuxRuntime(manifest.devices);
  if (!equalJSON(requireOneTrain(trains), manifest.source_train)) {
    throw new Error("shared artifact source train changed");
  }
  return {root, manifest};
}

function validateInitialSync(value, device, recordCount) {
  exactKeys(value, [
    "server_sequence", "password_revision", "cookie_revision",
    "password_apply", "cookie_apply", "password_readback",
    "cookie_readback", "initial_publications",
  ], `${device} initial sync`);
  positiveInt64(value.server_sequence, `${device} initial sequence`);
  if (value.password_revision !== "1" || value.cookie_revision !== "1" ||
      value.password_apply !== "verified" || value.cookie_apply !== "verified" ||
      value.password_readback !== "exact" || value.cookie_readback !== "exact") {
    throw new Error(`${device} did not verify the initial native application`);
  }
  exactKeys(value.initial_publications, ["passwords", "cookies"],
    `${device} initial publications`);
  int64String(value.initial_publications.passwords,
    `${device} initial password publications`);
  int64String(value.initial_publications.cookies,
    `${device} initial cookie publications`);
  if (device === "d") {
    if (value.initial_publications.passwords !== "1" ||
        value.initial_publications.cookies !== String(recordCount)) {
      throw new Error("d seed publication does not match the synthetic inventory");
    }
  } else if (value.initial_publications.passwords !== "0" ||
      value.initial_publications.cookies !== "0") {
    throw new Error(`${device} initial pull-only join published records`);
  }
}

function validateUnchangedRestart(value, device) {
  exactKeys(value, [
    "before_sequence", "after_sequence", "before_state_sha256",
    "after_state_sha256", "before_journal_sha256", "after_journal_sha256",
    "password_publications", "cookie_publications",
  ], `${device} unchanged restart`);
  int64String(value.before_sequence, `${device} restart sequence`);
  int64String(value.after_sequence, `${device} restart sequence`);
  for (const field of [
    "before_state_sha256", "after_state_sha256",
    "before_journal_sha256", "after_journal_sha256",
  ]) requireHash(value[field], `${device} ${field}`);
  if (value.before_sequence !== value.after_sequence ||
      value.before_state_sha256 !== value.after_state_sha256 ||
      value.before_journal_sha256 !== value.after_journal_sha256 ||
      value.password_publications !== "0" ||
      value.cookie_publications !== "0") {
    throw new Error(`${device} unchanged restart mutated or published state`);
  }
}

function validatePasswordEvidence(value) {
  exactKeys(value, [
    "record_key", "seed_source", "seed_revision", "update_source",
    "update_revision", "delete_source", "tombstone_revision",
    "applications", "stale_conflict",
  ], "browser password evidence");
  if (!CREDENTIAL_KEY.test(value.record_key) || value.seed_source !== "d" ||
      value.seed_revision !== "1" || value.update_source !== "da" ||
      value.update_revision !== "2" || value.delete_source !== "da" ||
      value.tombstone_revision !== "3" || !Array.isArray(value.applications)) {
    throw new Error("browser password lifecycle metadata is invalid");
  }
  const expectedApplications = DEVICES.flatMap(device =>
    ["1", "2", "3"].map(revision => `${device}:${revision}`));
  const actualApplications = value.applications.map((entry, index) => {
    exactKeys(entry, [
      "device", "revision", "deleted", "apply", "store_readback",
    ], `password application ${index}`);
    if (!DEVICES.includes(entry.device) ||
        !["1", "2", "3"].includes(entry.revision) ||
        entry.deleted !== (entry.revision === "3") ||
        entry.apply !== "verified" || entry.store_readback !== "exact") {
      throw new Error("native password-store application was not verified");
    }
    return `${entry.device}:${entry.revision}`;
  }).sort();
  if (!equalJSON(actualApplications, expectedApplications.sort())) {
    throw new Error("password applications do not cover every device and revision");
  }
  exactKeys(value.stale_conflict, [
    "device", "expected_revision", "authoritative_revision", "result",
    "accepted_publications", "authoritative_preserved", "local_preserved",
  ], "stale password conflict");
  if (value.stale_conflict.device !== "oneplus" ||
      value.stale_conflict.expected_revision !== "1" ||
      value.stale_conflict.authoritative_revision !== "2" ||
      value.stale_conflict.result !== "revision-conflict" ||
      value.stale_conflict.accepted_publications !== "0" ||
      value.stale_conflict.authoritative_preserved !== true ||
      value.stale_conflict.local_preserved !== true) {
    throw new Error("stale device password overwrite did not fail closed");
  }
}

function validateAuthenticatedRequest(value, device) {
  exactKeys(value, [
    "origin", "response_status", "result", "evidence_ref", "evidence_sha256",
  ], `${device} authenticated request`);
  const origin = new URL(value.origin);
  if (origin.protocol !== "https:" || origin.origin !== value.origin ||
      origin.pathname !== "/" || origin.search || origin.hash ||
      value.response_status !== 200 || value.result !== "authenticated" ||
      !EVIDENCE_REF.test(value.evidence_ref)) {
    throw new Error(`${device} has no exact authenticated destination request`);
  }
  requireHash(value.evidence_sha256, `${device} authenticated request evidence`);
}

function validateCookieTransaction(value, label, {rollback}) {
  exactKeys(value, [
    "preview", "apply", "readback", "destination_snapshot", "rollback",
  ], label);
  if (value.preview !== "verified" ||
      !["verified", "stopped"].includes(value.apply) ||
      !["exact", "not-run"].includes(value.readback) ||
      value.destination_snapshot !== "sealed" ||
      value.rollback !== rollback) {
    throw new Error(`${label} transaction evidence is invalid`);
  }
}

function validateCookieEvidence(value) {
  exactKeys(value, [
    "record_set_sha256", "rotating_record_key", "record_count",
    "attribute_coverage", "canonical_keys_unique",
    "partitioned_unpartitioned_distinct", "imports", "rotations",
    "conflict", "loop_prevention", "destination_exceptions",
    "origin_state_adapter_count", "arbitrary_database_merge",
  ], "browser cookie evidence");
  requireHash(value.record_set_sha256, "cookie record-set hash");
  if (!COOKIE_KEY.test(value.rotating_record_key) ||
      !Number.isSafeInteger(value.record_count) || value.record_count < 3 ||
      value.record_count > 4096 || value.canonical_keys_unique !== true ||
      value.partitioned_unpartitioned_distinct !== true ||
      value.origin_state_adapter_count !== 0 ||
      value.arbitrary_database_merge !== false) {
    throw new Error("cookie inventory or origin-state boundary is invalid");
  }
  const coverage = [
    "session", "persistent", "http_only", "secure", "same_site",
    "host_only", "domain", "partitioned", "unpartitioned",
    "source_scheme_port",
  ];
  exactKeys(value.attribute_coverage, coverage, "cookie attribute coverage");
  if (coverage.some(field => value.attribute_coverage[field] !== true)) {
    throw new Error("full canonical cookie attributes did not round-trip");
  }
  if (!Array.isArray(value.imports) || value.imports.length !== JOINERS.length) {
    throw new Error("cookie imports must cover exactly both joiners");
  }
  const imports = new Map();
  for (const entry of value.imports) {
    exactKeys(entry, [
      "device", "revision", "transaction", "authenticated_request",
    ], "cookie import");
    if (!JOINERS.includes(entry.device) || imports.has(entry.device) ||
        entry.revision !== "1") {
      throw new Error("cookie imports contain an invalid device or revision");
    }
    validateCookieTransaction(
      entry.transaction,
      `${entry.device} cookie import`,
      {rollback: "not-needed"},
    );
    if (entry.transaction.apply !== "verified" ||
        entry.transaction.readback !== "exact") {
      throw new Error(`${entry.device} cookie import did not commit exactly`);
    }
    validateAuthenticatedRequest(entry.authenticated_request, entry.device);
    imports.set(entry.device, entry);
  }
  if (JOINERS.some(device => !imports.has(device))) {
    throw new Error("cookie import omitted a joiner");
  }

  if (!Array.isArray(value.rotations) || value.rotations.length !== 2) {
    throw new Error("cookie evidence requires exactly two rotations");
  }
  for (const [index, rotation] of value.rotations.entries()) {
    exactKeys(rotation, [
      "source_device", "expected_revision", "revision", "destinations",
    ], `cookie rotation ${index}`);
    const expectedRevision = String(index + 1);
    const revision = String(index + 2);
    if (rotation.source_device !== "d" ||
        rotation.expected_revision !== expectedRevision ||
        rotation.revision !== revision ||
        !Array.isArray(rotation.destinations) ||
        rotation.destinations.length !== JOINERS.length) {
      throw new Error("cookie rotation order or authenticated source is invalid");
    }
    const seen = new Set();
    for (const destination of rotation.destinations) {
      exactKeys(destination, [
        "device", "apply", "readback", "echo_publications",
      ], `cookie rotation ${revision} destination`);
      if (!JOINERS.includes(destination.device) || seen.has(destination.device) ||
          destination.apply !== "verified" ||
          destination.readback !== "exact" ||
          destination.echo_publications !== "0") {
        throw new Error("cookie rotation did not converge without an echo");
      }
      seen.add(destination.device);
    }
  }

  exactKeys(value.conflict, [
    "device", "baseline_revision", "remote_revision", "remote_source",
    "action", "reason", "transaction", "last_good_local_preserved",
    "accepted_publications",
  ], "cookie rotation conflict");
  if (value.conflict.device !== "oneplus" ||
      value.conflict.baseline_revision !== "3" ||
      value.conflict.remote_revision !== "4" ||
      value.conflict.remote_source !== "d" ||
      value.conflict.action !== "stop" ||
      value.conflict.reason !== "concurrent-local-and-remote-change" ||
      value.conflict.last_good_local_preserved !== true ||
      value.conflict.accepted_publications !== "0") {
    throw new Error("cookie rotation conflict did not stop safely");
  }
  validateCookieTransaction(
    value.conflict.transaction,
    "cookie rotation conflict",
    {rollback: "exact"},
  );
  if (value.conflict.transaction.apply !== "stopped" ||
      value.conflict.transaction.readback !== "not-run") {
    throw new Error("cookie conflict unexpectedly applied remote state");
  }

  exactKeys(value.loop_prevention, [
    "device", "remote_revision", "repeated_apply_count",
    "echo_publications", "last_good_local_preserved",
  ], "cookie loop prevention");
  if (value.loop_prevention.device !== "oneplus" ||
      value.loop_prevention.remote_revision !== "4" ||
      value.loop_prevention.repeated_apply_count !== "0" ||
      value.loop_prevention.echo_publications !== "0" ||
      value.loop_prevention.last_good_local_preserved !== true) {
    throw new Error("cookie rotation loop prevention failed");
  }

  if (!Array.isArray(value.destination_exceptions)) {
    throw new Error("cookie destination exceptions must be an array");
  }
  const exceptionKeys = new Set();
  for (const [index, exception] of value.destination_exceptions.entries()) {
    exactKeys(exception, [
      "device", "record_key", "remote_revision", "payload_sha256",
      "observed_result", "classification", "rollback", "local_preserved",
      "evidence_ref", "evidence_sha256",
    ], `destination exception ${index}`);
    if (!JOINERS.includes(exception.device) ||
        !COOKIE_KEY.test(exception.record_key) ||
        positiveInt64(exception.remote_revision, "destination exception revision") < 1n ||
        exception.observed_result !== "destination-rejected" ||
        exception.classification !== "non-clonable" ||
        exception.rollback !== "exact" || exception.local_preserved !== true ||
        !EVIDENCE_REF.test(exception.evidence_ref)) {
      throw new Error("non-clonable classification lacks exact destination rejection");
    }
    requireHash(exception.payload_sha256, "destination exception payload hash");
    requireHash(exception.evidence_sha256, "destination exception evidence hash");
    const identity = `${exception.device}\0${exception.record_key}\0${exception.remote_revision}\0${exception.payload_sha256}`;
    if (exceptionKeys.has(identity)) {
      throw new Error("duplicate destination exception");
    }
    exceptionKeys.add(identity);
  }
  return {imports};
}

export function validateBrowserEvidence(value, manifest, runtimeEvidence) {
  exactKeys(value, [
    "schema_version", "evidence_scope", "writer", "source_train",
    "tabs_observed", "runtime_evidence_sha256", "devices", "password",
    "cookies",
  ], "browser evidence");
  if (value.schema_version !== SCHEMA_VERSION ||
      value.evidence_scope !== "disposable-browser" ||
      value.writer !== "native-password-store-and-cookie-manager" ||
      value.tabs_observed !== false ||
      !equalJSON(value.source_train, manifest.source_train) ||
      !Array.isArray(value.devices) || value.devices.length !== DEVICES.length) {
    throw new Error("browser evidence boundary is invalid");
  }
  const cookieResult = validateCookieEvidence(value.cookies);
  exactKeys(value.runtime_evidence_sha256, DEVICES,
    "browser runtime evidence hashes");
  const devices = new Map();
  for (const entry of value.devices) {
    exactKeys(entry, [
      "device", "platform", "target", "package", "artifact_sha256",
      "admission_sha256", "profile_marker_sha256",
      "native_ui_receipt_sha256", "role", "phase_before", "phase_after",
      "execution_identity_sha256", "initial_sync", "unchanged_restart",
    ], "browser device evidence");
    exactKeys(entry.admission_sha256, [
      "receipt", "deployment_receipt", "provenance_manifest",
      "returned_archive", "full_graph_receipt", "full_graph_inventory",
      "inventory",
    ],
      `${entry.device} browser admission hashes`);
    const recorded = manifest.devices[entry.device];
    const actualRuntime = runtimeEvidence?.[entry.device];
    const expectedAdmission = recorded && {
      receipt: recorded.admission.receipt_sha256,
      deployment_receipt: recorded.admission.deployment_receipt_sha256,
      provenance_manifest: recorded.admission.provenance_manifest_sha256,
      returned_archive: recorded.admission.returned_archive_sha256,
      full_graph_receipt: recorded.admission.full_graph_receipt_sha256,
      full_graph_inventory: recorded.admission.full_graph_inventory_sha256,
      inventory: recorded.admission.inventory_sha256,
    };
    if (!DEVICES.includes(entry.device) || devices.has(entry.device) ||
        entry.platform !== recorded?.platform ||
        entry.target !== recorded?.target ||
        entry.package !== recorded?.package ||
        entry.artifact_sha256 !== recorded?.artifact_sha256 ||
        !actualRuntime ||
        value.runtime_evidence_sha256[entry.device] !==
          actualRuntime.bundle_sha256 ||
        entry.execution_identity_sha256 !== actualRuntime.identity_sha256 ||
        !equalJSON(entry.admission_sha256, expectedAdmission) ||
        entry.profile_marker_sha256 !== recorded?.profile_marker_sha256 ||
        entry.role !== (entry.device === "d" ? "seed" : "join") ||
        entry.phase_before !== (entry.device === "d" ? "new" : "pending") ||
        entry.phase_after !== "active") {
      throw new Error("browser enrollment phase or device identity is invalid");
    }
    requireHash(entry.artifact_sha256, `${entry.device} browser artifact hash`);
    requireHash(entry.admission_sha256.receipt,
      `${entry.device} admission receipt hash`);
    if (entry.device === "oneplus") {
      requireHash(entry.admission_sha256.inventory,
        "OnePlus admission inventory hash");
      if (entry.admission_sha256.deployment_receipt !== null ||
          entry.admission_sha256.provenance_manifest !== null ||
          entry.admission_sha256.returned_archive !== null ||
          entry.admission_sha256.full_graph_receipt !== null ||
          entry.admission_sha256.full_graph_inventory !== null ||
          entry.profile_marker_sha256 !== null) {
        throw new Error(
          "OnePlus browser evidence invented a Linux admission or filesystem profile",
        );
      }
    } else {
      requireHash(entry.admission_sha256.deployment_receipt,
        `${entry.device} deployment receipt hash`);
      requireHash(entry.admission_sha256.provenance_manifest,
        `${entry.device} provenance manifest hash`);
      requireHash(entry.admission_sha256.returned_archive,
        `${entry.device} returned archive hash`);
      requireHash(entry.admission_sha256.full_graph_receipt,
        `${entry.device} full-graph receipt hash`);
      requireHash(entry.admission_sha256.full_graph_inventory,
        `${entry.device} full-graph inventory hash`);
      requireHash(entry.profile_marker_sha256,
        `${entry.device} profile marker hash`);
      if (entry.admission_sha256.inventory !== null) {
        throw new Error(`${entry.device} Linux evidence invented an APK inventory`);
      }
    }
    requireHash(entry.native_ui_receipt_sha256,
      `${entry.device} native UI receipt hash`);
    validateInitialSync(entry.initial_sync, entry.device, value.cookies.record_count);
    validateUnchangedRestart(entry.unchanged_restart, entry.device);
    if (entry.initial_sync.server_sequence !==
          actualRuntime.initial.client.sequence ||
        !equalJSON(entry.initial_sync.initial_publications,
          actualRuntime.initial_publications) ||
        entry.unchanged_restart.before_sequence !==
          actualRuntime.initial.client.sequence ||
        entry.unchanged_restart.after_sequence !==
          actualRuntime.restart.client.sequence ||
        entry.unchanged_restart.before_state_sha256 !==
          actualRuntime.initial.state_sha256 ||
        entry.unchanged_restart.after_state_sha256 !==
          actualRuntime.restart.state_sha256 ||
        entry.unchanged_restart.before_journal_sha256 !==
          actualRuntime.initial_journal_sha256 ||
        entry.unchanged_restart.after_journal_sha256 !==
          actualRuntime.restart_journal_sha256) {
      throw new Error(`${entry.device} browser claims do not derive from native bridge evidence`);
    }
    devices.set(entry.device, entry);
  }
  if (DEVICES.some(device => !devices.has(device))) {
    throw new Error("browser evidence omitted a device");
  }
  validatePasswordEvidence(value.password);
  for (const [device, imported] of cookieResult.imports) {
    const actual = runtimeEvidence[device].requests.find(request =>
      request.evidence_ref === imported.authenticated_request.evidence_ref);
    if (!actual || actual.origin !== imported.authenticated_request.origin ||
        actual.response_status !== imported.authenticated_request.response_status ||
        actual.result !== imported.authenticated_request.result ||
        actual.evidence_sha256 !==
          imported.authenticated_request.evidence_sha256) {
      throw new Error(`${device} authenticated request claim has no raw receipt`);
    }
  }
  for (const device of DEVICES) {
    const terminal = runtimeEvidence[device].terminal;
    const password = terminal.password.credentials.find(item =>
      item.key === value.password.record_key);
    const cookie = terminal.cookie.records[value.cookies.rotating_record_key];
    if (!password || !password.deleted || password.revision !== "3" ||
        !cookie || cookie.remote_revision !== "4" || cookie.device_id !== "d") {
      throw new Error(`${device} terminal native bridges do not contain authoritative state`);
    }
  }
  return {devices, cookieImports: cookieResult.imports};
}

function validatePublicationCounts(value, label, expectedPasswords, expectedCookies) {
  exactKeys(value, ["passwords", "cookies"], label);
  int64String(value.passwords, `${label} passwords`);
  int64String(value.cookies, `${label} cookies`);
  if (value.passwords !== expectedPasswords || value.cookies !== expectedCookies) {
    throw new Error(`${label} does not match the expected publication count`);
  }
}

export function validateServerEvidence(value, manifest, browserEvidence,
  runtimeEvidence) {
  exactKeys(value, [
    "schema_version", "source_train", "evidence_scope", "transport",
    "enrollment_order", "join_cursors",
    "initial_publications", "restarts", "password", "cookies",
    "counter_probe", "runtime_evidence_sha256", "journal", "logs",
  ], "server evidence");
  if (value.schema_version !== SCHEMA_VERSION ||
      !equalJSON(value.source_train, manifest.source_train) ||
      value.evidence_scope !== "disposable-tailnet-http-service" ||
      value.runtime_evidence_sha256 !== runtimeEvidence?.bundle_sha256 ||
      !equalJSON(value.enrollment_order, DEVICES)) {
    throw new Error("server evidence identity or enrollment order is invalid");
  }
  exactKeys(value.transport, [
    "endpoint", "network", "device_auth", "payload_visibility",
  ], "server transport");
  requireTailnetHTTP(value.transport.endpoint, "server endpoint");
  if (value.transport.network !== "tailscale-private" ||
      value.transport.device_auth !== "per-device-bearer" ||
      value.transport.payload_visibility !== "readable-private-journal" ||
      value.transport.endpoint !== runtimeEvidence.endpoint) {
    throw new Error("server transport did not use the admitted Tailnet HTTP boundary");
  }
  exactKeys(value.join_cursors, JOINERS, "server join cursors");
  exactKeys(value.initial_publications, DEVICES, "server initial publications");
  for (const device of DEVICES) {
    const browserDevice = browserEvidence.devices.find(entry => entry.device === device);
    validatePublicationCounts(
      value.initial_publications[device],
      `${device} server initial publications`,
      browserDevice.initial_sync.initial_publications.passwords,
      browserDevice.initial_sync.initial_publications.cookies,
    );
    if (device !== "d") {
      positiveInt64(value.join_cursors[device], `${device} server join cursor`);
      if (value.join_cursors[device] !== browserDevice.initial_sync.server_sequence) {
        throw new Error(`${device} browser/server join cursors disagree`);
      }
    }
  }
  if (!Array.isArray(value.restarts) || value.restarts.length !== DEVICES.length) {
    throw new Error("server restart evidence must cover every device");
  }
  const restartDevices = new Set();
  for (const restart of value.restarts) {
    exactKeys(restart, [
      "device", "before_sequence", "after_sequence",
      "password_publications", "cookie_publications",
    ], "server restart");
    if (!DEVICES.includes(restart.device) || restartDevices.has(restart.device)) {
      throw new Error("server restart device inventory is invalid");
    }
    const browserRestart = browserEvidence.devices.find(
      entry => entry.device === restart.device).unchanged_restart;
    if (restart.before_sequence !== browserRestart.before_sequence ||
        restart.after_sequence !== browserRestart.after_sequence ||
        restart.password_publications !== "0" ||
        restart.cookie_publications !== "0") {
      throw new Error(`${restart.device} server observed a restart publication`);
    }
    restartDevices.add(restart.device);
  }

  exactKeys(value.password, ["record_key", "revisions", "stale_conflict"],
    "server password evidence");
  if (value.password.record_key !== browserEvidence.password.record_key ||
      !Array.isArray(value.password.revisions) ||
      value.password.revisions.length !== 3) {
    throw new Error("server password record does not match browser evidence");
  }
  const expectedPasswordRevisions = [
    ["1", "d", false],
    ["2", "da", false],
    ["3", "da", true],
  ];
  value.password.revisions.forEach((entry, index) => {
    exactKeys(entry, ["revision", "device", "deleted"],
      `server password revision ${index}`);
    if (!equalJSON(
      [entry.revision, entry.device, entry.deleted],
      expectedPasswordRevisions[index],
    )) throw new Error("server password revision history is invalid");
  });
  const actualPasswordRevisions = runtimeEvidence.records.filter(record =>
    record.kind === "passwords" && record.key === value.password.record_key)
    .map(record => [record.revision, record.device_id, record.deleted]);
  if (!equalJSON(actualPasswordRevisions, expectedPasswordRevisions)) {
    throw new Error("server password claims do not derive from records.jsonl");
  }
  exactKeys(value.password.stale_conflict, [
    "device", "expected_revision", "current_revision", "result",
    "accepted_publications",
  ], "server stale password conflict");
  const browserConflict = browserEvidence.password.stale_conflict;
  if (value.password.stale_conflict.device !== browserConflict.device ||
      value.password.stale_conflict.expected_revision !==
        browserConflict.expected_revision ||
      value.password.stale_conflict.current_revision !==
        browserConflict.authoritative_revision ||
      value.password.stale_conflict.result !== "revision-conflict" ||
      value.password.stale_conflict.accepted_publications !== "0") {
    throw new Error("server did not reject the stale password mutation");
  }
  if (runtimeEvidence.password_conflict.request.key !==
        value.password.record_key ||
      runtimeEvidence.password_conflict.request.expected_revision !==
        value.password.stale_conflict.expected_revision ||
      runtimeEvidence.password_conflict.response.body.current_revision !==
        value.password.stale_conflict.current_revision) {
    throw new Error("server password conflict claim has no exact HTTP 409 receipt");
  }

  exactKeys(value.cookies, [
    "record_key", "authoritative_source", "revisions", "rejected_conflict",
  ], "server cookie evidence");
  if (value.cookies.record_key !== browserEvidence.cookies.rotating_record_key ||
      value.cookies.authoritative_source !== "d" ||
      !Array.isArray(value.cookies.revisions) ||
      value.cookies.revisions.length !== 4) {
    throw new Error("server cookie authority metadata is invalid");
  }
  value.cookies.revisions.forEach((entry, index) => {
    exactKeys(entry, ["revision", "device", "deleted"],
      `server cookie revision ${index}`);
    if (entry.revision !== String(index + 1) ||
        entry.device !== "d" || entry.deleted !== false) {
      throw new Error("server cookie revision history changed source or order");
    }
  });
  const actualCookieRevisions = runtimeEvidence.records.filter(record =>
    record.kind === "cookies" && record.key === value.cookies.record_key)
    .map(record => ({
      revision: record.revision, device: record.device_id, deleted: record.deleted,
    }));
  if (!equalJSON(actualCookieRevisions, value.cookies.revisions)) {
    throw new Error("server cookie claims do not derive from records.jsonl");
  }
  exactKeys(value.cookies.rejected_conflict, [
    "device", "expected_revision", "current_revision", "result",
    "accepted_publications",
  ], "server cookie conflict");
  if (value.cookies.rejected_conflict.device !== "oneplus" ||
      value.cookies.rejected_conflict.expected_revision !== "3" ||
      value.cookies.rejected_conflict.current_revision !== "4" ||
      value.cookies.rejected_conflict.result !== "revision-conflict" ||
      value.cookies.rejected_conflict.accepted_publications !== "0") {
    throw new Error("server cookie conflict did not preserve authoritative revision");
  }
  if (runtimeEvidence.cookie_conflict.request.key !== value.cookies.record_key ||
      runtimeEvidence.cookie_conflict.request.expected_revision !==
        value.cookies.rejected_conflict.expected_revision ||
      runtimeEvidence.cookie_conflict.response.body.current_revision !==
        value.cookies.rejected_conflict.current_revision) {
    throw new Error("server cookie conflict claim has no exact HTTP 409 receipt");
  }

  exactKeys(value.counter_probe, [
    "encoding", "uint32_plus_one", "round_trip", "overflow_rejected",
  ], "server counter probe");
  if (value.counter_probe.encoding !== "int64-string" ||
      value.counter_probe.uint32_plus_one !== "4294967296" ||
      int64String(value.counter_probe.uint32_plus_one, "uint32-plus-one probe") !==
        4294967296n ||
      value.counter_probe.round_trip !== true ||
      value.counter_probe.overflow_rejected !== true) {
    throw new Error("server did not prove 64-bit sequence handling");
  }
  exactKeys(value.journal, [
    "sha256", "schema_version", "tabs_records", "payload_storage",
    "bearer_tokens_present", "private_mode",
  ], "server journal evidence");
  requireHash(value.journal.sha256, "server journal hash");
  if (value.journal.sha256 !== runtimeEvidence.journal_sha256 ||
      value.journal.tabs_records !== "0" ||
      value.journal.schema_version !== "2" ||
      value.journal.payload_storage !== "readable" ||
      value.journal.bearer_tokens_present !== false ||
      value.journal.private_mode !== true) {
    throw new Error("server journal violates the private readable schema-2 boundary");
  }
  exactKeys(value.logs, [
    "password_values_detected", "bearer_tokens_detected",
  ], "server log evidence");
  if (value.logs.password_values_detected !== false ||
      value.logs.bearer_tokens_detected !== false) {
    throw new Error("server logs contain a password value or bearer token");
  }
}

function validateOriginAudit(input, expectedDevice, manifest, browserEvidence) {
  const result = auditOriginState(input);
  if (result.proof_level !== "disposable-browser" ||
      result.artifact_sha256 !== manifest.devices[expectedDevice].artifact_sha256 ||
      result.target_device !== expectedDevice ||
      !Array.isArray(result.origins) || result.origins.length === 0) {
    throw new Error(`${expectedDevice} origin-state audit is not disposable browser evidence`);
  }
  const imported = browserEvidence.cookies.imports.find(
    entry => entry.device === expectedDevice);
  const origin = result.origins.find(
    entry => entry.origin === imported.authenticated_request.origin);
  const stateKinds = origin?.state.map(entry => entry.kind).sort() || [];
  if (!origin || origin.cookie_classification !== "destination-verified" ||
      origin.cookie_evidence_ref !== imported.authenticated_request.evidence_ref ||
      !equalJSON(stateKinds, ORIGIN_STATE_KINDS) ||
      origin.state.some(entry =>
        entry.classification !== "not-required-observed")) {
    throw new Error(`${expectedDevice} origin-state audit does not bind the authenticated request`);
  }
  return result;
}

async function auditNativeRuns(manifest) {
  const audited = {};
  for (const device of DEVICES) {
    const nativeRun = manifest.devices[device].native_run;
    audited[device] = await auditVerifiedSyncRun({
      runRoot: nativeRun,
      fixtureEvidence: path.join(nativeRun, "fixture-evidence.json"),
    });
    if (audited[device].receipt.artifact_sha256 !==
        manifest.devices[device].artifact_sha256) {
      throw new Error(`${device} native receipt belongs to a different artifact`);
    }
  }
  return audited;
}

function requireNativeBindings(browserEvidence, nativeRuns) {
  for (const device of DEVICES) {
    const evidence = browserEvidence.devices.find(
      entry => entry.device === device);
    if (evidence.native_ui_receipt_sha256 !==
        nativeRuns[device].receipt_sha256) {
      throw new Error(
        `${device} browser evidence is not bound to its verified native UI receipt`);
    }
  }
}

function artifactHashes(manifest) {
  return Object.fromEntries(DEVICES.map(device => [
    device, manifest.devices[device].artifact_sha256,
  ]));
}

function nativeReceiptHashes(nativeRuns) {
  return Object.fromEntries(DEVICES.map(device => [
    device, nativeRuns[device].receipt_sha256,
  ]));
}

function admissionHashes(manifest) {
  return Object.fromEntries(DEVICES.map(device => {
    const admission = manifest.devices[device].admission;
    return [device, {
      receipt: admission.receipt_sha256,
      deployment_receipt: admission.deployment_receipt_sha256,
      provenance_manifest: admission.provenance_manifest_sha256,
      returned_archive: admission.returned_archive_sha256,
      full_graph_receipt: admission.full_graph_receipt_sha256,
      full_graph_inventory: admission.full_graph_inventory_sha256,
      inventory: admission.inventory_sha256,
    }];
  }));
}

function profileMarkerHashes(manifest) {
  return Object.fromEntries(DEVICES.map(device => [
    device, manifest.devices[device].profile_marker_sha256,
  ]));
}

export async function verifyThreeClientRun({
  runRoot,
  browserEvidence,
  serverEvidence,
  dRuntimeEvidence,
  daRuntimeEvidence,
  oneplusRuntimeEvidence,
  serverRuntimeEvidence,
  daOriginAudit,
  oneplusOriginAudit,
}) {
  const {root, manifest} = await loadManifest(runRoot);
  const nativeRuns = await auditNativeRuns(manifest);
  const runtimeDevices = {
    d: await auditDeviceRuntimeEvidence(
      dRuntimeEvidence, "d", manifest.devices.d.execution_identity),
    da: await auditDeviceRuntimeEvidence(
      daRuntimeEvidence, "da", manifest.devices.da.execution_identity),
    oneplus: await auditDeviceRuntimeEvidence(
      oneplusRuntimeEvidence, "oneplus",
      manifest.devices.oneplus.execution_identity),
  };
  const serverRuntime = await auditServerRuntimeEvidence(serverRuntimeEvidence);
  if (DEVICES.some(device =>
    runtimeDevices[device].terminal.client.sequence !==
      serverRuntime.max_sequence)) {
    throw new Error("terminal native bridge cursors do not acknowledge the final journal");
  }

  const browserFile = await readJSON(browserEvidence, "browser-native flow evidence");
  const serverFile = await readJSON(serverEvidence, "server flow evidence");
  const daAuditFile = await readJSON(daOriginAudit, "da origin-state evidence");
  const oneplusAuditFile = await readJSON(
    oneplusOriginAudit,
    "oneplus origin-state evidence",
  );
  validateBrowserEvidence(browserFile.value, manifest, runtimeDevices);
  requireNativeBindings(browserFile.value, nativeRuns);
  validateServerEvidence(
    serverFile.value, manifest, browserFile.value, serverRuntime);
  validateOriginAudit(daAuditFile.value, "da", manifest, browserFile.value);
  validateOriginAudit(
    oneplusAuditFile.value,
    "oneplus",
    manifest,
    browserFile.value,
  );

  const receipt = {
    schema_version: SCHEMA_VERSION,
    result: "passed",
    artifact_sha256: artifactHashes(manifest),
    source_train: manifest.source_train,
    admission_sha256: admissionHashes(manifest),
    native_ui_receipt_sha256: nativeReceiptHashes(nativeRuns),
    runtime_evidence_sha256: {
      d: runtimeDevices.d.bundle_sha256,
      da: runtimeDevices.da.bundle_sha256,
      oneplus: runtimeDevices.oneplus.bundle_sha256,
      server: serverRuntime.bundle_sha256,
    },
    browser_evidence_sha256: sha256(browserFile.raw),
    server_evidence_sha256: sha256(serverFile.raw),
    da_origin_audit_sha256: sha256(daAuditFile.raw),
    oneplus_origin_audit_sha256: sha256(oneplusAuditFile.raw),
    profile_marker_sha256: profileMarkerHashes(manifest),
    enrollment_order: DEVICES,
    password_revisions: {
      seed: "1",
      update: "2",
      tombstone: "3",
    },
    cookie_authoritative_revision: "4",
    uint32_plus_one_sequence: "4294967296",
    tabs_policy: "excluded",
    verified_at: new Date().toISOString(),
  };

  const finalDirectory = path.join(root, "verified");
  try {
    await fsp.lstat(finalDirectory);
    throw new Error("three-client acceptance receipt already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const incoming = path.join(
    root,
    `.verified.incoming-${process.pid}-${crypto.randomUUID()}`,
  );
  await fsp.mkdir(incoming, {mode: 0o700});
  try {
    const inputs = [
      ["browser-evidence.json", browserFile.raw],
      ["server-evidence.json", serverFile.raw],
      ["da-origin-audit.json", daAuditFile.raw],
      ["oneplus-origin-audit.json", oneplusAuditFile.raw],
    ];
    for (const [name, raw] of inputs) {
      await fsp.writeFile(path.join(incoming, name), raw, {
        mode: 0o600,
        flag: "wx",
      });
    }
    for (const [name, source] of [
      ["runtime-d", runtimeDevices.d.root],
      ["runtime-da", runtimeDevices.da.root],
      ["runtime-oneplus", runtimeDevices.oneplus.root],
      ["runtime-server", serverRuntime.root],
    ]) {
      await fsp.cp(source, path.join(incoming, name), {
        recursive: true,
        errorOnExist: true,
        force: false,
        preserveTimestamps: true,
      });
    }
    await writeJSONExclusive(path.join(incoming, "receipt.json"), receipt);
    await fsp.rename(incoming, finalDirectory);
  } catch (error) {
    await fsp.rm(incoming, {recursive: true, force: true});
    throw error;
  }
  return receipt;
}

export async function auditVerifiedThreeClientRun(runRoot) {
  const {root, manifest} = await loadManifest(runRoot);
  const finalDirectory = path.join(root, "verified");
  const nativeRuns = await auditNativeRuns(manifest);
  const runtimeDevices = {
    d: await auditDeviceRuntimeEvidence(
      path.join(finalDirectory, "runtime-d"), "d",
      manifest.devices.d.execution_identity),
    da: await auditDeviceRuntimeEvidence(
      path.join(finalDirectory, "runtime-da"), "da",
      manifest.devices.da.execution_identity),
    oneplus: await auditDeviceRuntimeEvidence(
      path.join(finalDirectory, "runtime-oneplus"), "oneplus",
      manifest.devices.oneplus.execution_identity),
  };
  const serverRuntime = await auditServerRuntimeEvidence(
    path.join(finalDirectory, "runtime-server"));
  if (DEVICES.some(device =>
    runtimeDevices[device].terminal.client.sequence !==
      serverRuntime.max_sequence)) {
    throw new Error("verified terminal bridge cursors do not acknowledge the journal");
  }
  const browserFile = await readJSON(
    path.join(finalDirectory, "browser-evidence.json"),
    "verified browser-native flow evidence",
  );
  const serverFile = await readJSON(
    path.join(finalDirectory, "server-evidence.json"),
    "verified server flow evidence",
  );
  const daAuditFile = await readJSON(
    path.join(finalDirectory, "da-origin-audit.json"),
    "verified da origin-state evidence",
  );
  const oneplusAuditFile = await readJSON(
    path.join(finalDirectory, "oneplus-origin-audit.json"),
    "verified oneplus origin-state evidence",
  );
  validateBrowserEvidence(browserFile.value, manifest, runtimeDevices);
  requireNativeBindings(browserFile.value, nativeRuns);
  validateServerEvidence(
    serverFile.value, manifest, browserFile.value, serverRuntime);
  validateOriginAudit(daAuditFile.value, "da", manifest, browserFile.value);
  validateOriginAudit(
    oneplusAuditFile.value,
    "oneplus",
    manifest,
    browserFile.value,
  );

  const receiptFile = await readJSON(
    path.join(finalDirectory, "receipt.json"),
    "three-client acceptance receipt",
  );
  const verifiedAt = receiptFile.value?.verified_at;
  const expected = {
    schema_version: SCHEMA_VERSION,
    result: "passed",
    artifact_sha256: artifactHashes(manifest),
    source_train: manifest.source_train,
    admission_sha256: admissionHashes(manifest),
    native_ui_receipt_sha256: nativeReceiptHashes(nativeRuns),
    runtime_evidence_sha256: {
      d: runtimeDevices.d.bundle_sha256,
      da: runtimeDevices.da.bundle_sha256,
      oneplus: runtimeDevices.oneplus.bundle_sha256,
      server: serverRuntime.bundle_sha256,
    },
    browser_evidence_sha256: sha256(browserFile.raw),
    server_evidence_sha256: sha256(serverFile.raw),
    da_origin_audit_sha256: sha256(daAuditFile.raw),
    oneplus_origin_audit_sha256: sha256(oneplusAuditFile.raw),
    profile_marker_sha256: profileMarkerHashes(manifest),
    enrollment_order: DEVICES,
    password_revisions: {
      seed: "1",
      update: "2",
      tombstone: "3",
    },
    cookie_authoritative_revision: "4",
    uint32_plus_one_sequence: "4294967296",
    tabs_policy: "excluded",
    verified_at: verifiedAt,
  };
  if (typeof verifiedAt !== "string" ||
      !Number.isFinite(Date.parse(verifiedAt)) ||
      !equalJSON(receiptFile.value, expected)) {
    throw new Error("three-client acceptance receipt no longer matches its evidence");
  }
  return {root, manifest, receipt: receiptFile.value};
}

export async function acceptanceStatus(runRoot) {
  const {root, manifest} = await loadManifest(runRoot);
  let state = "native-ui-required";
  try {
    for (const device of DEVICES) {
      await regularFile(
        path.join(manifest.devices[device].native_run, "sync-receipt.json"),
        `${device} Sync acceptance receipt`,
      );
    }
    state = "flow-evidence-required";
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  try {
    await auditVerifiedThreeClientRun(root);
    state = "passed";
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return {run: root, state};
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) {
      throw new Error(`invalid argument: ${key}`);
    }
    const name = key.slice(2);
    if (Object.hasOwn(result, name)) throw new Error(`duplicate argument: ${key}`);
    result[name] = argv[++index];
  }
  return result;
}

function requireArgs(args, names) {
  if (!equalJSON(Object.keys(args).sort(), [...names].sort())) {
    throw new Error(`expected arguments: ${[...names].sort().join(", ")}`);
  }
}

function usage() {
  return `usage:
  three-client-acceptance.mjs init --d-artifact FILE --d-artifact-receipt FILE --d-execution-identity FILE --da-artifact FILE --da-artifact-receipt FILE --da-execution-identity FILE --oneplus-artifact Browser-test.apk --oneplus-execution-identity FILE --output NEW_DIR
  three-client-acceptance.mjs status --run DIR
  three-client-acceptance.mjs verify --run DIR --browser-evidence JSON --server-evidence JSON --d-runtime-evidence DIR --da-runtime-evidence DIR --oneplus-runtime-evidence DIR --server-runtime-evidence DIR --da-origin-audit JSON --oneplus-origin-audit JSON
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    const args = parseArgs(process.argv.slice(3));
    let result;
    if (command === "init") {
      requireArgs(args, [
        "d-artifact", "d-artifact-receipt",
        "d-execution-identity",
        "da-artifact", "da-artifact-receipt",
        "da-execution-identity", "oneplus-artifact",
        "oneplus-execution-identity", "output",
      ]);
      result = await initializeThreeClientRun({
        dArtifact: args["d-artifact"],
        dArtifactReceipt: args["d-artifact-receipt"],
        daArtifact: args["da-artifact"],
        daArtifactReceipt: args["da-artifact-receipt"],
        oneplusArtifact: args["oneplus-artifact"],
        dExecutionIdentity: args["d-execution-identity"],
        daExecutionIdentity: args["da-execution-identity"],
        oneplusExecutionIdentity: args["oneplus-execution-identity"],
        output: args.output,
      });
      result = {
        event: "initialized",
        run: result.root,
        source_train: result.source_train,
        devices: result.devices,
      };
    } else if (command === "status") {
      requireArgs(args, ["run"]);
      result = {event: "status", ...await acceptanceStatus(args.run)};
    } else if (command === "verify") {
      requireArgs(args, [
        "run", "browser-evidence", "server-evidence",
        "d-runtime-evidence", "da-runtime-evidence",
        "oneplus-runtime-evidence", "server-runtime-evidence",
        "da-origin-audit", "oneplus-origin-audit",
      ]);
      const receipt = await verifyThreeClientRun({
        runRoot: args.run,
        browserEvidence: args["browser-evidence"],
        serverEvidence: args["server-evidence"],
        dRuntimeEvidence: args["d-runtime-evidence"],
        daRuntimeEvidence: args["da-runtime-evidence"],
        oneplusRuntimeEvidence: args["oneplus-runtime-evidence"],
        serverRuntimeEvidence: args["server-runtime-evidence"],
        daOriginAudit: args["da-origin-audit"],
        oneplusOriginAudit: args["oneplus-origin-audit"],
      });
      result = {event: "passed", receipt};
    } else {
      throw new Error(usage());
    }
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`three-client acceptance: ${error.message}\n`);
    process.exit(1);
  }
}
