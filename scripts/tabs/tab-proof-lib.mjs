#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const DEVICES = new Set(["d", "da", "oneplus"]);
export const MECHANISMS = new Set([
  "chromium-native-session",
  "neutral-topology",
  "full-profile",
]);
export const EVIDENCE_MARKER = ".helium-tab-runtime-evidence-root-v1";
export const EVIDENCE_MARKER_CONTENT =
  "helium-tab-runtime-evidence-root-v1\n";
export const EVIDENCE_DIRECTORY_MARKER =
  ".helium-tab-runtime-evidence-v1";
export const EVIDENCE_DIRECTORY_MARKER_CONTENT =
  "helium-tab-runtime-evidence-v1\n";
export const HEALTH_MARKER = ".helium-tab-health-root-v1";
export const HEALTH_MARKER_CONTENT = "helium-tab-health-root-v1\n";
export const NATIVE_ROOT_MARKER = ".helium-tab-runtime-proof-root-v1";
export const NATIVE_ROOT_MARKER_CONTENT =
  "helium-tab-runtime-proof-root-v1\n";

const phaseNames = new Map([
  ["chromium-native-session", [
    "initial-created",
    "clean-restart",
    "crash-restart",
    "second-restart",
  ]],
  ["neutral-topology", ["first-import", "second-restart"]],
  ["full-profile", ["first-restore-start", "second-restart"]],
]);

export function fail(message) {
  throw new Error(message);
}

export function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length ||
      actual.some((key, index) => key !== expected[index])) {
    fail(`${label} has an invalid field set`);
  }
}

export function validSlug(value, label = "slug") {
  if (typeof value !== "string" ||
      !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(value)) {
    fail(`${label} is invalid`);
  }
  return value;
}

export function validDevice(value) {
  if (!DEVICES.has(value)) {
    fail("source device must be d, da, or oneplus");
  }
  return value;
}

export function validSHA256(value, label = "SHA-256") {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) {
    fail(`${label} is invalid`);
  }
  return value;
}

export function sha256(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

export async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  await new Promise((resolve, reject) => {
    const stream = fs.createReadStream(file);
    stream.on("data", chunk => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", resolve);
  });
  return hash.digest("hex");
}

export function requireAbsolute(value, label) {
  if (typeof value !== "string" || !path.isAbsolute(value) ||
      path.normalize(value) !== value) {
    fail(`${label} must be an absolute normalized path`);
  }
  return value;
}

function requireOwned(stat, label) {
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    fail(`${label} must be owned by the current user`);
  }
}

export function requirePrivateDirectory(directory, label = "directory") {
  requireAbsolute(directory, label);
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail(`${label} must be a real directory`);
  }
  requireOwned(stat, label);
  if ((stat.mode & 0o077) !== 0) {
    fail(`${label} must not be accessible by group or other users`);
  }
  if (fs.realpathSync(directory) !== directory) {
    fail(`${label} must not traverse symlinks`);
  }
  return stat;
}

export function requirePrivateFile(file, label = "file", maximum = 1024 * 1024) {
  requireAbsolute(file, label);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`${label} must be a real regular file`);
  }
  requireOwned(stat, label);
  if ((stat.mode & 0o077) !== 0) {
    fail(`${label} must not be accessible by group or other users`);
  }
  if (stat.size < 1 || stat.size > maximum) {
    fail(`${label} has an invalid size`);
  }
  if (fs.realpathSync(file) !== file) {
    fail(`${label} must not traverse symlinks`);
  }
  return stat;
}

export function requireMarker(directory, name, content, label) {
  requirePrivateDirectory(directory, label);
  const marker = path.join(directory, name);
  if (!fs.existsSync(marker)) {
    fail(`${label} marker is missing`);
  }
  requirePrivateFile(marker, `${label} marker`, 256);
  if (fs.readFileSync(marker, "utf8") !== content) {
    fail(`${label} marker is invalid`);
  }
}

