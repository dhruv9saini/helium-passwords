#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {
  capturePhysicalDeviceIdentity,
  parsePhysicalDeviceIdentityEnv,
  physicalIdentityEnv,
} from
  "../android-acceptance/physical-device-identity.mjs";
import {summarizePasswordState, summarizeJournal} from
  "../password-runtime/sync-acceptance.mjs";
import {
  captureLinuxHostIdentity,
  linuxHostIdentityEnv,
  parseLinuxHostIdentityEnv,
} from "./execution-identity.mjs";

const DEVICES = new Set(["d", "da", "oneplus"]);
const HASH = /^[0-9a-f]{64}$/;
const DEVICE_FILES = Object.freeze([
  "identity.env",
  "client-initial.json", "client-restart.json", "client-terminal.json",
  "password-initial.json", "password-restart.json", "password-terminal.json",
  "cookie-initial.json", "cookie-restart.json", "cookie-terminal.json",
  "journal-initial.jsonl", "journal-restart.jsonl",
  "authenticated-requests.jsonl", "browser.log", "capture.env",
]);
const SERVER_FILES = Object.freeze([
  "records.jsonl", "server.log", "password-conflict.json",
  "cookie-conflict.json", "capture.env",
]);

function fail(message) {
  throw new Error(message);
}

function equal(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sha256(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !equal(Object.keys(value).sort(), [...keys].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
}

function int64(value, label, positive = false) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    fail(`${label} must be an int64 string`);
  }
  const parsed = BigInt(value);
  if (parsed > 9223372036854775807n || (positive && parsed === 0n)) {
    fail(`${label} is outside its admitted range`);
  }
  return parsed;
}

function requireTailnetHTTP(value, label) {
  let endpoint;
  try { endpoint = new URL(value); } catch { fail(`${label} must be an exact URL`); }
  const parts = endpoint.hostname.split(".");
  const octets = parts.map(Number);
  const tailnetIPv4 = octets.length === 4 && octets.every((octet, index) =>
    Number.isInteger(octet) && octet >= 0 && octet <= 255 &&
    String(octet) === parts[index]) && octets[0] === 100 &&
    octets[1] >= 64 && octets[1] <= 127;
  if (endpoint.protocol !== "http:" || !tailnetIPv4 ||
      endpoint.port !== "44719" || endpoint.pathname !== "/" ||
      endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    fail(`${label} must be literal private-Tailnet HTTP port 44719`);
  }
  return endpoint.href;
}

async function regularFile(file, label, maximum = 64 * 1024 * 1024) {
  const resolved = path.resolve(file);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
      stat.size > maximum) {
    fail(`${label} must be a nonempty regular file within its size limit`);
  }
  return {resolved, stat, raw: await fsp.readFile(resolved)};
}

async function readJSON(file, label) {
  const admitted = await regularFile(file, label);
  try {
    return {...admitted, value: JSON.parse(admitted.raw)};
  } catch {
    fail(`${label} is not valid JSON`);
  }
}

function parseEnv(raw, label) {
  const result = new Map();
  for (const line of raw.toString("utf8").split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (separator < 1 || !value || result.has(key) || /[\r\n\0]/.test(value)) {
      fail(`${label} is malformed`);
    }
    result.set(key, value);
  }
  return result;
}

