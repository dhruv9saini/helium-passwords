#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {fileURLToPath} from "node:url";

const HASH = /^[0-9a-f]{64}$/;
const GENERATION = /^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$/;
const DEVICES = new Set(["d", "da", "oneplus", "fixture"]);
const KINDS = new Set(["passwords", "cookies"]);
const MAX_SNAPSHOT = 64 * 1024 * 1024;

function fail(message) { throw new Error(message); }
function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}
async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}
function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !==
        JSON.stringify([...keys].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
}
function positiveWindowsTime(value, label) {
  if (typeof value !== "string" || !/^[1-9][0-9]*$/.test(value)) {
    fail(`${label} is not a positive Windows-microsecond timestamp`);
  }
  BigInt(value);
}

function windowsTimeToUnixMilliseconds(value) {
  const windowsEpochOffsetMicros = 11644473600000000n;
  return Number((BigInt(value) - windowsEpochOffsetMicros) / 1000n);
}

async function privateFile(file, label, maximum = MAX_SNAPSHOT) {
  const resolved = path.resolve(file);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
      stat.size > maximum || (stat.mode & 0o077) !== 0) {
    fail(`${label} must be a nonempty private regular file`);
  }
  return {resolved, raw: await fsp.readFile(resolved), stat};
}

async function regularPath(file, label, maximum) {
  const resolved = path.resolve(file);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
      stat.size > maximum) {
    fail(`${label} must be a nonempty regular file within its size limit`);
  }
  return {resolved, stat};
}

async function privateJSON(file, label, maximum) {
  const admitted = await privateFile(file, label, maximum);
  try {
    return {...admitted, value: JSON.parse(admitted.raw)};
  } catch {
    fail(`${label} is not valid JSON`);
  }
}

function cookieFingerprint(cookie) {
  const normalized = {...cookie};
  delete normalized.creation;
  delete normalized.last_access;
  delete normalized.last_update;
  return sha256(JSON.stringify(normalized));
}

function stateHash(kind, records) {
  let material = "";
  for (const record of records) {
    const fingerprint = kind === "passwords"
      ? sha256(JSON.stringify(record.payload))
      : cookieFingerprint(record.cookie);
    material += `${record.key}\0${fingerprint}\n`;
  }
  return sha256(material);
}

function validateCookie(cookie, label) {
  const required = [
    "name", "value", "domain", "path", "creation", "expiry",
    "last_access", "last_update", "secure", "http_only", "same_site",
    "priority", "source_scheme", "source_port", "source_type",
  ];
  const allowed = cookie?.partition_key ? [...required, "partition_key"] : required;
  exactKeys(cookie, allowed, label);
  for (const field of ["name", "value", "domain", "path", "creation",
    "expiry", "last_access", "last_update"]) {
    if (typeof cookie[field] !== "string") fail(`${label}.${field} is invalid`);
  }
  if (!cookie.domain || !cookie.path.startsWith("/") ||
      !/^[0-9]+$/.test(cookie.creation) || !/^[0-9]+$/.test(cookie.expiry) ||
      !/^[0-9]+$/.test(cookie.last_access) ||
      !/^[0-9]+$/.test(cookie.last_update) ||
      typeof cookie.secure !== "boolean" ||
      typeof cookie.http_only !== "boolean" ||
      !Number.isInteger(cookie.same_site) || cookie.same_site < -1 ||
      cookie.same_site > 2 || !Number.isInteger(cookie.priority) ||
      cookie.priority < 0 || cookie.priority > 2 ||
      !Number.isInteger(cookie.source_scheme) || cookie.source_scheme < 0 ||
      cookie.source_scheme > 2 || !Number.isInteger(cookie.source_port) ||
      cookie.source_port < -1 || cookie.source_port > 65535 ||
      !Number.isInteger(cookie.source_type) || cookie.source_type < 1 ||
      cookie.source_type > 3) {
    fail(`${label} has invalid Chromium cookie fields`);
  }
  if (cookie.partition_key) {
    exactKeys(cookie.partition_key,
      ["top_level_site", "has_cross_site_ancestor"], `${label}.partition_key`);
    if (typeof cookie.partition_key.top_level_site !== "string" ||
        !cookie.partition_key.top_level_site ||
        typeof cookie.partition_key.has_cross_site_ancestor !== "boolean") {
      fail(`${label}.partition_key is invalid`);
    }
  }
}

