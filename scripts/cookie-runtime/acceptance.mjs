#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const RUN_NONCE = /^[0-9a-f]{64}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const COOKIE_KEY = /^[0-9a-f]{64}$/;
const PNG_SIGNATURE = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
]);
const PNG_MAX_BYTES = 32 * 1024 * 1024;
const PNG_CRC_TABLE = Object.freeze(Array.from({length: 256}, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) {
    crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return crc >>> 0;
}));
const SCREENSHOTS = Object.freeze([
  "01-d-initial.png",
  "02-da-initial.png",
  "03-da-updated.png",
  "04-d-updated.png",
  "05-d-deleted.png",
  "06-da-deleted.png",
]);

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...keys].sort())) {
    fail(`${label} has an invalid field inventory`);
  }
}

async function regularFile(file, label, {privateFile = true} = {}) {
  if (!path.isAbsolute(file)) fail(`${label} path must be absolute`);
  const stat = await fsp.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || await fsp.realpath(file) !== file ||
      stat.size < 1 || (privateFile && (stat.mode & 0o077) !== 0)) {
    fail(`${label} must be a private nonempty regular file`);
  }
  return {stat, raw: await fsp.readFile(file)};
}

async function readJSON(file, label, options) {
  const result = await regularFile(file, label, options);
  try {
    return {...result, value: JSON.parse(result.raw)};
  } catch {
    fail(`${label} is not valid JSON`);
  }
}

async function validatePNG(file) {
  const {stat, raw} = await regularFile(file, "cookie UI screenshot");
  if (stat.size <= PNG_SIGNATURE.length || stat.size > PNG_MAX_BYTES ||
      !raw.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    fail("cookie UI screenshot is not a bounded PNG");
  }
  let offset = PNG_SIGNATURE.length;
  let chunks = 0;
  let sawData = false;
  let sawEnd = false;
  while (offset < raw.length) {
    if (raw.length - offset < 12) fail("cookie UI PNG chunk is truncated");
    const length = raw.readUInt32BE(offset);
    const typeOffset = offset + 4;
    const dataOffset = typeOffset + 4;
    const crcOffset = dataOffset + length;
    const next = crcOffset + 4;
    if (next > raw.length) fail("cookie UI PNG chunk exceeds the file");
    const type = raw.toString("ascii", typeOffset, dataOffset);
    if (!/^[A-Za-z]{4}$/.test(type)) fail("cookie UI PNG chunk type is invalid");
    let crc = 0xffffffff;
    for (let index = typeOffset; index < crcOffset; index += 1) {
      crc = PNG_CRC_TABLE[(crc ^ raw[index]) & 0xff] ^ (crc >>> 8);
    }
    if (((crc ^ 0xffffffff) >>> 0) !== raw.readUInt32BE(crcOffset)) {
      fail(`cookie UI PNG ${type} checksum is invalid`);
    }
    if (chunks === 0) {
      if (type !== "IHDR" || length !== 13 || raw.readUInt32BE(dataOffset) < 1 ||
          raw.readUInt32BE(dataOffset + 4) < 1) {
        fail("cookie UI PNG header is invalid");
      }
    } else if (type === "IHDR") {
      fail("cookie UI PNG contains a duplicate header");
    }
    if (type === "IDAT") sawData = true;
    if (type === "IEND") {
      if (length !== 0 || next !== raw.length) fail("cookie UI PNG end is invalid");
      sawEnd = true;
    }
    chunks += 1;
    offset = next;
  }
  if (!sawData || !sawEnd) fail("cookie UI PNG is incomplete");
  return {size: stat.size, sha256: sha256(raw)};
}

function parseCounter(value, label) {
  const text = typeof value === "number" && Number.isSafeInteger(value)
    ? String(value) : value;
  if (typeof text !== "string" || !/^(0|[1-9][0-9]*)$/.test(text)) {
    fail(`${label} is not a nonnegative integer`);
  }
  return BigInt(text);
}

