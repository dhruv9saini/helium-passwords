#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

import {
  DISPOSABLE_PROFILE_MARKER,
  initializeRun,
} from "../password-runtime/acceptance.mjs";
import {auditVerifiedSyncRun} from "../password-runtime/sync-acceptance.mjs";
import {auditOriginState} from "../session-state/origin-state-audit.mjs";

const SCHEMA_VERSION = 1;
const ROOT_MARKER = "helium-three-client-disposable-v1\n";
const DEVICE_MARKER_PREFIX = "helium-three-client-device-v1:";
const DEVICES = Object.freeze(["d", "da", "oneplus"]);
const JOINERS = Object.freeze(["da", "oneplus"]);
const HASH = /^[0-9a-f]{64}$/;
const CREDENTIAL_KEY = /^credential\/v2\/[0-9a-f]{64}$/;
const COOKIE_KEY = /^[0-9a-f]{64}$/;
const EVIDENCE_REF = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const INT64_MAX = 9223372036854775807n;
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

function expectedProfilePath(root, device) {
  if (device === "d") return path.join(root, "native-ui-d", "profile");
  return path.join(root, "profiles", device);
}

async function admittedSourceCommit(receiptPath) {
  const raw = await fsp.readFile(receiptPath, "utf8");
  const values = raw.split("\n")
    .filter(line => line.startsWith("source_commit="))
    .map(line => line.slice("source_commit=".length));
  if (values.length !== 1 || !/^[0-9a-f]{40}$/.test(values[0])) {
    throw new Error("admitted artifact receipt has no exact source commit");
  }
  return values[0];
}