export async function verifySnapshot(file, expectedKind, expectedDevice,
  maxAgeSeconds) {
  if (!KINDS.has(expectedKind)) fail("snapshot kind is invalid");
  const snapshot = await privateJSON(file, `${expectedKind} snapshot`);
  exactKeys(snapshot.value, [
    "schema_version", "kind", "format", "source_device",
    "captured_at_windows_us", "record_count", "records",
    "records_sha256", "state_sha256",
  ], `${expectedKind} snapshot`);
  const format = expectedKind === "passwords"
    ? "chromium-password-specifics-neutral-v1"
    : "chromium-cookie-manager-neutral-v1";
  if (snapshot.value.schema_version !== 1 ||
      snapshot.value.kind !== expectedKind || snapshot.value.format !== format ||
      !DEVICES.has(snapshot.value.source_device) ||
      (expectedDevice && snapshot.value.source_device !== expectedDevice) ||
      !Number.isInteger(snapshot.value.record_count) ||
      snapshot.value.record_count < 0 || snapshot.value.record_count > 50000 ||
      !Array.isArray(snapshot.value.records) ||
      snapshot.value.records.length !== snapshot.value.record_count ||
      !HASH.test(snapshot.value.records_sha256 || "") ||
      !HASH.test(snapshot.value.state_sha256 || "")) {
    fail(`${expectedKind} snapshot metadata is invalid`);
  }
  positiveWindowsTime(snapshot.value.captured_at_windows_us,
    `${expectedKind} snapshot capture time`);
  if (maxAgeSeconds !== undefined) {
    if (!Number.isInteger(maxAgeSeconds) || maxAgeSeconds < 120 ||
        maxAgeSeconds > 3600) {
      fail("snapshot freshness bound must be 120 through 3600 seconds");
    }
    const age = Date.now() -
      windowsTimeToUnixMilliseconds(snapshot.value.captured_at_windows_us);
    if (age < -30_000 || age > maxAgeSeconds * 1000) {
      fail(`${expectedKind} snapshot is stale or future-dated`);
    }
  }
  if (sha256(JSON.stringify(snapshot.value.records)) !==
      snapshot.value.records_sha256) {
    fail(`${expectedKind} snapshot records checksum changed`);
  }
  const keys = new Set();
  for (const [index, record] of snapshot.value.records.entries()) {
    const label = `${expectedKind} record ${index + 1}`;
    exactKeys(record,
      expectedKind === "passwords" ? ["key", "payload"] : ["key", "cookie"],
      label);
    const pattern = expectedKind === "passwords"
      ? /^credential\/v2\/[0-9a-f]{64}$/ : /^[0-9a-f]{64}$/;
    if (typeof record.key !== "string" || !pattern.test(record.key) ||
        keys.has(record.key)) fail(`${label} has an invalid or duplicate key`);
    keys.add(record.key);
    if (expectedKind === "passwords") {
      exactKeys(record.payload,
        ["format", "password_specifics_data_b64"], `${label}.payload`);
      if (record.payload.format !== "chromium-password-specifics-data-v1" ||
          typeof record.payload.password_specifics_data_b64 !== "string" ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
            .test(record.payload.password_specifics_data_b64)) {
        fail(`${label} password specifics are invalid`);
      }
    } else {
      validateCookie(record.cookie, `${label}.cookie`);
    }
  }
  if (stateHash(expectedKind, snapshot.value.records) !==
      snapshot.value.state_sha256) {
    fail(`${expectedKind} snapshot state checksum changed`);
  }
  return {
    file: snapshot.resolved,
    file_sha256: sha256(snapshot.raw),
    device: snapshot.value.source_device,
    kind: expectedKind,
    count: snapshot.value.record_count,
    records_sha256: snapshot.value.records_sha256,
    state_sha256: snapshot.value.state_sha256,
  };
}