function validateCookieState(state, label) {
  exactKeys(state, ["schema_version", "verified_sequence", "blocked_reason", "records"], label);
  if (state.schema_version !== 5 || state.blocked_reason !== "" ||
      !state.records || typeof state.records !== "object" || Array.isArray(state.records)) {
    fail(`${label} schema or blocked state is invalid`);
  }
  const entries = Object.entries(state.records);
  if (entries.length !== 1 || !COOKIE_KEY.test(entries[0][0])) {
    fail(`${label} must contain exactly one canonical cookie record`);
  }
  const [key, record] = entries[0];
  exactKeys(record, [
    "remote_revision", "device_id", "remote_payload_fingerprint",
    "baseline_cookie_fingerprint", "remote_deleted",
  ], `${label} cookie record`);
  if (parseCounter(record.remote_revision, `${label} remote revision`) !== 3n ||
      record.device_id !== "d-test" || record.remote_payload_fingerprint !== "deleted" ||
      record.baseline_cookie_fingerprint !== "deleted" || record.remote_deleted !== true) {
    fail(`${label} does not contain the terminal d tombstone`);
  }
  return {
    key,
    verifiedSequence: parseCounter(state.verified_sequence,
      `${label} verified sequence`),
  };
}

function validateFixture(value, runNonce) {
  exactKeys(value, [
    "schema_version", "evidence_type", "run_nonce", "completed_at",
    "fixture_origin", "cookie_contract", "value_fingerprints",
    "evidence_contains_cookie_values", "observations",
  ], "cookie fixture evidence");
  if (value.schema_version !== 1 ||
      value.evidence_type !== "helium-desktop-native-cookie-e2e-v1" ||
      value.run_nonce !== runNonce || value.evidence_contains_cookie_values !== false ||
      Number.isNaN(Date.parse(value.completed_at))) {
    fail("cookie fixture evidence identity is invalid");
  }
  const origin = new URL(value.fixture_origin);
  if (origin.protocol !== "http:" || origin.hostname !== "127.0.0.1" ||
      origin.pathname !== "/" || origin.search || origin.hash) {
    fail("cookie fixture evidence is not bound to an exact loopback origin");
  }
  exactKeys(value.cookie_contract,
    ["name", "path", "http_only", "same_site", "secure", "host_only"],
    "cookie fixture contract");
  if (value.cookie_contract.name !== "helium_sync_desktop_fixture" ||
      value.cookie_contract.path !== "/" || value.cookie_contract.http_only !== true ||
      value.cookie_contract.same_site !== "Lax" || value.cookie_contract.secure !== false ||
      value.cookie_contract.host_only !== true) {
    fail("cookie fixture attributes changed");
  }
  exactKeys(value.value_fingerprints, ["initial_sha256", "updated_sha256"],
    "cookie fixture fingerprints");
  if (!SHA256.test(value.value_fingerprints.initial_sha256) ||
      !SHA256.test(value.value_fingerprints.updated_sha256) ||
      value.value_fingerprints.initial_sha256 === value.value_fingerprints.updated_sha256) {
    fail("cookie fixture value fingerprints are invalid");
  }
  const observationNames = [
    "d_initial_empty_before_set", "da_received_initial_http_only_cookie",
    "da_updated_received_cookie", "d_received_updated_http_only_cookie",
    "d_deleted_received_cookie", "da_received_deletion",
  ];
  exactKeys(value.observations, observationNames, "cookie fixture observations");
  if (observationNames.some(name => value.observations[name] !== true)) {
    fail("cookie fixture lifecycle is incomplete");
  }
}

