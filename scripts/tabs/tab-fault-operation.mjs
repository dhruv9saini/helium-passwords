#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {
  atomicWrite,
  fail,
  hmac,
  loadSigningKey,
  readPrivateJSON,
  requirePrivateDirectory,
  requirePrivateFile,
  sha256File,
  validDevice,
  validSHA256,
  validSlug,
} from "./tab-proof-lib.mjs";

const MARKER = ".helium-tab-fault-operation-v1";
const MARKER_CONTENT = "helium-tab-fault-operation-v1\n";
const FAULTS = new Map([
  ["neutral-corrupt-newest-generation", {
    mechanism: "neutral-topology",
    rejection: "create-new-rejected",
    recovery: "previous-generation-restored",
  }],
  ["full-profile-corrupt-destination", {
    mechanism: "full-profile",
    rejection: "create-new-rejected",
    recovery: "independent-replica-restored",
  }],
]);
const INPUT_FIELDS = Object.freeze([
  "schema_version", "evidence_type", "operation", "platform",
  "source_device", "execution_identity_sha256", "package_id", "profile",
  "fault", "affected_mechanism", "damaged_generation",
  "recovery_generation", "damaged_destination", "recovery_destination",
  "create_new_result", "quarantine_result", "recovery_result",
  "live_profile_touched", "started_unix", "rejected_unix",
  "quarantined_unix", "recovered_unix", "completed_unix",
]);

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !==
        JSON.stringify([...keys].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
}

function timestamp(value, label) {
  if (!Number.isSafeInteger(value) || value < 1 ||
      value > Math.floor(Date.now() / 1000)) {
    fail(`${label} is invalid`);
  }
  return value;
}

export function validateFaultOperation(value) {
  exactKeys(value, [
    "schema_version", "evidence_type", "operation", "platform",
    "source_device", "execution_identity_sha256", "package_id", "profile",
    "fault", "affected_mechanism", "damaged_generation",
    "recovery_generation", "damaged_destination", "recovery_destination",
    "pre_fault_archive_sha256", "damaged_input_sha256",
    "quarantine_archive_sha256", "create_new_result", "quarantine_result",
    "recovery_result", "fallback_evidence_sha256",
    "sibling_state_before_sha256", "sibling_state_after_sha256",
    "live_profile_touched", "started_unix", "rejected_unix",
    "quarantined_unix", "recovered_unix", "completed_unix",
    "producer_sha256",
  ], "tab fault operation");
  const wanted = FAULTS.get(value.fault);
  if (value.schema_version !== 1 ||
      value.evidence_type !== "helium-tab-fault-operation-v1" ||
      !new Set(["rejection", "quarantine"]).has(value.operation) ||
      !new Set(["desktop", "android"]).has(value.platform) || !wanted ||
      value.affected_mechanism !== wanted.mechanism ||
      value.create_new_result !== wanted.rejection ||
      value.quarantine_result !== "completed" ||
      value.recovery_result !== wanted.recovery ||
      value.live_profile_touched !== false) {
    fail("tab fault operation result is invalid");
  }
  validDevice(value.source_device);
  validSlug(value.profile, "tab fault profile");
  if (![value.damaged_generation, value.recovery_generation].every(item =>
    typeof item === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(item))) {
    fail("tab fault generations are invalid");
  }
  for (const field of [
    "execution_identity_sha256", "pre_fault_archive_sha256",
    "damaged_input_sha256", "quarantine_archive_sha256",
    "fallback_evidence_sha256", "sibling_state_before_sha256",
    "sibling_state_after_sha256", "producer_sha256",
  ]) validSHA256(value[field], `tab fault ${field}`);
  if (value.damaged_input_sha256 === value.pre_fault_archive_sha256 ||
      value.quarantine_archive_sha256 !== value.damaged_input_sha256 ||
      value.sibling_state_before_sha256 !== value.sibling_state_after_sha256) {
    fail("fault evidence does not prove corruption, quarantine, and unchanged siblings");
  }
  if (value.platform === "desktop") {
    if (!new Set(["d", "da"]).has(value.source_device) ||
        value.package_id !== "desktop") {
      fail("desktop fault operation identity is invalid");
    }
  } else if (value.source_device !== "oneplus" ||
      value.package_id !== "computer.helium.sync.test") {
    fail("Android fault operation identity is invalid");
  }
  if (value.fault === "neutral-corrupt-newest-generation") {
    if (value.damaged_generation === value.recovery_generation ||
        value.damaged_destination !== "local-spool" ||
        value.recovery_destination === "local-spool") {
      fail("neutral fault did not recover a prior local generation");
    }
  } else if (value.damaged_generation !== value.recovery_generation ||
      value.damaged_destination === value.recovery_destination ||
      value.damaged_destination === "local-spool" ||
      value.recovery_destination === "local-spool") {
    fail("full-profile fault did not recover from an independent destination");
  }
  const times = [
    timestamp(value.started_unix, "fault start"),
    timestamp(value.rejected_unix, "fault rejection"),
    timestamp(value.quarantined_unix, "fault quarantine"),
    timestamp(value.recovered_unix, "fault recovery"),
    timestamp(value.completed_unix, "fault completion"),
  ];
  if (times.some((item, index) => index > 0 && item < times[index - 1])) {
    fail("tab fault operation chronology is invalid");
  }
  return value;
}

