#!/usr/bin/env node

import crypto from "node:crypto";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

import {auditRun, NATIVE_PASSWORD_STEPS} from "./acceptance.mjs";

const SCHEMA_VERSION = 1;
export const SYNC_PASSWORD_STEPS = Object.freeze([
  "saved_store",
  "saved_restart_autofill",
  "updated_store",
  "updated_restart_autofill",
  "deleted_store",
  "deleted_restart_empty",
]);

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function equalJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function exactKeys(value, expected, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (!equalJSON(actual, wanted)) throw new Error(`${name} has an unexpected field inventory`);
}

function int64String(value, name) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${name} must be a non-negative int64 string`);
  }
  const parsed = BigInt(value);
  if (parsed > 9223372036854775807n) throw new Error(`${name} exceeds int64`);
  return parsed;
}

async function regularFile(filePath, name) {
  const resolved = path.resolve(filePath);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${name} must be a regular, non-symlink file`);
  }
  return {resolved, stat};
}

async function readJSON(filePath, name) {
  const {resolved} = await regularFile(filePath, name);
  const raw = await fsp.readFile(resolved, "utf8");
  return {resolved, raw, value: JSON.parse(raw)};
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

export function summarizePasswordState(state) {
  exactKeys(state, [
    "schema_version", "identity_schema", "migration_status",
    "verified_sequence", "credentials", "legacy_credentials",
  ], "password state");
  if (state.schema_version !== 4 ||
      state.identity_schema !== "password-form-unique-key-v2") {
    throw new Error("password state must use canonical identity schema 4");
  }
  if (state.migration_status !== "complete" ||
      !state.legacy_credentials ||
      typeof state.legacy_credentials !== "object" ||
      Array.isArray(state.legacy_credentials) ||
      Object.keys(state.legacy_credentials).length !== 0) {
    throw new Error("runtime acceptance requires completed empty legacy migration state");
  }
  int64String(state.verified_sequence, "verified_sequence");
  if (!state.credentials || typeof state.credentials !== "object" || Array.isArray(state.credentials)) {
    throw new Error("password state credentials must be an object");
  }
  const credentials = Object.entries(state.credentials).sort(([left], [right]) => left.localeCompare(right));
  return {
    schema_version: 4,
    identity_schema: state.identity_schema,
    verified_sequence: state.verified_sequence,
    credentials: credentials.map(([key, entry]) => {
      if (!/^credential\/v2\/[0-9a-f]{64}$/.test(key)) {
        throw new Error("password state contains an invalid credential key");
      }
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
    exactKeys(record, [
      "seq", "kind", "key", "revision", "deleted", "device_id", "key_id",
      "nonce", "ciphertext",
    ], `journal line ${index + 1}`);
    int64String(record.seq, `journal line ${index + 1} seq`);
    int64String(record.revision, `journal line ${index + 1} revision`);
    if (record.kind !== "passwords" && record.kind !== "cookies") {
      throw new Error("journal contains an invalid kind");
    }
    if (typeof record.key !== "string" || !record.key || typeof record.deleted !== "boolean" ||
        typeof record.device_id !== "string" || !record.device_id ||
        typeof record.key_id !== "string" || !record.key_id ||
        typeof record.nonce !== "string" || !record.nonce ||
        typeof record.ciphertext !== "string" || !record.ciphertext) {
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

async function loadPublicRun(runRoot) {
  const root = path.resolve(runRoot);
  const {value} = await readJSON(path.join(root, "run.json"), "public password acceptance run");
  if (value.run_root !== root || !equalJSON(value.expected_steps, NATIVE_PASSWORD_STEPS) ||
      !Array.isArray(value.captures) || !/^[0-9a-f]{64}$/.test(value.artifact_sha256)) {
    throw new Error("public password acceptance run is invalid");
  }
  return {root, run: value};
}

async function loadSyncRun(root, publicRun, {create = false} = {}) {
  const syncPath = path.join(root, "sync-run.json");
  let sync;
  try {
    sync = (await readJSON(syncPath, "Sync password acceptance run")).value;
  } catch (error) {
    if (!create || error.code !== "ENOENT") throw error;
    sync = {
      schema_version: SCHEMA_VERSION,
      run_root: root,
      artifact_sha256: publicRun.artifact_sha256,
      expected_steps: SYNC_PASSWORD_STEPS,
      captures: [],
    };
    await writeJSON(syncPath, sync, {exclusive: true});
  }
  exactKeys(sync, ["schema_version", "run_root", "artifact_sha256", "expected_steps", "captures"], "Sync acceptance run");
  if (sync.schema_version !== SCHEMA_VERSION || sync.run_root !== root ||
      sync.artifact_sha256 !== publicRun.artifact_sha256 ||
      !equalJSON(sync.expected_steps, SYNC_PASSWORD_STEPS) || !Array.isArray(sync.captures)) {
    throw new Error("Sync password acceptance run is invalid");
  }
  return {path: syncPath, run: sync};
}

export async function captureSyncStep({runRoot, step, passwordState, journal}) {
  const {root, run: publicRun} = await loadPublicRun(runRoot);
  const sync = await loadSyncRun(root, publicRun, {create: step === SYNC_PASSWORD_STEPS[0]});
  const expected = SYNC_PASSWORD_STEPS[sync.run.captures.length];
  if (step !== expected) throw new Error(`expected Sync acceptance step ${expected}, got ${step}`);
  const publicCapture = publicRun.captures.at(-1);
  if (!publicCapture || publicCapture.step !== step || !/^[0-9a-f]{64}$/.test(publicCapture.screenshot_sha256)) {
    throw new Error(`${step} Sync metadata must be captured immediately after its public UI capture`);
  }
  const state = await readJSON(passwordState, "disposable password state");
  const journalFile = await regularFile(journal, "disposable opaque journal");
  const capture = {
    step,
    captured_at: new Date().toISOString(),
    screenshot_sha256: publicCapture.screenshot_sha256,
    password_state: summarizePasswordState(state.value),
    journal: summarizeJournal(await fsp.readFile(journalFile.resolved, "utf8")),
  };
  sync.run.captures.push(capture);
  await writeJSON(sync.path, sync.run);
  return capture;
}

function captureByStep(run, step) {
  const capture = run.captures.find(item => item.step === step);
  if (!capture) throw new Error(`missing Sync acceptance capture: ${step}`);
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
  return records.reduce((latest, record) =>
    BigInt(record.revision) > BigInt(latest.revision) ? record : latest);
}

export function validateSyncAcceptance(syncRun, publicRun) {
  if (!equalJSON(syncRun.expected_steps, SYNC_PASSWORD_STEPS) ||
      !equalJSON(syncRun.captures.map(item => item.step), SYNC_PASSWORD_STEPS)) {
    throw new Error("Sync acceptance steps are incomplete or out of order");
  }
  for (const capture of syncRun.captures) {
    const publicCapture = publicRun.captures.find(item => item.step === capture.step);
    if (!publicCapture || publicCapture.screenshot_sha256 !== capture.screenshot_sha256) {
      throw new Error(`${capture.step} Sync metadata is not bound to its public UI capture`);
    }
  }
  const saved = captureByStep(syncRun, "saved_store");
  const savedRestart = captureByStep(syncRun, "saved_restart_autofill");
  const updated = captureByStep(syncRun, "updated_store");
  const updatedRestart = captureByStep(syncRun, "updated_restart_autofill");
  const deleted = captureByStep(syncRun, "deleted_store");
  const deletedRestart = captureByStep(syncRun, "deleted_restart_empty");
  const savedCredential = onlyCredential(saved, "saved_store");
  const updatedCredential = onlyCredential(updated, "updated_store");
  const deletedCredential = onlyCredential(deleted, "deleted_store");
  if (savedCredential.deleted || BigInt(savedCredential.revision) < 1n) {
    throw new Error("saved credential was not published");
  }
  if (!equalJSON(saved.password_state, savedRestart.password_state) ||
      saved.journal.sha256 !== savedRestart.journal.sha256) {
    throw new Error("unchanged restart after save mutated password state or journal");
  }
  if (updatedCredential.key !== savedCredential.key || updatedCredential.deleted ||
      BigInt(updatedCredential.revision) !== BigInt(savedCredential.revision) + 1n ||
      updatedCredential.fingerprint === savedCredential.fingerprint) {
    throw new Error("native password update did not produce one changed revision");
  }
  if (!equalJSON(updated.password_state, updatedRestart.password_state) ||
      updated.journal.sha256 !== updatedRestart.journal.sha256) {
    throw new Error("unchanged restart after update mutated password state or journal");
  }
  if (deletedCredential.key !== savedCredential.key || !deletedCredential.deleted ||
      deletedCredential.fingerprint !== "" ||
      BigInt(deletedCredential.revision) !== BigInt(updatedCredential.revision) + 1n) {
    throw new Error("native deletion did not produce the expected tombstone revision");
  }
  if (!equalJSON(deleted.password_state, deletedRestart.password_state) ||
      deleted.journal.sha256 !== deletedRestart.journal.sha256) {
    throw new Error("unchanged restart after deletion mutated password state or journal");
  }
  for (const [capture, credential] of [
    [saved, savedCredential], [updated, updatedCredential], [deleted, deletedCredential],
  ]) {
    const latest = latestJournalRecord(capture, credential.key);
    if (latest.revision !== credential.revision || latest.deleted !== credential.deleted ||
        latest.key_id !== credential.key_id) {
      throw new Error(`${capture.step} browser state does not match the opaque journal record`);
    }
  }
  return {
    credential_key: savedCredential.key,
    saved_revision: savedCredential.revision,
    updated_revision: updatedCredential.revision,
    tombstone_revision: deletedCredential.revision,
  };
}

export async function verifySyncRun({runRoot, fixtureEvidence}) {
  const audited = await auditRun({runRoot, fixtureEvidence});
  const publicReceiptFile = await readJSON(path.join(audited.root, "receipt.json"), "public acceptance receipt");
  exactKeys(publicReceiptFile.value, [
    "schema_version", "result", "artifact_sha256", "platform", "package",
    "fixture_origin", "screenshots", "fixture_evidence_sha256", "verified_at",
  ], "public acceptance receipt");
  const {verified_at: publicVerifiedAt, ...publicReceipt} = publicReceiptFile.value;
  if (typeof publicVerifiedAt !== "string" || !equalJSON(publicReceipt, audited.receipt)) {
    throw new Error("public acceptance receipt does not match the current artifact evidence");
  }
  const sync = await loadSyncRun(audited.root, audited.run);
  const result = validateSyncAcceptance(sync.run, audited.run);
  const receipt = {
    schema_version: SCHEMA_VERSION,
    result: "passed",
    artifact_sha256: audited.run.artifact_sha256,
    public_receipt_sha256: sha256(publicReceiptFile.raw),
    ...result,
    verified_at: new Date().toISOString(),
  };
  await writeJSON(path.join(audited.root, "sync-receipt.json"), receipt, {exclusive: true});
  return receipt;
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) throw new Error(`invalid argument: ${key}`);
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
  sync-acceptance.mjs capture --run DIR --step STEP --password-state JSON --journal JSONL
  sync-acceptance.mjs verify --run DIR --fixture-evidence JSON\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    const args = parseArgs(process.argv.slice(3));
    if (command === "capture") {
      requireArgs(args, ["run", "step", "password-state", "journal"]);
      const capture = await captureSyncStep({
        runRoot: args.run,
        step: args.step,
        passwordState: args["password-state"],
        journal: args.journal,
      });
      process.stdout.write(`${JSON.stringify({event: "captured", step: capture.step})}\n`);
    } else if (command === "verify") {
      requireArgs(args, ["run", "fixture-evidence"]);
      const receipt = await verifySyncRun({runRoot: args.run, fixtureEvidence: args["fixture-evidence"]});
      process.stdout.write(`${JSON.stringify({event: "passed", receipt})}\n`);
    } else {
      throw new Error(usage());
    }
  } catch (error) {
    process.stderr.write(`Sync password acceptance failed: ${error.message}\n`);
    process.exit(1);
  }
}