function validateJournal(raw, fixture, recordKey) {
  const records = raw.toString("utf8").split("\n").filter(Boolean).map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      fail(`server journal line ${index + 1} is not JSON`);
    }
  });
  const cookies = records.filter(record => record.kind === "cookies");
  if (cookies.length !== 3) fail("server journal does not contain exactly three cookie revisions");
  const expected = [
    {revision: 1n, deleted: false, device: "d-test", fingerprint: fixture.value_fingerprints.initial_sha256},
    {revision: 2n, deleted: false, device: "da-test", fingerprint: fixture.value_fingerprints.updated_sha256},
    {revision: 3n, deleted: true, device: "d-test"},
  ];
  for (let index = 0; index < cookies.length; index += 1) {
    const record = cookies[index];
    const wanted = expected[index];
    if (record.key !== recordKey ||
        parseCounter(record.revision, `journal cookie revision ${index + 1}`) !== wanted.revision ||
        record.deleted !== wanted.deleted || record.device_id !== wanted.device) {
      fail(`server journal cookie revision ${index + 1} is invalid`);
    }
    if (wanted.deleted) {
      if (!record.payload || typeof record.payload !== "object" ||
          Array.isArray(record.payload) || Object.keys(record.payload).length !== 0) {
        fail("server journal tombstone payload is not empty");
      }
    } else if (!record.payload || typeof record.payload !== "object" ||
               record.payload.name !== "helium_sync_desktop_fixture" ||
               record.payload.path !== "/" || record.payload.domain !== "127.0.0.1" ||
               record.payload.http_only !== true || record.payload.secure !== false ||
               typeof record.payload.value !== "string" ||
               sha256(record.payload.value) !== wanted.fingerprint) {
      fail(`server journal cookie payload ${index + 1} is invalid`);
    }
  }
  const maxSequence = records.reduce((maximum, record, index) => {
    const sequence = parseCounter(record.seq, `journal sequence ${index + 1}`);
    return sequence > maximum ? sequence : maximum;
  }, 0n);
  return {
    count: records.length,
    maxSequence,
    cookieRecords: cookies.map(record => ({
      seq: String(record.seq),
      key: record.key,
      revision: String(record.revision),
      deleted: record.deleted,
      device_id: record.device_id,
    })),
  };
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined || Object.hasOwn(result, key)) {
      fail("invalid acceptance arguments");
    }
    result[key.slice(2)] = value;
  }
  return result;
}