export function readAuthenticatedFaultOperation(directory, key,
  expectedProducerSHA256) {
  const root = path.resolve(directory);
  requirePrivateDirectory(root, "tab fault operation directory");
  const entries = fs.readdirSync(root).sort();
  if (JSON.stringify(entries) !== JSON.stringify([
    MARKER, "receipt.hmac", "receipt.json",
  ].sort())) {
    fail("tab fault operation directory inventory is invalid");
  }
  requirePrivateFile(path.join(root, MARKER), "tab fault operation marker", 128);
  if (fs.readFileSync(path.join(root, MARKER), "utf8") !== MARKER_CONTENT) {
    fail("tab fault operation marker is invalid");
  }
  const receipt = readPrivateJSON(path.join(root, "receipt.json"),
    "tab fault operation receipt", 1024 * 1024);
  requirePrivateFile(path.join(root, "receipt.hmac"),
    "tab fault operation authentication", 128);
  const signature = fs.readFileSync(path.join(root, "receipt.hmac"), "utf8");
  if (!/^[0-9a-f]{64}\n$/.test(signature) ||
      signature.trim() !== hmac(receipt.raw, key)) {
    fail("tab fault operation authentication failed");
  }
  validateFaultOperation(receipt.value);
  if (receipt.value.producer_sha256 !== expectedProducerSHA256) {
    fail("tab fault operation was not produced by the admitted recorder");
  }
  return {root, raw: receipt.raw, value: receipt.value,
    sha256: validSHA256(sha256FileSync(path.join(root, "receipt.json")),
      "tab fault receipt SHA-256")};
}

function sha256FileSync(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

async function publish(input, output, keyFile, evidence) {
  const key = loadSigningKey(keyFile);
  const body = readPrivateJSON(path.resolve(input), "fault operation input");
  exactKeys(body.value, INPUT_FIELDS, "fault operation input");
  const digest = async (option, label) => {
    const file = path.resolve(evidence.get(option) || "");
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
        stat.size > 16 * 1024 * 1024 * 1024 || (stat.mode & 0o077) !== 0) {
      fail(`${label} must be a private nonempty regular file`);
    }
    return sha256File(file);
  };
  const producerSHA256 = await sha256File(fileURLToPath(import.meta.url));
  const value = {
    ...body.value,
    pre_fault_archive_sha256: await digest(
      "--pre-fault-archive", "pre-fault archive"),
    damaged_input_sha256: await digest("--damaged-input", "damaged input"),
    quarantine_archive_sha256: await digest(
      "--quarantine-archive", "quarantine archive"),
    fallback_evidence_sha256: await digest(
      "--fallback-evidence", "fallback evidence"),
    sibling_state_before_sha256: await digest(
      "--sibling-before", "pre-fault sibling state"),
    sibling_state_after_sha256: await digest(
      "--sibling-after", "post-recovery sibling state"),
    producer_sha256: producerSHA256,
  };
  validateFaultOperation(value);
  const root = path.resolve(output);
  if (fs.existsSync(root)) fail("fault operation output already exists");
  requirePrivateDirectory(path.dirname(root), "fault operation output parent");
  fs.mkdirSync(root, {mode: 0o700});
  try {
    atomicWrite(path.join(root, MARKER), MARKER_CONTENT);
    const raw = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
    atomicWrite(path.join(root, "receipt.json"), raw);
    atomicWrite(path.join(root, "receipt.hmac"), `${hmac(raw, key)}\n`);
  } catch (error) {
    fs.rmSync(root, {recursive: true, force: true});
    throw error;
  }
  return root;
}

function parse(args) {
  const result = new Map();
  for (let index = 0; index < args.length; index += 2) {
    if (!args[index]?.startsWith("--") || args[index + 1] === undefined ||
        result.has(args[index])) fail("options must be unique pairs");
    result.set(args[index], args[index + 1]);
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, ...args] = process.argv.slice(2);
    const options = parse(args);
    const expected = [
      "--input", "--output", "--signing-key", "--pre-fault-archive",
      "--damaged-input", "--quarantine-archive", "--fallback-evidence",
      "--sibling-before", "--sibling-after",
    ];
    if (command !== "record" || options.size !== expected.length ||
        expected.some(option => !options.has(option))) {
      fail("usage: tab-fault-operation.mjs record --input JSON --output NEW-DIR --signing-key FILE --pre-fault-archive FILE --damaged-input FILE --quarantine-archive FILE --fallback-evidence FILE --sibling-before FILE --sibling-after FILE");
    }
    const output = await publish(options.get("--input"), options.get("--output"),
      options.get("--signing-key"), options);
    process.stdout.write(`${JSON.stringify({event: "recorded", output})}\n`);
  } catch (error) {
    process.stderr.write(`tab fault operation: ${error.message}\n`);
    process.exitCode = 1;
  }
}
