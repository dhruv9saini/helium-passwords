#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

const SCHEMA_VERSION = 1;
const ANDROID_TEST_PACKAGE = "computer.helium.sync.test";
const SCREENSHOT_MAX_BYTES = 32 * 1024 * 1024;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const STEPS = [
  "settings_entry",
  "save_prompt",
  "saved_store",
  "suggestions",
  "saved_restart_autofill",
  "generation",
  "update_prompt",
  "updated_store",
  "updated_restart_autofill",
  "delete",
  "tombstone",
  "deleted_restart_empty",
];
const STATE_STEPS = new Set([
  "saved_store",
  "saved_restart_autofill",
  "updated_store",
  "updated_restart_autofill",
  "tombstone",
  "deleted_restart_empty",
]);

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

async function regularFile(filePath, name) {
  const resolved = path.resolve(filePath);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${name} must be a regular, non-symlink file`);
  return {resolved, stat};
}

async function readJSON(filePath, name) {
  const {resolved} = await regularFile(filePath, name);
  return {resolved, value: JSON.parse(await fsp.readFile(resolved, "utf8"))};
}

async function readPreparedAndroidAdmission(artifactPath, artifactHash) {
  if (path.basename(artifactPath) !== "Browser-test.apk") {
    throw new Error("Android artifact must be the prepared Browser-test.apk");
  }
  const directory = path.dirname(artifactPath);
  const receipt = await regularFile(path.join(directory, "acceptance.env"), "Android acceptance metadata");
  const inventory = await regularFile(path.join(directory, "PACKAGE_SHA256SUMS"), "Android acceptance checksum inventory");
  const values = new Map();
  for (const line of (await fsp.readFile(receipt.resolved, "utf8")).split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    if (separator < 1) throw new Error("Android acceptance metadata is malformed");
    const key = line.slice(0, separator);
    if (values.has(key)) throw new Error("Android acceptance metadata contains duplicate keys");
    values.set(key, line.slice(separator + 1));
  }
  if (values.get("schema_version") !== "1" || values.get("package") !== ANDROID_TEST_PACKAGE ||
      values.get("apk_sha256") !== artifactHash) {
    throw new Error("Android acceptance metadata does not admit this test APK");
  }
  const expectedLine = `${artifactHash}  ./Browser-test.apk`;
  if (!(await fsp.readFile(inventory.resolved, "utf8")).split("\n").includes(expectedLine)) {
    throw new Error("Android checksum inventory does not admit this test APK");
  }
}

async function writeJSON(filePath, value, {exclusive = false} = {}) {
  const data = `${JSON.stringify(value, null, 2)}\n`;
  if (exclusive) {
    await fsp.writeFile(filePath, data, {mode: 0o600, flag: "wx"});
    return;
  }
  const temporary = `${filePath}.tmp-${process.pid}-${crypto.randomUUID()}`;
  await fsp.writeFile(temporary, data, {mode: 0o600, flag: "wx"});
  await fsp.rename(temporary, filePath);
}

function exactKeys(value, expected, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    throw new Error(`${name} has an unexpected field inventory`);
  }
}

function int64String(value, name) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${name} must be a non-negative int64 string`);
  }
  const parsed = BigInt(value);
  if (parsed > 9223372036854775807n) throw new Error(`${name} exceeds int64`);
  return parsed;
}

export function summarizePasswordState(state) {
  exactKeys(state, ["schema_version", "verified_sequence", "credentials"], "password state");
  if (state.schema_version !== 3) throw new Error("password state schema must be 3");
  int64String(state.verified_sequence, "verified_sequence");
  if (!state.credentials || typeof state.credentials !== "object" || Array.isArray(state.credentials)) {
    throw new Error("password state credentials must be an object");
  }
  const credentials = Object.entries(state.credentials).sort(([left], [right]) => left.localeCompare(right));
  return {
    schema_version: 3,
    verified_sequence: state.verified_sequence,
    credentials: credentials.map(([key, entry]) => {
      if (!/^credential\/[0-9a-f]{64}$/.test(key)) throw new Error("password state contains an invalid credential key");
      exactKeys(entry, ["fingerprint", "remote_seq", "revision", "deleted", "key_id"], `credential ${key}`);
      const revision = int64String(entry.revision, `${key} revision`);
      int64String(entry.remote_seq, `${key} remote_seq`);
      if (typeof entry.deleted !== "boolean" || typeof entry.key_id !== "string") {
        throw new Error(`${key} has invalid deletion or key metadata`);
      }
      if (entry.deleted ? entry.fingerprint !== "" : !/^[0-9a-f]{64}$/.test(entry.fingerprint)) {
        throw new Error(`${key} has an invalid fingerprint/deletion combination`);
      }
      if (revision > 0n && !/^[0-9a-f]{16,64}$/.test(entry.key_id)) {
        throw new Error(`${key} has no valid content-key id`);
      }
      return {key, ...entry};
    }),
  };
}