async function verify(args) {
  const names = [
    "sync-receipt", "da-admission-run", "artifact", "artifact-receipt",
    "fixture-evidence", "d-cookie-state", "da-cookie-state", "journal",
    "screenshot-dir", "output",
  ];
  if (JSON.stringify(Object.keys(args).sort()) !== JSON.stringify(names.sort())) {
    fail(`expected arguments: ${names.join(", ")}`);
  }
  const sync = await readJSON(args["sync-receipt"], "private password receipt");
  if (sync.value.schema_version !== 2 || sync.value.result !== "passed" ||
      !RUN_NONCE.test(sync.value.run_nonce) || !SHA256.test(sync.value.artifact_sha256)) {
    fail("private password receipt is not a passed schema-2 receipt");
  }
  const daAdmission = await readJSON(args["da-admission-run"],
    "da browser admission run");
  if (daAdmission.value.schema_version !== 2 ||
      daAdmission.value.platform !== "linux" || daAdmission.value.package !== "" ||
      daAdmission.value.artifact_sha256 !== sync.value.artifact_sha256 ||
      !SHA256.test(daAdmission.value.artifact_receipt_sha256) ||
      typeof daAdmission.value.run_root !== "string" ||
      !path.isAbsolute(daAdmission.value.run_root) ||
      typeof daAdmission.value.profile_path !== "string" ||
      !path.isAbsolute(daAdmission.value.profile_path) ||
      daAdmission.value.profile_path !== path.join(daAdmission.value.run_root, "profile") ||
      !Array.isArray(daAdmission.value.captures) || daAdmission.value.captures.length !== 0) {
    fail("da browser admission is not a fresh matching Linux run");
  }
  const artifact = await regularFile(args.artifact, "admitted browser", {privateFile: false});
  if (sha256(artifact.raw) !== sync.value.artifact_sha256) {
    fail("admitted browser changed after private password acceptance");
  }
  const artifactReceipt = await regularFile(args["artifact-receipt"],
    "artifact provenance receipt");
  if (daAdmission.value.artifact_path !== args.artifact ||
      daAdmission.value.artifact_receipt_sha256 !== sha256(artifactReceipt.raw)) {
    fail("da browser admission is not bound to the supplied runtime receipt");
  }
  const fixture = await readJSON(args["fixture-evidence"], "cookie fixture evidence");
  validateFixture(fixture.value, sync.value.run_nonce);

  const dState = await readJSON(args["d-cookie-state"], "d cookie bridge state");
  const daState = await readJSON(args["da-cookie-state"], "da cookie bridge state");
  if (!dState.raw.equals(daState.raw)) fail("d and da terminal cookie states are not byte-identical");
  const dTerminal = validateCookieState(dState.value, "d cookie bridge state");
  const daTerminal = validateCookieState(daState.value, "da cookie bridge state");
  if (dTerminal.key !== daTerminal.key ||
      dTerminal.verifiedSequence !== daTerminal.verifiedSequence) {
    fail("d and da terminal cookie cursors disagree");
  }

  const journal = await regularFile(args.journal, "readable server journal");
  const journalResult = validateJournal(journal.raw, fixture.value, dTerminal.key);
  if (dTerminal.verifiedSequence !== journalResult.maxSequence) {
    fail("cookie bridge cursors do not acknowledge the complete server journal");
  }

  const screenshotDir = args["screenshot-dir"];
  if (!path.isAbsolute(screenshotDir)) fail("screenshot directory must be absolute");
  const screenshotStat = await fsp.lstat(screenshotDir);
  if (!screenshotStat.isDirectory() || screenshotStat.isSymbolicLink() ||
      (screenshotStat.mode & 0o077) !== 0 || await fsp.realpath(screenshotDir) !== screenshotDir) {
    fail("screenshot directory must be a private real directory");
  }
  const inventory = (await fsp.readdir(screenshotDir)).sort();
  if (JSON.stringify(inventory) !== JSON.stringify([...SCREENSHOTS].sort())) {
    fail("cookie UI screenshot inventory is incomplete");
  }
  const screenshots = [];
  for (const name of SCREENSHOTS) {
    screenshots.push({step: name.slice(3, -4), ...await validatePNG(path.join(screenshotDir, name))});
  }

  if (!path.isAbsolute(args.output)) fail("receipt output must be absolute");
  await fsp.lstat(args.output).then(
    () => fail("refusing to replace an existing cookie acceptance receipt"),
    error => { if (error.code !== "ENOENT") throw error; },
  );
  const script = await regularFile(fileURLToPath(import.meta.url),
    "cookie acceptance verifier", {privateFile: false});
  const receipt = {
    schema_version: 1,
    receipt_type: "helium-desktop-native-cookie-e2e-v1",
    result: "passed",
    run_nonce: sync.value.run_nonce,
    artifact_sha256: sync.value.artifact_sha256,
    artifact_receipt_sha256: sha256(artifactReceipt.raw),
    private_password_receipt_sha256: sha256(sync.raw),
    da_admission_run_sha256: sha256(daAdmission.raw),
    fixture_evidence_sha256: sha256(fixture.raw),
    cookie_state_sha256: sha256(dState.raw),
    journal_sha256: sha256(journal.raw),
    journal_size: journal.stat.size,
    journal_record_count: journalResult.count,
    cookie_records: journalResult.cookieRecords,
    terminal_verified_sequence: dTerminal.verifiedSequence.toString(),
    screenshots,
    verifier_sha256: sha256(script.raw),
    verified_at: new Date().toISOString(),
  };
  const handle = await fsp.open(args.output,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(receipt, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
  return receipt;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv[2] !== "verify") {
      fail("usage: acceptance.mjs verify --sync-receipt FILE --da-admission-run FILE --artifact FILE --artifact-receipt FILE --fixture-evidence FILE --d-cookie-state FILE --da-cookie-state FILE --journal FILE --screenshot-dir DIR --output NEWFILE");
    }
    const receipt = await verify(parseArgs(process.argv.slice(3)));
    process.stdout.write(`${JSON.stringify({event: "passed", receipt})}\n`);
  } catch (error) {
    process.stderr.write(`Cookie acceptance failed: ${error.message}\n`);
    process.exit(1);
  }
}