async function verifyBrowserReceipt(file, snapshot) {
  const receipt = await privateJSON(file, "native browser recovery receipt", 1024 * 1024);
  exactKeys(receipt.value, [
    "schema_version", "result", "kind", "snapshot_sha256",
    "records_sha256", "restored_state_sha256", "restored_count",
    "browser_api", "completed_at_windows_us",
  ], "native browser recovery receipt");
  const api = snapshot.kind === "passwords"
    ? "PasswordStoreInterface" : "network::mojom::CookieManager";
  if (receipt.value.schema_version !== 1 || receipt.value.result !== "passed" ||
      receipt.value.kind !== snapshot.kind ||
      receipt.value.snapshot_sha256 !== snapshot.file_sha256 ||
      receipt.value.records_sha256 !== snapshot.records_sha256 ||
      receipt.value.restored_state_sha256 !== snapshot.state_sha256 ||
      receipt.value.restored_count !== snapshot.count ||
      receipt.value.browser_api !== api) {
    fail("native browser recovery receipt does not bind the supplied snapshot");
  }
  positiveWindowsTime(receipt.value.completed_at_windows_us,
    "native browser recovery completion time");
  return {file_sha256: sha256(receipt.raw), api};
}

function parseEnv(raw, label) {
  const result = new Map();
  for (const line of raw.toString("utf8").split("\n")) {
    if (!line) continue;
    const split = line.indexOf("=");
    const key = line.slice(0, split);
    const value = line.slice(split + 1);
    if (split < 1 || !value || result.has(key) || /[\r\n\0]/.test(value)) {
      fail(`${label} is malformed`);
    }
    result.set(key, value);
  }
  return result;
}

async function verifyProfileRestore(file, snapshot, destination) {
  const receipt = await privateFile(file, "off-device profile restore receipt", 1024 * 1024);
  const value = parseEnv(receipt.raw, "off-device profile restore receipt");
  const expected = [
    "schema_version", "generation", "source_device", "profile_id",
    "archive_sha256", "source_destination", "restored_at",
  ];
  if (JSON.stringify([...value.keys()].sort()) !== JSON.stringify(expected.sort()) ||
      value.get("schema_version") !== "3" ||
      !GENERATION.test(value.get("generation") || "") ||
      value.get("source_device") !== snapshot.device ||
      value.get("profile_id") !== "native-recovery-default" ||
      !HASH.test(value.get("archive_sha256") || "") ||
      value.get("source_destination") !== destination ||
      !Number.isFinite(Date.parse(value.get("restored_at") || ""))) {
    fail("off-device profile restore receipt is invalid");
  }
  return {
    file_sha256: sha256(receipt.raw),
    generation: value.get("generation"),
    archive_sha256: value.get("archive_sha256"),
  };
}

async function writeExclusive(file, value) {
  const output = path.resolve(file);
  const parent = path.dirname(output);
  const parentStat = await fsp.lstat(parent);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink() ||
      (parentStat.mode & 0o077) !== 0) {
    fail("output parent must be a private real directory");
  }
  await fsp.writeFile(output, `${JSON.stringify(value, null, 2)}\n`,
    {mode: 0o600, flag: "wx"});
  return output;
}

export async function verifyRestore({kind, device, destination, snapshot,
  browserReceipt, profileReceipt, artifact, output}) {
  const admitted = await verifySnapshot(snapshot, kind, device);
  const browser = await verifyBrowserReceipt(browserReceipt, admitted);
  const profile = await verifyProfileRestore(profileReceipt, admitted, destination);
  const browserArtifact = await regularPath(
    artifact, "native recovery browser artifact", 16 * 1024 * 1024 * 1024);
  const result = {
    schema_version: 1,
    result: "passed",
    mechanism: "browser-native-neutral",
    device,
    kind,
    source_destination: destination,
    generation: profile.generation,
    archive_sha256: profile.archive_sha256,
    artifact_sha256: await sha256File(browserArtifact.resolved),
    snapshot_sha256: admitted.file_sha256,
    records_sha256: admitted.records_sha256,
    restored_state_sha256: admitted.state_sha256,
    restored_count: admitted.count,
    browser_api: browser.api,
    browser_receipt_sha256: browser.file_sha256,
    profile_restore_receipt_sha256: profile.file_sha256,
    verified_at: new Date().toISOString(),
  };
  await writeExclusive(output, result);
  return result;
}