async function auditBundle(directory, expectedFiles, kind) {
  const root = path.resolve(directory);
  const stat = await fsp.lstat(root);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      await fsp.realpath(root) !== root || (stat.mode & 0o077) !== 0) {
    fail(`${kind} evidence must be a private canonical directory`);
  }
  const entries = await fsp.readdir(root, {withFileTypes: true});
  if (entries.some(entry => !entry.isFile() || entry.isSymbolicLink())) {
    fail(`${kind} evidence contains a non-file entry`);
  }
  const actual = entries.map(entry => entry.name).sort();
  const expected = [...expectedFiles, "EVIDENCE_SHA256SUMS"].sort();
  if (!equal(actual, expected)) fail(`${kind} evidence inventory is invalid`);
  const inventory = await regularFile(path.join(root, "EVIDENCE_SHA256SUMS"),
    `${kind} evidence checksum inventory`, 1024 * 1024);
  if ((inventory.stat.mode & 0o077) !== 0) {
    fail(`${kind} evidence checksum inventory must be private`);
  }
  const recorded = new Map();
  for (const line of inventory.raw.toString("utf8").split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
    if (!match || recorded.has(match[2]) ||
        !expectedFiles.includes(match[2])) {
      fail(`${kind} evidence checksum inventory is malformed`);
    }
    recorded.set(match[2], match[1]);
  }
  if (!equal([...recorded.keys()].sort(), [...expectedFiles].sort())) {
    fail(`${kind} evidence checksum inventory is incomplete`);
  }
  const files = new Map();
  for (const name of expectedFiles) {
    const file = await regularFile(path.join(root, name), `${kind} ${name}`);
    if ((file.stat.mode & 0o077) !== 0) {
      fail(`${kind} evidence file must be private: ${name}`);
    }
    if (sha256(file.raw) !== recorded.get(name)) {
      fail(`${kind} evidence changed after capture: ${name}`);
    }
    files.set(name, file);
  }
  return {root, files, inventory_sha256: sha256(inventory.raw)};
}

function parseClient(raw, expectedDevice, label) {
  const value = JSON.parse(raw);
  exactKeys(value, [
    "version", "device_id", "role", "phase", "revisions", "sequence",
  ], label);
  const expectedRole = expectedDevice === "d" ? "seed" : "join";
  if (value.version !== 2 || value.device_id !== expectedDevice ||
      value.role !== expectedRole || value.phase !== "active" ||
      !value.revisions || typeof value.revisions !== "object" ||
      Array.isArray(value.revisions)) {
    fail(`${label} enrollment identity is invalid`);
  }
  int64(value.sequence, `${label} sequence`);
  for (const [identity, revision] of Object.entries(value.revisions)) {
    if (!identity || !identity.includes("\0")) fail(`${label} revision key is invalid`);
    int64(revision, `${label} ${identity} revision`);
  }
  return value;
}

function parseCookieState(raw, label) {
  const value = JSON.parse(raw);
  exactKeys(value, [
    "schema_version", "verified_sequence", "blocked_reason", "records",
  ], label);
  if (value.schema_version !== 5 || value.blocked_reason !== "" ||
      !value.records || typeof value.records !== "object" ||
      Array.isArray(value.records)) {
    fail(`${label} is not an unblocked schema-5 bridge state`);
  }
  int64(value.verified_sequence, `${label} verified sequence`);
  for (const [key, record] of Object.entries(value.records)) {
    if (!HASH.test(key)) fail(`${label} has an invalid canonical cookie key`);
    const allowed = [
      "remote_revision", "device_id", "remote_payload_fingerprint",
      "baseline_cookie_fingerprint", "remote_deleted", "destination_exception",
      "pending_publish",
    ];
    if (!record || typeof record !== "object" || Array.isArray(record) ||
        Object.keys(record).some(field => !allowed.includes(field)) ||
        !Object.hasOwn(record, "remote_revision") ||
        !Object.hasOwn(record, "device_id") ||
        !Object.hasOwn(record, "remote_payload_fingerprint") ||
        !Object.hasOwn(record, "baseline_cookie_fingerprint") ||
        !Object.hasOwn(record, "remote_deleted")) {
      fail(`${label} cookie record shape is invalid`);
    }
    int64(record.remote_revision, `${label} cookie revision`, true);
    if (!DEVICES.has(record.device_id) ||
        !(HASH.test(record.remote_payload_fingerprint) ||
          record.remote_payload_fingerprint === "deleted") ||
        !(HASH.test(record.baseline_cookie_fingerprint) ||
          record.baseline_cookie_fingerprint === "deleted") ||
        typeof record.remote_deleted !== "boolean" ||
        Object.hasOwn(record, "pending_publish")) {
      fail(`${label} cookie record is unverified or pending`);
    }
  }
  return value;
}