export function summarizeJournal(raw) {
  const records = [];
  for (const [index, line] of raw.split("\n").entries()) {
    if (!line) continue;
    const record = JSON.parse(line);
    exactKeys(record, ["seq", "kind", "key", "revision", "deleted", "device_id", "key_id", "nonce", "ciphertext"], `journal line ${index + 1}`);
    int64String(record.seq, `journal line ${index + 1} seq`);
    int64String(record.revision, `journal line ${index + 1} revision`);
    if (record.kind !== "passwords" && record.kind !== "cookies") throw new Error("journal contains an invalid kind");
    if (typeof record.key !== "string" || !record.key || typeof record.deleted !== "boolean" ||
        typeof record.device_id !== "string" || !record.device_id || typeof record.key_id !== "string" || !record.key_id ||
        typeof record.nonce !== "string" || !record.nonce || typeof record.ciphertext !== "string" || !record.ciphertext) {
      throw new Error(`journal line ${index + 1} has invalid metadata`);
    }
    if (record.kind === "passwords") {
      records.push({
        seq: record.seq,
        kind: record.kind,
        key: record.key,
        revision: record.revision,
        deleted: record.deleted,
        device_id: record.device_id,
        key_id: record.key_id,
      });
    }
  }
  return {sha256: sha256(raw), password_records: records};
}

async function loadRun(runRoot) {
  const root = path.resolve(runRoot);
  const {value} = await readJSON(path.join(root, "run.json"), "acceptance run");
  if (value.schema_version !== SCHEMA_VERSION || value.run_root !== root || !Array.isArray(value.captures)) {
    throw new Error("acceptance run metadata is invalid");
  }
  return {root, run: value};
}

export async function initializeRun({artifact, output, platform, packageName = ""}) {
  if (!new Set(["linux", "android"]).has(platform)) throw new Error("platform must be linux or android");
  if (platform === "android" && packageName !== ANDROID_TEST_PACKAGE) {
    throw new Error(`Android acceptance requires ${ANDROID_TEST_PACKAGE}`);
  }
  if (platform === "linux" && packageName) throw new Error("Linux acceptance does not take an Android package");
  const artifactInfo = await regularFile(artifact, "browser artifact");
  const artifactHash = sha256(await fsp.readFile(artifactInfo.resolved));
  if (platform === "linux" && (artifactInfo.stat.mode & 0o111) === 0) {
    throw new Error("Linux browser artifact must be the executable that will be launched");
  }
  if (platform === "android") {
    await readPreparedAndroidAdmission(artifactInfo.resolved, artifactHash);
  }
  const root = path.resolve(output);
  await fsp.mkdir(path.dirname(root), {recursive: true});
  await fsp.mkdir(root, {mode: 0o700});
  await fsp.mkdir(path.join(root, "screenshots"), {mode: 0o700});
  let profile = null;
  if (platform === "linux") {
    profile = path.join(root, "profile");
    await fsp.mkdir(profile, {mode: 0o700});
    await fsp.writeFile(path.join(profile, "SYNTHETIC_ONLY"), "helium-password-runtime-v1\n", {mode: 0o600, flag: "wx"});
  }
  const run = {
    schema_version: SCHEMA_VERSION,
    run_root: root,
    platform,
    package: packageName,
    artifact_path: artifactInfo.resolved,
    artifact_sha256: artifactHash,
    profile_path: profile,
    created_at: new Date().toISOString(),
    expected_steps: STEPS,
    captures: [],
  };
  await writeJSON(path.join(root, "run.json"), run, {exclusive: true});
  return run;
}

async function validateScreenshot(filePath) {
  const {resolved, stat} = await regularFile(filePath, "native UI screenshot");
  if (stat.size <= PNG_SIGNATURE.length || stat.size > SCREENSHOT_MAX_BYTES) {
    throw new Error("native UI screenshot size is invalid");
  }
  const handle = await fsp.open(resolved, "r");
  const signature = Buffer.alloc(PNG_SIGNATURE.length);
  try {
    await handle.read(signature, 0, signature.length, 0);
  } finally {
    await handle.close();
  }
  if (!signature.equals(PNG_SIGNATURE)) throw new Error("native UI screenshot is not PNG");
  return resolved;
}