async function readRecoveryEvidence(file, label) {
  const evidence = await privateJSON(file, label, 1024 * 1024);
  exactKeys(evidence.value, [
    "schema_version", "result", "mechanism", "device", "kind",
    "source_destination", "generation", "archive_sha256", "artifact_sha256",
    "snapshot_sha256",
    "records_sha256", "restored_state_sha256", "restored_count", "browser_api",
    "browser_receipt_sha256", "profile_restore_receipt_sha256", "verified_at",
  ], label);
  if (evidence.value.schema_version !== 1 || evidence.value.result !== "passed" ||
      evidence.value.mechanism !== "browser-native-neutral" ||
      !DEVICES.has(evidence.value.device) || !KINDS.has(evidence.value.kind) ||
      !GENERATION.test(evidence.value.generation || "") ||
      !HASH.test(evidence.value.archive_sha256 || "") ||
      !HASH.test(evidence.value.artifact_sha256 || "") ||
      !HASH.test(evidence.value.snapshot_sha256 || "") ||
      !HASH.test(evidence.value.records_sha256 || "") ||
      !HASH.test(evidence.value.restored_state_sha256 || "") ||
      !HASH.test(evidence.value.browser_receipt_sha256 || "") ||
      !HASH.test(evidence.value.profile_restore_receipt_sha256 || "") ||
      !Number.isInteger(evidence.value.restored_count) ||
      evidence.value.restored_count < 0 ||
      !Number.isFinite(Date.parse(evidence.value.verified_at))) {
    fail(`${label} is invalid`);
  }
  return {...evidence.value, evidence_sha256: sha256(evidence.raw)};
}

export async function finalizeDevice(device, inputs, output) {
  if (!new Set(["d", "da", "oneplus"]).has(device)) fail("device is invalid");
  const peer = device === "d" ? "da-copy" : device === "da" ? "d-copy" : "da-copy";
  const evidence = [];
  for (const kind of ["passwords", "cookies"]) {
    for (const destination of ["nas-on-lm", peer]) {
      const key = `${kind}_${destination === "nas-on-lm" ? "nas" : "peer"}`;
      const item = await readRecoveryEvidence(inputs[key], key);
      if (item.device !== device || item.kind !== kind ||
          item.source_destination !== destination) {
        fail(`${key} belongs to the wrong recovery path`);
      }
      evidence.push(item);
    }
  }
  const generations = new Set(evidence.map(item => item.generation));
  const archiveHashes = new Set(evidence.map(item => item.archive_sha256));
  const artifactHashes = new Set(evidence.map(item => item.artifact_sha256));
  if (generations.size !== 1 || archiveHashes.size !== 1 ||
      artifactHashes.size !== 1) {
    fail("native password/cookie recovery evidence does not use one exact archive generation");
  }
  for (const kind of ["passwords", "cookies"]) {
    const pair = evidence.filter(item => item.kind === kind);
    for (const field of ["snapshot_sha256", "records_sha256",
      "restored_state_sha256", "restored_count", "browser_api"]) {
      if (pair[0][field] !== pair[1][field]) {
        fail(`${kind} NAS and peer restores disagree on ${field}`);
      }
    }
  }
  const result = {
    schema_version: 1,
    result: "passed",
    mechanism: "browser-native-neutral",
    device,
    generation: evidence[0].generation,
    archive_sha256: evidence[0].archive_sha256,
    artifact_sha256: evidence[0].artifact_sha256,
    destinations: ["nas-on-lm", peer],
    passwords_state_sha256: evidence[0].restored_state_sha256,
    cookies_state_sha256: evidence[2].restored_state_sha256,
    evidence_sha256: evidence.map(item => item.evidence_sha256),
    verified_at: new Date().toISOString(),
  };
  await writeExclusive(output, result);
  return result;
}