function stateDigest(clientRaw, passwordRaw, cookieRaw) {
  return sha256(Buffer.concat([
    clientRaw, Buffer.from([0]), passwordRaw, Buffer.from([0]), cookieRaw,
  ]));
}

function parseJournal(raw, label) {
  const records = [];
  for (const [index, line] of raw.toString("utf8").split("\n").entries()) {
    if (!line) continue;
    let record;
    try { record = JSON.parse(line); } catch { fail(`${label} line is invalid JSON`); }
    exactKeys(record, [
      "seq", "kind", "key", "revision", "deleted", "device_id", "payload",
    ], `${label} line ${index + 1}`);
    int64(record.seq, `${label} sequence`, true);
    int64(record.revision, `${label} revision`, true);
    if (!new Set(["passwords", "cookies"]).has(record.kind) ||
        typeof record.key !== "string" || !record.key ||
        typeof record.deleted !== "boolean" || !DEVICES.has(record.device_id) ||
        !record.payload || typeof record.payload !== "object" ||
        Array.isArray(record.payload)) {
      fail(`${label} line ${index + 1} has invalid metadata`);
    }
    records.push(record);
  }
  if (!records.length || records.some((item, index) =>
    item.seq !== String(index + 1))) {
    fail(`${label} is empty, noncontiguous, or reordered`);
  }
  return records;
}

function parseRequests(raw, device) {
  const result = [];
  for (const [index, line] of raw.toString("utf8").split("\n").entries()) {
    if (!line) continue;
    let value;
    try { value = JSON.parse(line); } catch { fail("authenticated request receipt is invalid JSON"); }
    exactKeys(value, [
      "device", "origin", "response_status", "result", "evidence_ref",
      "evidence_sha256", "authorization_scheme", "authorization_sha256",
      "completed_at",
    ], `authenticated request ${index + 1}`);
    let origin;
    try { origin = new URL(value.origin); } catch { fail("authenticated request origin is invalid"); }
    if (value.device !== device || origin.protocol !== "https:" ||
        origin.origin !== value.origin || origin.pathname !== "/" ||
        value.response_status !== 200 || value.result !== "authenticated" ||
        value.authorization_scheme !== "Bearer" ||
        !HASH.test(value.authorization_sha256 || "") ||
        !/^[a-z0-9][a-z0-9._-]{0,127}$/.test(value.evidence_ref) ||
        !HASH.test(value.evidence_sha256) ||
        !Number.isFinite(Date.parse(value.completed_at))) {
      fail("authenticated request receipt is invalid");
    }
    result.push(value);
  }
  if ((device === "d" && result.length !== 0) ||
      (device !== "d" && result.length < 1)) {
    fail(`${device} authenticated request inventory is invalid`);
  }
  return result;
}

function assertSafeLog(raw, label) {
  const text = raw.toString("utf8");
  if (/authorization\s*:\s*bearer|bearer\s+[A-Za-z0-9+/=_-]{16,}|password\s*[=:]\s*\S+/i.test(text)) {
    fail(`${label} contains a bearer token or password value`);
  }
}