export async function captureStep({runRoot, step, screenshot, passwordState, journal}) {
  const {root, run} = await loadRun(runRoot);
  const expected = STEPS[run.captures.length];
  if (step !== expected) throw new Error(`expected acceptance step ${expected}, got ${step}`);
  const screenshotPath = await validateScreenshot(screenshot);
  const capture = {
    step,
    captured_at: new Date().toISOString(),
  };
  if (STATE_STEPS.has(step)) {
    if (!passwordState || !journal) throw new Error(`${step} requires password-state and journal files`);
    const state = await readJSON(passwordState, "disposable password state");
    const journalFile = await regularFile(journal, "disposable opaque journal");
    capture.password_state = summarizePasswordState(state.value);
    capture.journal = summarizeJournal(await fsp.readFile(journalFile.resolved, "utf8"));
  } else if (passwordState || journal) {
    throw new Error(`${step} does not accept password-state or journal files`);
  }
  const screenshotName = `${String(run.captures.length + 1).padStart(2, "0")}-${step}.png`;
  const copiedScreenshot = path.join(root, "screenshots", screenshotName);
  await fsp.copyFile(screenshotPath, copiedScreenshot, fs.constants.COPYFILE_EXCL);
  await fsp.chmod(copiedScreenshot, 0o600);
  capture.screenshot = `screenshots/${screenshotName}`;
  capture.screenshot_sha256 = sha256(await fsp.readFile(copiedScreenshot));
  run.captures.push(capture);
  await writeJSON(path.join(root, "run.json"), run);
  return capture;
}

function captureByStep(run, step) {
  const capture = run.captures.find(item => item.step === step);
  if (!capture) throw new Error(`missing acceptance capture: ${step}`);
  return capture;
}

function onlyCredential(capture, step) {
  const credentials = capture.password_state?.credentials;
  if (!Array.isArray(credentials) || credentials.length !== 1) {
    throw new Error(`${step} must contain exactly one synthetic credential`);
  }
  return credentials[0];
}

function latestJournalRecord(capture, key) {
  const records = capture.journal?.password_records?.filter(record => record.key === key) || [];
  if (!records.length) throw new Error(`${capture.step} journal has no record for the synthetic credential`);
  return records.reduce((latest, record) => BigInt(record.revision) > BigInt(latest.revision) ? record : latest);
}

function equalJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

export function validateAcceptance(run, fixtureEvidence) {
  if (!equalJSON(run.expected_steps, STEPS) || !equalJSON(run.captures.map(item => item.step), STEPS)) {
    throw new Error("acceptance steps are incomplete or out of order");
  }
  exactKeys(fixtureEvidence, ["schema_version", "completed_at", "fixture_origin", "observations", "evidence_contains_submitted_values"], "fixture evidence");
  if (fixtureEvidence.schema_version !== 1 || fixtureEvidence.evidence_contains_submitted_values !== false) {
    throw new Error("fixture evidence schema or secret boundary is invalid");
  }
  const fixtureURL = new URL(fixtureEvidence.fixture_origin);
  if (fixtureURL.protocol !== "http:" || fixtureURL.hostname !== "127.0.0.1") {
    throw new Error("fixture evidence is not loopback-bound");
  }
  const observationNames = [
    "initial_login_accepted", "saved_restart_matches", "update_current_matches",
    "update_changes_password", "generated_candidate_minimum_length",
    "updated_restart_matches", "deleted_restart_empty",
  ];
  exactKeys(fixtureEvidence.observations, observationNames, "fixture observations");
  if (observationNames.some(name => fixtureEvidence.observations[name] !== true)) {
    throw new Error("fixture lifecycle is incomplete");
  }

  const saved = captureByStep(run, "saved_store");
  const savedRestart = captureByStep(run, "saved_restart_autofill");
  const updated = captureByStep(run, "updated_store");
  const updatedRestart = captureByStep(run, "updated_restart_autofill");
  const tombstone = captureByStep(run, "tombstone");
  const deletedRestart = captureByStep(run, "deleted_restart_empty");
  const savedCredential = onlyCredential(saved, "saved_store");
  const updatedCredential = onlyCredential(updated, "updated_store");
  const deletedCredential = onlyCredential(tombstone, "tombstone");
  if (savedCredential.deleted || BigInt(savedCredential.revision) < 1n) throw new Error("saved credential was not published");
  if (!equalJSON(saved.password_state, savedRestart.password_state) || saved.journal.sha256 !== savedRestart.journal.sha256) {
    throw new Error("unchanged restart after save mutated password state or journal");
  }
  if (updatedCredential.key !== savedCredential.key || updatedCredential.deleted ||
      BigInt(updatedCredential.revision) !== BigInt(savedCredential.revision) + 1n ||
      updatedCredential.fingerprint === savedCredential.fingerprint) {
    throw new Error("native password update did not produce one changed revision");
  }
  if (!equalJSON(updated.password_state, updatedRestart.password_state) || updated.journal.sha256 !== updatedRestart.journal.sha256) {
    throw new Error("unchanged restart after update mutated password state or journal");
  }
  if (deletedCredential.key !== savedCredential.key || !deletedCredential.deleted ||
      deletedCredential.fingerprint !== "" ||
      BigInt(deletedCredential.revision) !== BigInt(updatedCredential.revision) + 1n) {
    throw new Error("native deletion did not produce the expected tombstone revision");
  }
  if (!equalJSON(tombstone.password_state, deletedRestart.password_state) ||
      tombstone.journal.sha256 !== deletedRestart.journal.sha256) {
    throw new Error("unchanged restart after deletion mutated password state or journal");
  }
  for (const [capture, credential] of [[saved, savedCredential], [updated, updatedCredential], [tombstone, deletedCredential]]) {
    const latest = latestJournalRecord(capture, credential.key);
    if (latest.revision !== credential.revision || latest.deleted !== credential.deleted || latest.key_id !== credential.key_id) {
      throw new Error(`${capture.step} browser state does not match the accepted opaque journal record`);
    }
  }
  return {
    schema_version: 1,
    result: "passed",
    artifact_sha256: run.artifact_sha256,
    platform: run.platform,
    package: run.package,
    fixture_origin: fixtureEvidence.fixture_origin,
    credential_key: savedCredential.key,
    saved_revision: savedCredential.revision,
    updated_revision: updatedCredential.revision,
    tombstone_revision: deletedCredential.revision,
    verified_at: new Date().toISOString(),
  };
}