export function createMarkedRoot(directory, marker, content, label) {
  requireAbsolute(directory, label);
  if (fs.existsSync(directory)) {
    fail(`${label} already exists`);
  }
  const parent = path.dirname(directory);
  requirePrivateDirectory(parent, `${label} parent`);
  fs.mkdirSync(directory, {mode: 0o700});
  try {
    const markerPath = path.join(directory, marker);
    const descriptor = fs.openSync(markerPath,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
      0o600);
    try {
      fs.writeFileSync(descriptor, content);
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }
    fsyncDirectory(directory);
    fsyncDirectory(parent);
  } catch (error) {
    fs.rmSync(directory, {recursive: true});
    throw error;
  }
}

export function readPrivateJSON(file, label, maximum = 1024 * 1024) {
  requirePrivateFile(file, label, maximum);
  const raw = fs.readFileSync(file);
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    fail(`${label} is not valid JSON`);
  }
  return {raw, value};
}

export function readPrivateEnv(file, allowedKeys, label) {
  requirePrivateFile(file, label, 64 * 1024);
  const fields = new Map();
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (line === "") {
      continue;
    }
    const separator = line.indexOf("=");
    if (separator < 1) {
      fail(`${label} contains an invalid line`);
    }
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (!allowedKeys.has(key) || fields.has(key) || value === "" ||
        /[\r\n\0]/.test(value)) {
      fail(`${label} contains an invalid field`);
    }
    fields.set(key, value);
  }
  if (fields.size !== allowedKeys.size) {
    fail(`${label} is incomplete`);
  }
  return fields;
}