export async function auditDeviceRuntimeEvidence(directory, device,
  expectedIdentity) {
  if (!DEVICES.has(device)) fail("unknown fleet device");
  const bundle = await auditBundle(directory, DEVICE_FILES, `${device} runtime`);
  const capture = parseEnv(bundle.files.get("capture.env").raw,
    `${device} capture metadata`);
  if (!equal([...capture.keys()].sort(), [
    "schema_version", "device", "collector_sha256", "captured_at",
  ].sort()) || capture.get("schema_version") !== "1" ||
      capture.get("device") !== device ||
      !HASH.test(capture.get("collector_sha256") || "") ||
      !Number.isFinite(Date.parse(capture.get("captured_at") || ""))) {
    fail(`${device} capture metadata is invalid`);
  }
  const collectorSHA256 = await sha256File(fileURLToPath(import.meta.url));
  if (capture.get("collector_sha256") !== collectorSHA256) {
    fail(`${device} runtime evidence used a different collector`);
  }
  const identityRaw = bundle.files.get("identity.env").raw.toString("utf8");
  const identity = device === "oneplus"
    ? parsePhysicalDeviceIdentityEnv(identityRaw)
    : parseLinuxHostIdentityEnv(identityRaw, device);
  const identitySHA256 = device === "oneplus"
    ? identity.physical_identity_sha256 : identity.host_identity_sha256;
  const wantedIdentity = device === "oneplus"
    ? expectedIdentity.physical_identity_sha256
    : expectedIdentity.host_identity_sha256;
  if (identitySHA256 !== wantedIdentity) {
    fail(`${device} runtime evidence belongs to a different execution target`);
  }
  const phase = name => ({
    clientRaw: bundle.files.get(`client-${name}.json`).raw,
    passwordRaw: bundle.files.get(`password-${name}.json`).raw,
    cookieRaw: bundle.files.get(`cookie-${name}.json`).raw,
  });
  const initial = phase("initial");
  const restart = phase("restart");
  const terminal = phase("terminal");
  for (const [name, evidence] of Object.entries({initial, restart, terminal})) {
    evidence.client = parseClient(evidence.clientRaw, device,
      `${device} ${name} client state`);
    evidence.password = summarizePasswordState(JSON.parse(evidence.passwordRaw));
    evidence.cookie = parseCookieState(evidence.cookieRaw,
      `${device} ${name} CookieManager bridge state`);
    evidence.state_sha256 = stateDigest(evidence.clientRaw,
      evidence.passwordRaw, evidence.cookieRaw);
    if (evidence.cookie.verified_sequence !== evidence.client.sequence ||
        evidence.password.verified_sequence !== evidence.client.sequence) {
      fail(`${device} ${name} native bridge cursors disagree`);
    }
  }
  const journalInitial = bundle.files.get("journal-initial.jsonl");
  const journalRestart = bundle.files.get("journal-restart.jsonl");
  const initialRecords = parseJournal(journalInitial.raw,
    `${device} initial server journal`);
  parseJournal(journalRestart.raw, `${device} restart server journal`);
  if (!initial.clientRaw.equals(restart.clientRaw) ||
      !initial.passwordRaw.equals(restart.passwordRaw) ||
      !initial.cookieRaw.equals(restart.cookieRaw) ||
      !journalInitial.raw.equals(journalRestart.raw)) {
    fail(`${device} unchanged restart changed native bridge state or journal`);
  }
  if (initial.client.sequence !== initialRecords.at(-1).seq) {
    fail(`${device} initial cursor does not acknowledge its exact journal`);
  }
  const publications = kind => String(initialRecords.filter(record =>
    record.kind === kind && record.device_id === device).length);
  const requests = parseRequests(
    bundle.files.get("authenticated-requests.jsonl").raw, device);
  assertSafeLog(bundle.files.get("browser.log").raw, `${device} browser log`);
  return {
    root: bundle.root,
    bundle_sha256: bundle.inventory_sha256,
    identity,
    identity_sha256: identitySHA256,
    initial,
    restart,
    terminal,
    initial_journal_sha256: sha256(journalInitial.raw),
    restart_journal_sha256: sha256(journalRestart.raw),
    initial_publications: {
      passwords: publications("passwords"),
      cookies: publications("cookies"),
    },
    requests,
  };
}