export async function initializeThreeClientRun({
  artifact,
  artifactReceipt,
  output,
}) {
  const root = path.resolve(output);
  try {
    await fsp.lstat(root);
    throw new Error("three-client acceptance output already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const nativeUIRoot = path.join(root, "native-ui-d");
  const nativeRun = await initializeRun({
    artifact,
    artifactReceipt,
    output: nativeUIRoot,
    platform: "linux",
  });
  await fsp.chmod(root, 0o700);
  await fsp.mkdir(path.join(root, "profiles"), {mode: 0o700});
  for (const device of JOINERS) {
    const profile = expectedProfilePath(root, device);
    await fsp.mkdir(profile, {mode: 0o700});
    await fsp.writeFile(
      path.join(profile, "SYNTHETIC_ONLY"),
      DISPOSABLE_PROFILE_MARKER,
      {mode: 0o600, flag: "wx"},
    );
  }
  for (const device of DEVICES) {
    await fsp.writeFile(
      path.join(expectedProfilePath(root, device), "HELIUM_SYNC_DEVICE"),
      `${DEVICE_MARKER_PREFIX}${device}\n`,
      {mode: 0o600, flag: "wx"},
    );
  }
  await fsp.writeFile(
    path.join(root, "SYNTHETIC_ONLY"),
    ROOT_MARKER,
    {mode: 0o600, flag: "wx"},
  );

  const profileMarkerSHA256 = {};
  const profiles = {};
  for (const device of DEVICES) {
    const profile = expectedProfilePath(root, device);
    profiles[device] = profile;
    profileMarkerSHA256[device] = await requireDisposableProfile(
      profile, profile, device);
  }
  const manifest = {
    schema_version: SCHEMA_VERSION,
    root,
    artifact_path: nativeRun.artifact_path,
    artifact_sha256: nativeRun.artifact_sha256,
    artifact_receipt_path: nativeRun.artifact_receipt,
    artifact_receipt_sha256: nativeRun.artifact_receipt_sha256,
    source_commit: await admittedSourceCommit(nativeRun.artifact_receipt),
    created_at: new Date().toISOString(),
    native_ui_run: nativeUIRoot,
    profiles,
    profile_marker_sha256: profileMarkerSHA256,
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
    "schema_version", "root", "artifact_path", "artifact_sha256",
    "artifact_receipt_path", "artifact_receipt_sha256", "source_commit",
    "created_at", "native_ui_run", "profiles", "profile_marker_sha256",
    "expected_enrollment_order", "tabs_policy",
  ], "three-client run");
  exactKeys(manifest.profiles, DEVICES, "three-client profiles");
  exactKeys(manifest.profile_marker_sha256, DEVICES, "profile marker hashes");
  if (manifest.schema_version !== SCHEMA_VERSION || manifest.root !== root ||
      manifest.native_ui_run !== path.join(root, "native-ui-d") ||
      !Number.isFinite(Date.parse(manifest.created_at)) ||
      !equalJSON(manifest.expected_enrollment_order, DEVICES) ||
      manifest.tabs_policy !== "excluded") {
    throw new Error("three-client run metadata is invalid");
  }
  requireHash(manifest.artifact_sha256, "run artifact hash");
  requireHash(manifest.artifact_receipt_sha256, "run artifact receipt hash");
  if (!/^[0-9a-f]{40}$/.test(manifest.source_commit)) {
    throw new Error("run source commit is invalid");
  }
  const artifact = await regularFile(manifest.artifact_path, "admitted browser", 2 * 1024 * 1024 * 1024);
  if (await sha256File(artifact.resolved) !== manifest.artifact_sha256) {
    throw new Error("admitted browser changed after initialization");
  }
  const artifactReceipt = await regularFile(
    manifest.artifact_receipt_path,
    "admitted browser receipt",
  );
  if ((artifactReceipt.info.mode & 0o077) !== 0 ||
      await sha256File(artifactReceipt.resolved) !== manifest.artifact_receipt_sha256) {
    throw new Error("admitted browser receipt changed after initialization");
  }
  for (const device of DEVICES) {
    const expected = expectedProfilePath(root, device);
    if (manifest.profiles[device] !== expected ||
        await requireDisposableProfile(
          manifest.profiles[device], expected, device) !==
          manifest.profile_marker_sha256[device]) {
      throw new Error(`disposable ${device} profile no longer matches the run`);
    }
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

export function validateBrowserEvidence(value, manifest) {
  exactKeys(value, [
    "schema_version", "artifact_sha256", "evidence_scope", "writer",
    "native_ui_receipt_sha256", "tabs_observed", "profile_marker_sha256",
    "devices", "password", "cookies",
  ], "browser evidence");
  exactKeys(value.profile_marker_sha256, DEVICES, "browser profile marker hashes");
  if (value.schema_version !== SCHEMA_VERSION ||
      value.artifact_sha256 !== manifest.artifact_sha256 ||
      value.evidence_scope !== "disposable-browser" ||
      value.writer !== "native-password-store-and-cookie-manager" ||
      value.tabs_observed !== false ||
      !equalJSON(value.profile_marker_sha256, manifest.profile_marker_sha256) ||
      !Array.isArray(value.devices) || value.devices.length !== DEVICES.length) {
    throw new Error("browser evidence boundary is invalid");
  }
  requireHash(value.native_ui_receipt_sha256, "native UI receipt hash");
  const cookieResult = validateCookieEvidence(value.cookies);
  const devices = new Map();
  for (const entry of value.devices) {
    exactKeys(entry, [
      "device", "role", "phase_before", "phase_after", "initial_sync",
      "unchanged_restart",
    ], "browser device evidence");
    if (!DEVICES.includes(entry.device) || devices.has(entry.device) ||
        entry.role !== (entry.device === "d" ? "seed" : "join") ||
        entry.phase_before !== (entry.device === "d" ? "new" : "pending") ||
        entry.phase_after !== "active") {
      throw new Error("browser enrollment phase or device identity is invalid");
    }
    validateInitialSync(entry.initial_sync, entry.device, value.cookies.record_count);
    validateUnchangedRestart(entry.unchanged_restart, entry.device);
    devices.set(entry.device, entry);
  }
  if (DEVICES.some(device => !devices.has(device))) {
    throw new Error("browser evidence omitted a device");
  }
  validatePasswordEvidence(value.password);
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

export function validateServerEvidence(value, manifest, browserEvidence) {
  exactKeys(value, [
    "schema_version", "artifact_sha256", "source_commit", "evidence_scope",
    "transport", "enrollment_order", "join_cursors",
    "initial_publications", "restarts", "password", "cookies",
    "counter_probe", "journal",
  ], "server evidence");
  if (value.schema_version !== SCHEMA_VERSION ||
      value.artifact_sha256 !== manifest.artifact_sha256 ||
      value.source_commit !== manifest.source_commit ||
      value.evidence_scope !== "disposable-tls-service" ||
      !equalJSON(value.enrollment_order, DEVICES)) {
    throw new Error("server evidence identity or enrollment order is invalid");
  }
  exactKeys(value.transport, [
    "tls", "network", "device_auth", "payload_visibility",
  ], "server transport");
  if (value.transport.tls !== "verified" ||
      value.transport.network !== "tailscale" ||
      value.transport.device_auth !== "per-device" ||
      value.transport.payload_visibility !== "ciphertext-only") {
    throw new Error("server transport did not use authenticated TLS/E2EE");
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
    "sha256", "tabs_records", "plaintext_detected", "secret_fields_logged",
  ], "server journal evidence");
  requireHash(value.journal.sha256, "server journal hash");
  if (value.journal.tabs_records !== "0" ||
      value.journal.plaintext_detected !== false ||
      value.journal.secret_fields_logged !== false) {
    throw new Error("server journal contains tabs, plaintext, or logged secrets");
  }
}

function validateOriginAudit(input, expectedDevice, manifest, browserEvidence) {
  const result = auditOriginState(input);
  if (result.proof_level !== "disposable-browser" ||
      result.artifact_sha256 !== manifest.artifact_sha256 ||
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

export async function verifyThreeClientRun({
  runRoot,
  browserEvidence,
  serverEvidence,
  daOriginAudit,
  oneplusOriginAudit,
}) {
  const {root, manifest} = await loadManifest(runRoot);
  const nativeUI = await auditVerifiedSyncRun({
    runRoot: manifest.native_ui_run,
    fixtureEvidence: path.join(manifest.native_ui_run, "fixture-evidence.json"),
  });
  if (nativeUI.receipt.artifact_sha256 !== manifest.artifact_sha256) {
    throw new Error("native password UI receipt belongs to a different browser");
  }

  const browserFile = await readJSON(browserEvidence, "browser-native flow evidence");
  const serverFile = await readJSON(serverEvidence, "server flow evidence");
  const daAuditFile = await readJSON(daOriginAudit, "da origin-state evidence");
  const oneplusAuditFile = await readJSON(
    oneplusOriginAudit,
    "oneplus origin-state evidence",
  );
  validateBrowserEvidence(browserFile.value, manifest);
  if (browserFile.value.native_ui_receipt_sha256 !== nativeUI.receipt_sha256) {
    throw new Error("browser evidence is not bound to the verified native UI receipt");
  }
  validateServerEvidence(serverFile.value, manifest, browserFile.value);
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
    artifact_sha256: manifest.artifact_sha256,
    source_commit: manifest.source_commit,
    native_ui_receipt_sha256: nativeUI.receipt_sha256,
    browser_evidence_sha256: sha256(browserFile.raw),
    server_evidence_sha256: sha256(serverFile.raw),
    da_origin_audit_sha256: sha256(daAuditFile.raw),
    oneplus_origin_audit_sha256: sha256(oneplusAuditFile.raw),
    profile_marker_sha256: manifest.profile_marker_sha256,
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
  const nativeUI = await auditVerifiedSyncRun({
    runRoot: manifest.native_ui_run,
    fixtureEvidence: path.join(manifest.native_ui_run, "fixture-evidence.json"),
  });
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
  validateBrowserEvidence(browserFile.value, manifest);
  if (browserFile.value.native_ui_receipt_sha256 !== nativeUI.receipt_sha256) {
    throw new Error("verified browser evidence lost its native UI binding");
  }
  validateServerEvidence(serverFile.value, manifest, browserFile.value);
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
    artifact_sha256: manifest.artifact_sha256,
    source_commit: manifest.source_commit,
    native_ui_receipt_sha256: nativeUI.receipt_sha256,
    browser_evidence_sha256: sha256(browserFile.raw),
    server_evidence_sha256: sha256(serverFile.raw),
    da_origin_audit_sha256: sha256(daAuditFile.raw),
    oneplus_origin_audit_sha256: sha256(oneplusAuditFile.raw),
    profile_marker_sha256: manifest.profile_marker_sha256,
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
    await regularFile(path.join(manifest.native_ui_run, "sync-receipt.json"),
      "Sync acceptance receipt");
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
  three-client-acceptance.mjs init --artifact FILE --artifact-receipt FILE --output NEW_DIR
  three-client-acceptance.mjs status --run DIR
  three-client-acceptance.mjs verify --run DIR --browser-evidence JSON --server-evidence JSON --da-origin-audit JSON --oneplus-origin-audit JSON
`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    const args = parseArgs(process.argv.slice(3));
    let result;
    if (command === "init") {
      requireArgs(args, ["artifact", "artifact-receipt", "output"]);
      result = await initializeThreeClientRun({
        artifact: args.artifact,
        artifactReceipt: args["artifact-receipt"],
        output: args.output,
      });
      result = {
        event: "initialized",
        run: result.root,
        artifact_sha256: result.artifact_sha256,
        native_ui_run: result.native_ui_run,
        profiles: result.profiles,
      };
    } else if (command === "status") {
      requireArgs(args, ["run"]);
      result = {event: "status", ...await acceptanceStatus(args.run)};
    } else if (command === "verify") {
      requireArgs(args, [
        "run", "browser-evidence", "server-evidence",
        "da-origin-audit", "oneplus-origin-audit",
      ]);
      const receipt = await verifyThreeClientRun({
        runRoot: args.run,
        browserEvidence: args["browser-evidence"],
        serverEvidence: args["server-evidence"],
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