export function fsyncDirectory(directory) {
  const descriptor = fs.openSync(directory, fs.constants.O_RDONLY);
  try {
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

export function atomicWrite(file, raw, mode = 0o600) {
  const directory = path.dirname(file);
  requirePrivateDirectory(directory, "atomic write parent");
  if (fs.existsSync(file)) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      fail("atomic write target is unsafe");
    }
    requireOwned(stat, "atomic write target");
    if ((stat.mode & 0o077) !== 0) {
      fail("atomic write target has unsafe permissions");
    }
  }
  const temporary = path.join(directory,
    `.${path.basename(file)}.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  const descriptor = fs.openSync(temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    mode);
  try {
    fs.writeFileSync(descriptor, raw);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  try {
    fs.renameSync(temporary, file);
    fsyncDirectory(directory);
  } catch (error) {
    fs.rmSync(temporary, {force: true});
    throw error;
  }
}

export function loadSigningKey(file) {
  requirePrivateFile(file, "signing key", 256);
  const raw = fs.readFileSync(file, "utf8");
  if (!/^[a-f0-9]{64}\n$/.test(raw)) {
    fail("signing key must contain exactly 32 lowercase-hex bytes");
  }
  return Buffer.from(raw.trim(), "hex");
}

export function hmac(raw, key) {
  return crypto.createHmac("sha256", key).update(raw).digest("hex");
}

export function normalizeTopology(value, label = "topology") {
  exactKeys(value, ["schema_version", "windows"], label);
  if (value.schema_version !== 1 || !Array.isArray(value.windows) ||
      value.windows.length < 1 || value.windows.length > 64) {
    fail(`${label} has invalid windows`);
  }
  const windows = value.windows.map((window, windowIndex) => {
    exactKeys(window, ["urls"], `${label} window`);
    if (!Array.isArray(window.urls) || window.urls.length < 1 ||
        window.urls.length > 2000) {
      fail(`${label} window has invalid tabs`);
    }
    const urls = window.urls.map((url, tabIndex) => {
      if (typeof url !== "string" || url.length < 1 || url.length > 8192) {
        fail(`${label} URL ${windowIndex}:${tabIndex} is invalid`);
      }
      let parsed;
      try {
        parsed = new URL(url);
      } catch {
        fail(`${label} contains an invalid URL`);
      }
      if (parsed.protocol === "") {
        fail(`${label} contains a URL without a scheme`);
      }
      return url;
    }).sort();
    return {urls};
  }).sort((left, right) =>
    JSON.stringify(left.urls).localeCompare(JSON.stringify(right.urls)));
  const tabCount = windows.reduce((count, window) => count + window.urls.length, 0);
  return {
    schema_version: 1,
    validation: "cdp-window-url-multiset-v1",
    window_count: windows.length,
    tab_count: tabCount,
    windows,
  };
}

export function topologyDigest(topology) {
  return sha256(Buffer.from(`${JSON.stringify(topology)}\n`));
}

function validateTopologyRecord(value, label) {
  exactKeys(value, [
    "schema_version",
    "validation",
    "window_count",
    "tab_count",
    "windows",
  ], label);
  if (value.schema_version !== 1 ||
      value.validation !== "cdp-window-url-multiset-v1") {
    fail(`${label} has an invalid schema or validation`);
  }
  const normalized = normalizeTopology({
    schema_version: value.schema_version,
    windows: value.windows,
  }, label);
  if (value.window_count !== normalized.window_count ||
      value.tab_count !== normalized.tab_count ||
      JSON.stringify(value.windows) !== JSON.stringify(normalized.windows)) {
    fail(`${label} is not canonical`);
  }
  return normalized;
}

export function validateEvidence(value) {
  exactKeys(value, [
    "schema_version",
    "evidence_type",
    "mechanism",
    "state",
    "platform",
    "package_id",
    "source_device",
    "profile",
    "generation",
    "completed_unix",
    "browser",
    "disposable_profile",
    "source_binding",
    "expected_topology",
    "steps",
  ], "runtime evidence");
  if (value.schema_version !== 1 ||
      value.evidence_type !== "helium-tab-runtime-proof-v1" ||
      value.state !== "healthy" || value.platform !== "desktop" ||
      value.package_id !== "desktop" || !MECHANISMS.has(value.mechanism)) {
    fail("runtime evidence identity is invalid");
  }
  validDevice(value.source_device);
  validSlug(value.profile, "profile");
  if (typeof value.generation !== "string" || value.generation.length < 1 ||
      value.generation.length > 256 || /[\r\n\0]/.test(value.generation)) {
    fail("runtime evidence generation is invalid");
  }
  if (!Number.isSafeInteger(value.completed_unix) ||
      value.completed_unix < 1 ||
      value.completed_unix > Math.floor(Date.now() / 1000)) {
    fail("runtime evidence completion time is invalid");
  }
  exactKeys(value.browser, [
    "path",
    "sha256",
    "size",
    "product",
    "revision",
    "protocol_version",
    "user_agent",
    "js_version",
    "display_mode",
  ], "browser evidence");
  requireAbsolute(value.browser.path, "browser evidence path");
  validSHA256(value.browser.sha256, "browser evidence SHA-256");
  if (!Number.isSafeInteger(value.browser.size) || value.browser.size < 1 ||
      typeof value.browser.product !== "string" ||
      typeof value.browser.revision !== "string" ||
      typeof value.browser.protocol_version !== "string" ||
      typeof value.browser.user_agent !== "string" ||
      typeof value.browser.js_version !== "string" ||
      !["headless", "headed"].includes(value.browser.display_mode)) {
    fail("browser evidence is invalid");
  }
  exactKeys(value.disposable_profile, ["path", "marker"],
    "disposable profile evidence");
  requireAbsolute(value.disposable_profile.path, "disposable profile path");
  if (typeof value.disposable_profile.marker !== "string" ||
      value.disposable_profile.marker.length < 1) {
    fail("disposable profile marker is invalid");
  }
  const expected = validateTopologyRecord(value.expected_topology,
    "expected topology");
  const expectedDigest = topologyDigest(expected);
  if (!Array.isArray(value.steps)) {
    fail("runtime evidence steps are invalid");
  }
  const expectedPhases = phaseNames.get(value.mechanism);
  if (value.steps.length !== expectedPhases.length) {
    fail("runtime evidence has an invalid step count");
  }
  for (let index = 0; index < value.steps.length; index += 1) {
    const step = value.steps[index];
    exactKeys(step, [
      "name",
      "completed_unix",
      "topology_sha256",
      "window_count",
      "tab_count",
      "browser_exit",
    ], "runtime evidence step");
    if (step.name !== expectedPhases[index] ||
        !Number.isSafeInteger(step.completed_unix) ||
        step.completed_unix < 1 ||
        step.completed_unix > value.completed_unix ||
        step.topology_sha256 !== expectedDigest ||
        step.window_count !== expected.window_count ||
        step.tab_count !== expected.tab_count ||
        !["clean", "crash"].includes(step.browser_exit)) {
      fail("runtime evidence step is invalid");
    }
  }
  const expectedExits = value.mechanism === "chromium-native-session"
    ? ["clean", "crash", "clean", "clean"]
    : ["clean", "clean"];
  if (value.steps.some((step, index) => step.browser_exit !== expectedExits[index])) {
    fail("runtime evidence exit sequence is invalid");
  }

  if (value.mechanism === "chromium-native-session") {
    exactKeys(value.source_binding, ["fixture_sha256", "fixture_origin"],
      "native source binding");
    validSHA256(value.source_binding.fixture_sha256, "fixture SHA-256");
    const origin = new URL(value.source_binding.fixture_origin);
    if (origin.protocol !== "http:" ||
        !["127.0.0.1", "[::1]"].includes(origin.hostname)) {
      fail("native fixture must be loopback HTTP");
    }
  } else if (value.mechanism === "neutral-topology") {
    exactKeys(value.source_binding, [
      "source_generation",
      "source_session_sha256",
      "source_destination",
      "archive_sha256",
      "backup_manifest_sha256",
      "source_receipt_sha256",
      "native_receipt_sha256",
      "native_validation",
    ], "neutral source binding");
    if (value.source_binding.source_generation !== value.generation) {
      fail("neutral generation mismatch");
    }
    validSHA256(value.source_binding.source_session_sha256,
      "neutral session SHA-256");
    validSlug(value.source_binding.source_destination,
      "neutral source destination");
    validSHA256(value.source_binding.archive_sha256,
      "neutral archive SHA-256");
    validSHA256(value.source_binding.backup_manifest_sha256,
      "neutral backup manifest SHA-256");
    validSHA256(value.source_binding.source_receipt_sha256,
      "neutral source receipt SHA-256");
    validSHA256(value.source_binding.native_receipt_sha256,
      "neutral receipt SHA-256");
    if (value.source_binding.native_validation !==
        "exact-supported-live-topology") {
      fail("neutral native validation is invalid");
    }
  } else {
    exactKeys(value.source_binding, [
      "generation",
      "source_destination",
      "archive_sha256",
      "restore_receipt_sha256",
      "expected_evidence_sha256",
    ], "full-profile source binding");
    if (value.source_binding.generation !== value.generation) {
      fail("full-profile generation mismatch");
    }
    validSlug(value.source_binding.source_destination,
      "full-profile source destination");
    validSHA256(value.source_binding.archive_sha256,
      "full-profile archive SHA-256");
    validSHA256(value.source_binding.restore_receipt_sha256,
      "full-profile receipt SHA-256");
    validSHA256(value.source_binding.expected_evidence_sha256,
      "full-profile expected evidence SHA-256");
  }
  return value;
}

export function readAuthenticatedEvidence(directory, key) {
  requireMarker(directory, EVIDENCE_DIRECTORY_MARKER,
    EVIDENCE_DIRECTORY_MARKER_CONTENT, "runtime evidence directory");
  const entries = fs.readdirSync(directory).sort();
  const expectedEntries = [
    EVIDENCE_DIRECTORY_MARKER,
    "evidence.hmac",
    "evidence.json",
  ].sort();
  if (JSON.stringify(entries) !== JSON.stringify(expectedEntries)) {
    fail("runtime evidence directory inventory is invalid");
  }
  const evidencePath = path.join(directory, "evidence.json");
  const signaturePath = path.join(directory, "evidence.hmac");
  const {raw, value} = readPrivateJSON(evidencePath, "runtime evidence");
  requirePrivateFile(signaturePath, "runtime evidence signature", 128);
  const signatureRaw = fs.readFileSync(signaturePath, "utf8");
  if (!/^[a-f0-9]{64}\n$/.test(signatureRaw)) {
    fail("runtime evidence signature is invalid");
  }
  const expected = Buffer.from(hmac(raw, key), "hex");
  const actual = Buffer.from(signatureRaw.trim(), "hex");
  if (expected.length !== actual.length ||
      !crypto.timingSafeEqual(expected, actual)) {
    fail("runtime evidence authentication failed");
  }
  validateEvidence(value);
  return {raw, value, sha256: sha256(raw)};
}