function parseConflict(raw, expectedKind, expectedDevice, expectedEndpoint) {
  const value = JSON.parse(raw);
  exactKeys(value, [
    "schema_version", "device", "request", "response", "completed_at",
  ], `${expectedKind} conflict receipt`);
  exactKeys(value.request, [
    "kind", "key", "expected_revision", "deleted", "payload_sha256",
    "endpoint", "authorization_scheme", "authorization_sha256",
  ], `${expectedKind} conflict request`);
  exactKeys(value.response, ["http_status", "body"],
    `${expectedKind} conflict response`);
  exactKeys(value.response.body, [
    "code", "error", "kind", "key", "current_revision",
  ], `${expectedKind} conflict response body`);
  if (value.schema_version !== 1 || value.device !== expectedDevice ||
      value.request.kind !== expectedKind ||
      requireTailnetHTTP(value.request.endpoint,
        `${expectedKind} conflict endpoint`) !== expectedEndpoint ||
      value.request.authorization_scheme !== "Bearer" ||
      !HASH.test(value.request.authorization_sha256 || "") ||
      value.response.http_status !== 409 ||
      value.response.body.code !== "revision_conflict" ||
      value.response.body.kind !== expectedKind ||
      value.response.body.key !== value.request.key ||
      typeof value.request.key !== "string" || !value.request.key ||
      typeof value.request.deleted !== "boolean" ||
      !HASH.test(value.request.payload_sha256 || "") ||
      !Number.isFinite(Date.parse(value.completed_at))) {
    fail(`${expectedKind} conflict is not an exact authenticated 409 receipt`);
  }
  int64(value.request.expected_revision, `${expectedKind} expected revision`);
  int64(value.response.body.current_revision,
    `${expectedKind} current revision`, true);
  if (BigInt(value.response.body.current_revision) <=
      BigInt(value.request.expected_revision)) {
    fail(`${expectedKind} conflict does not reject a stale revision`);
  }
  const expectedError = `revision conflict for ${expectedKind}/${value.request.key}: expected ${value.request.expected_revision}, current ${value.response.body.current_revision}`;
  if (value.response.body.error !== expectedError) {
    fail(`${expectedKind} conflict error text does not match the rejected request`);
  }
  return value;
}

export async function auditServerRuntimeEvidence(directory) {
  const bundle = await auditBundle(directory, SERVER_FILES, "server runtime");
  const capture = parseEnv(bundle.files.get("capture.env").raw,
    "server capture metadata");
  if (!equal([...capture.keys()].sort(), [
    "schema_version", "endpoint", "collector_sha256", "captured_at",
  ].sort()) || capture.get("schema_version") !== "1" ||
      requireTailnetHTTP(capture.get("endpoint"), "server capture endpoint") !==
        capture.get("endpoint") ||
      capture.get("collector_sha256") !==
        await sha256File(fileURLToPath(import.meta.url)) ||
      !Number.isFinite(Date.parse(capture.get("captured_at") || ""))) {
    fail("server capture metadata is invalid");
  }
  const journal = bundle.files.get("records.jsonl");
  const records = parseJournal(journal.raw, "canonical server journal");
  assertSafeLog(bundle.files.get("server.log").raw, "canonical server log");
  const passwordConflict = parseConflict(
    bundle.files.get("password-conflict.json").raw, "passwords", "oneplus",
    capture.get("endpoint"));
  const cookieConflict = parseConflict(
    bundle.files.get("cookie-conflict.json").raw, "cookies", "oneplus",
    capture.get("endpoint"));
  if (Date.parse(passwordConflict.completed_at) >
        Date.parse(capture.get("captured_at")) ||
      Date.parse(cookieConflict.completed_at) >
        Date.parse(capture.get("captured_at"))) {
    fail("server conflict receipt chronology is invalid");
  }
  return {
    root: bundle.root,
    bundle_sha256: bundle.inventory_sha256,
    endpoint: capture.get("endpoint"),
    journal_sha256: sha256(journal.raw),
    records,
    max_sequence: records.at(-1).seq,
    password_conflict: passwordConflict,
    cookie_conflict: cookieConflict,
  };
}

async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function copyExclusive(source, destination) {
  const file = await regularFile(source, `runtime evidence input ${path.basename(destination)}`);
  await fsp.writeFile(destination, file.raw, {mode: 0o600, flag: "wx"});
}