export async function auditDeviceFinal(file, expectedDevice) {
  const receipt = await privateJSON(
    file, `${expectedDevice} native recovery final receipt`, 1024 * 1024);
  exactKeys(receipt.value, [
    "schema_version", "result", "mechanism", "device", "generation",
    "archive_sha256", "artifact_sha256", "destinations",
    "passwords_state_sha256", "cookies_state_sha256", "evidence_sha256",
    "verified_at",
  ], `${expectedDevice} native recovery final receipt`);
  const peer = expectedDevice === "d" ? "da-copy" :
    expectedDevice === "da" ? "d-copy" :
    expectedDevice === "oneplus" ? "da-copy" : "";
  if (receipt.value.schema_version !== 1 || receipt.value.result !== "passed" ||
      receipt.value.mechanism !== "browser-native-neutral" ||
      receipt.value.device !== expectedDevice || !peer ||
      !GENERATION.test(receipt.value.generation || "") ||
      !HASH.test(receipt.value.archive_sha256 || "") ||
      !HASH.test(receipt.value.artifact_sha256 || "") ||
      !HASH.test(receipt.value.passwords_state_sha256 || "") ||
      !HASH.test(receipt.value.cookies_state_sha256 || "") ||
      JSON.stringify(receipt.value.destinations) !==
        JSON.stringify(["nas-on-lm", peer]) ||
      !Array.isArray(receipt.value.evidence_sha256) ||
      receipt.value.evidence_sha256.length !== 4 ||
      receipt.value.evidence_sha256.some(value => !HASH.test(value)) ||
      new Set(receipt.value.evidence_sha256).size !== 4 ||
      !Number.isFinite(Date.parse(receipt.value.verified_at))) {
    fail(`${expectedDevice} native recovery final receipt is invalid`);
  }
  return {
    ...receipt.value,
    receipt_sha256: sha256(receipt.raw),
  };
}

function parseArgs(args) {
  const result = {};
  for (let index = 0; index < args.length; index += 2) {
    if (!args[index]?.startsWith("--") || index + 1 >= args.length) {
      fail("arguments must be --name value pairs");
    }
    const key = args[index].slice(2);
    if (result[key] !== undefined) fail(`duplicate argument: --${key}`);
    result[key] = args[index + 1];
  }
  return result;
}

async function main(argv) {
  const command = argv[0];
  const args = parseArgs(argv.slice(1));
  if (command === "verify-snapshot") {
    if (!args.kind || !args.snapshot || Object.keys(args).length > 4) {
      fail("usage: acceptance.mjs verify-snapshot --kind passwords|cookies --snapshot FILE [--device DEVICE] [--max-age-seconds 600]");
    }
    const maxAge = args["max-age-seconds"] === undefined
      ? undefined : Number(args["max-age-seconds"]);
    const result = await verifySnapshot(
      args.snapshot, args.kind, args.device, maxAge);
    process.stdout.write(`snapshot=verified\nkind=${result.kind}\ndevice=${result.device}\ncount=${result.count}\nsnapshot_sha256=${result.file_sha256}\n`);
    return;
  }
  if (command === "verify-restore") {
    for (const name of ["kind", "device", "destination", "snapshot",
      "browser-receipt", "profile-receipt", "artifact", "output"]) {
      if (!args[name]) fail(`missing --${name}`);
    }
    if (Object.keys(args).length !== 8) fail("unexpected verify-restore argument");
    const result = await verifyRestore({
      kind: args.kind, device: args.device, destination: args.destination,
      snapshot: args.snapshot, browserReceipt: args["browser-receipt"],
      profileReceipt: args["profile-receipt"], artifact: args.artifact,
      output: args.output,
    });
    process.stdout.write(`restore=verified\nkind=${result.kind}\ndevice=${result.device}\ndestination=${result.source_destination}\ngeneration=${result.generation}\n`);
    return;
  }
  if (command === "finalize-device") {
    for (const name of ["device", "passwords-nas", "passwords-peer",
      "cookies-nas", "cookies-peer", "output"]) {
      if (!args[name]) fail(`missing --${name}`);
    }
    if (Object.keys(args).length !== 6) fail("unexpected finalize-device argument");
    const result = await finalizeDevice(args.device, {
      passwords_nas: args["passwords-nas"],
      passwords_peer: args["passwords-peer"],
      cookies_nas: args["cookies-nas"],
      cookies_peer: args["cookies-peer"],
    }, args.output);
    process.stdout.write(`native_recovery=verified\ndevice=${result.device}\ngeneration=${result.generation}\n`);
    return;
  }
  fail("usage: acceptance.mjs <verify-snapshot|verify-restore|finalize-device> [options]");
}

if (process.argv[1] &&
    path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(error => {
    console.error(`helium native recovery acceptance: ${error.message}`);
    process.exitCode = 1;
  });
}