export async function verifyRun({runRoot, fixtureEvidence}) {
  const {root, run} = await loadRun(runRoot);
  const artifact = await regularFile(run.artifact_path, "browser artifact");
  if (sha256(await fsp.readFile(artifact.resolved)) !== run.artifact_sha256) {
    throw new Error("browser artifact changed after acceptance initialization");
  }
  if (run.platform === "linux") {
    const marker = path.join(root, "profile", "SYNTHETIC_ONLY");
    if (run.profile_path !== path.join(root, "profile") ||
        await fsp.readFile(marker, "utf8") !== "helium-password-runtime-v1\n") {
      throw new Error("Linux disposable profile marker is missing or invalid");
    }
  } else if (run.platform !== "android" || run.package !== ANDROID_TEST_PACKAGE) {
    throw new Error("Android acceptance package boundary is invalid");
  }
  for (const capture of run.captures) {
    const screenshotPath = path.join(root, capture.screenshot);
    const screenshot = await validateScreenshot(screenshotPath);
    if (!screenshot.startsWith(`${path.join(root, "screenshots")}${path.sep}`) ||
        sha256(await fsp.readFile(screenshot)) !== capture.screenshot_sha256) {
      throw new Error(`screenshot changed after capture: ${capture.step}`);
    }
  }
  const fixture = await readJSON(fixtureEvidence, "fixture evidence");
  const receipt = validateAcceptance(run, fixture.value);
  await writeJSON(path.join(root, "receipt.json"), receipt, {exclusive: true});
  return receipt;
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) throw new Error(`invalid argument: ${key}`);
    result[key.slice(2)] = argv[++index];
  }
  return result;
}

function usage() {
  return `usage:
  acceptance.mjs init --artifact FILE --platform linux|android --output NEW_DIR [--package ${ANDROID_TEST_PACKAGE}]
  acceptance.mjs capture --run DIR --step STEP --screenshot PNG [--password-state JSON --journal JSONL]
  acceptance.mjs verify --run DIR --fixture-evidence JSON\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    const args = parseArgs(process.argv.slice(3));
    if (command === "init") {
      const run = await initializeRun({
        artifact: args.artifact,
        output: args.output,
        platform: args.platform,
        packageName: args.package || "",
      });
      process.stdout.write(`${JSON.stringify({event: "initialized", run: run.run_root, profile: run.profile_path})}\n`);
    } else if (command === "capture") {
      const capture = await captureStep({
        runRoot: args.run,
        step: args.step,
        screenshot: args.screenshot,
        passwordState: args["password-state"],
        journal: args.journal,
      });
      process.stdout.write(`${JSON.stringify({event: "captured", step: capture.step})}\n`);
    } else if (command === "verify") {
      const receipt = await verifyRun({runRoot: args.run, fixtureEvidence: args["fixture-evidence"]});
      process.stdout.write(`${JSON.stringify({event: "passed", receipt})}\n`);
    } else {
      throw new Error(usage());
    }
  } catch (error) {
    process.stderr.write(`Native password acceptance failed: ${error.message}\n`);
    process.exit(1);
  }
}