async function capture(kind, options) {
  const output = path.resolve(options.get("--output") || "");
  const parent = path.dirname(output);
  const parentStat = await fsp.lstat(parent);
  if (!parentStat.isDirectory() || parentStat.isSymbolicLink() ||
      (parentStat.mode & 0o077) !== 0 || await fsp.realpath(parent) !== parent) {
    fail("runtime evidence output parent must be a private real directory");
  }
  try { await fsp.lstat(output); fail("runtime evidence output already exists"); }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  const expected = kind === "device" ? DEVICE_FILES : SERVER_FILES;
  const generated = new Set(["capture.env", ...(kind === "device" ? ["identity.env"] : [])]);
  const sourceNames = expected.filter(name => !generated.has(name));
  const optionName = name => `--${name.replaceAll(".", "-")}`;
  const allowed = new Set(["--output", ...sourceNames.map(optionName)]);
  if (kind === "device") {
    allowed.add("--device");
    if (options.get("--device") === "oneplus") allowed.add("--adb-serial");
  }
  if (kind === "server") allowed.add("--endpoint");
  if (!equal([...options.keys()].sort(), [...allowed].sort())) {
    fail(`${kind} capture options are incomplete or unexpected`);
  }
  const temporary = `${output}.incoming-${process.pid}-${crypto.randomUUID()}`;
  await fsp.mkdir(temporary, {mode: 0o700});
  try {
    for (const name of sourceNames) {
      await copyExclusive(options.get(optionName(name)), path.join(temporary, name));
    }
    if (kind === "device") {
      const device = options.get("--device");
      if (!DEVICES.has(device)) fail("device capture has an invalid fleet identity");
      const identityRaw = device === "oneplus"
        ? physicalIdentityEnv(capturePhysicalDeviceIdentity(
          options.get("--adb-serial")))
        : linuxHostIdentityEnv(captureLinuxHostIdentity(device));
      await fsp.writeFile(path.join(temporary, "identity.env"), identityRaw,
        {mode: 0o600, flag: "wx"});
    }
    const collectorSHA256 = await sha256File(fileURLToPath(import.meta.url));
    const captureLines = kind === "device"
      ? ["schema_version=1", `device=${options.get("--device")}`]
      : ["schema_version=1",
        `endpoint=${requireTailnetHTTP(options.get("--endpoint"), "server endpoint")}`];
    captureLines.push(`collector_sha256=${collectorSHA256}`,
      `captured_at=${new Date().toISOString()}`);
    await fsp.writeFile(path.join(temporary, "capture.env"),
      `${captureLines.join("\n")}\n`, {mode: 0o600, flag: "wx"});
    const sums = [];
    for (const name of expected) {
      sums.push(`${await sha256File(path.join(temporary, name))}  ${name}`);
    }
    await fsp.writeFile(path.join(temporary, "EVIDENCE_SHA256SUMS"),
      `${sums.join("\n")}\n`, {mode: 0o600, flag: "wx"});
    await fsp.rename(temporary, output);
  } catch (error) {
    await fsp.rm(temporary, {recursive: true, force: true});
    throw error;
  }
  return output;
}

function parseOptions(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    if (!key?.startsWith("--") || args[index + 1] === undefined ||
        values.has(key)) fail("options must be unique --name value pairs");
    values.set(key, args[index + 1]);
  }
  return values;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, ...args] = process.argv.slice(2);
    const kind = command === "capture-device" ? "device" :
      command === "capture-server" ? "server" : null;
    if (!kind) fail("usage: fleet-runtime-evidence.mjs capture-device|capture-server [exact file options] --output NEW-DIR");
    const output = await capture(kind, parseOptions(args));
    process.stdout.write(`${JSON.stringify({event: "captured", kind, output})}\n`);
  } catch (error) {
    process.stderr.write(`fleet runtime evidence: ${error.message}\n`);
    process.exitCode = 1;
  }
}
