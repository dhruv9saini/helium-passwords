#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import {
  EVIDENCE_MARKER,
  EVIDENCE_MARKER_CONTENT,
  HEALTH_MARKER,
  HEALTH_MARKER_CONTENT,
  atomicWrite,
  createMarkedRoot,
  fail,
  loadSigningKey,
  readAuthenticatedEvidence,
  requireAbsolute,
  requireMarker,
  sha256,
  validDevice,
  validSlug,
} from "./tab-proof-lib.mjs";

function usage() {
  console.error(`usage:
  tab-proof-status.mjs init-key --key ABSOLUTE-NEW-FILE
  tab-proof-status.mjs init-evidence-root --evidence-root ABSOLUTE-NEW-DIR
  tab-proof-status.mjs init-status-root --status-root ABSOLUTE-NEW-DIR
  tab-proof-status.mjs verify --key FILE --evidence-dir DIR
  tab-proof-status.mjs emit --key FILE --status-root DIR \\
    --source-device d|da|oneplus --profile SLUG --evidence-dir DIR [...]

Neutral and full-profile status requires two independently authenticated
evidence directories from distinct source destinations. Native status requires
one evidence directory. Existing status files are replaced atomically.`);
  process.exitCode = 64;
}

function parseOptions(args, repeatable = new Set()) {
  const options = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail("options must be --name value pairs");
    }
    if (options.has(key) && !repeatable.has(key)) {
      fail(`duplicate option: ${key}`);
    }
    if (repeatable.has(key)) {
      options.set(key, [...(options.get(key) ?? []), value]);
    } else {
      options.set(key, value);
    }
  }
  return options;
}

function requireOnly(options, required, optional = []) {
  const allowed = new Set([...required, ...optional]);
  for (const key of options.keys()) {
    if (!allowed.has(key)) {
      fail(`unknown option: ${key}`);
    }
  }
  for (const key of required) {
    if (!options.has(key)) {
      fail(`missing option: ${key}`);
    }
  }
}

function initKey(options) {
  requireOnly(options, ["--key"]);
  const keyPath = requireAbsolute(options.get("--key"), "signing key");
  if (fs.existsSync(keyPath)) {
    fail("signing key already exists");
  }
  const parent = path.dirname(keyPath);
  requireMarker(parent, EVIDENCE_MARKER, EVIDENCE_MARKER_CONTENT,
    "evidence root");
  const descriptor = fs.openSync(keyPath,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600);
  try {
    fs.writeFileSync(descriptor, `${crypto.randomBytes(32).toString("hex")}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  console.log(`key=${keyPath}`);
}

function initRoot(options, kind) {
  const option = kind === "evidence" ? "--evidence-root" : "--status-root";
  requireOnly(options, [option]);
  const directory = options.get(option);
  if (kind === "evidence") {
    createMarkedRoot(directory, EVIDENCE_MARKER, EVIDENCE_MARKER_CONTENT,
      "evidence root");
  } else {
    createMarkedRoot(directory, HEALTH_MARKER, HEALTH_MARKER_CONTENT,
      "status root");
  }
  console.log(`${kind}_root=${directory}`);
}

function verify(options) {
  requireOnly(options, ["--key", "--evidence-dir"]);
  const key = loadSigningKey(options.get("--key"));
  const directories = options.get("--evidence-dir");
  if (!Array.isArray(directories) || directories.length !== 1) {
    fail("verify requires exactly one evidence directory");
  }
  const evidence = readAuthenticatedEvidence(directories[0], key);
  console.log(JSON.stringify({
    mechanism: evidence.value.mechanism,
    source_device: evidence.value.source_device,
    profile: evidence.value.profile,
    generation: evidence.value.generation,
    evidence_sha256: evidence.sha256,
  }));
}

function emit(options) {
  requireOnly(options, [
    "--key",
    "--status-root",
    "--source-device",
    "--profile",
    "--evidence-dir",
  ]);
  const device = validDevice(options.get("--source-device"));
  const profile = validSlug(options.get("--profile"), "profile");
  const statusRoot = options.get("--status-root");
  requireMarker(statusRoot, HEALTH_MARKER, HEALTH_MARKER_CONTENT, "status root");
  const key = loadSigningKey(options.get("--key"));
  const directories = options.get("--evidence-dir");
  if (!Array.isArray(directories) || directories.length < 1) {
    fail("at least one evidence directory is required");
  }
  const evidences = directories.map(directory =>
    readAuthenticatedEvidence(directory, key));
  const mechanism = evidences[0].value.mechanism;
  const requiredCount = mechanism === "chromium-native-session" ? 1 : 2;
  if (evidences.length !== requiredCount) {
    fail(`${mechanism} requires exactly ${requiredCount} evidence director${requiredCount === 1 ? "y" : "ies"}`);
  }
  const first = evidences[0].value;
  for (const evidence of evidences) {
    const value = evidence.value;
    if (value.mechanism !== mechanism ||
        value.source_device !== device ||
        value.profile !== profile ||
        value.generation !== first.generation ||
        value.browser.sha256 !== first.browser.sha256 ||
        value.package_id !== first.package_id ||
        JSON.stringify(value.expected_topology) !==
          JSON.stringify(first.expected_topology)) {
      fail("runtime evidence set does not describe one exact recovery drill");
    }
  }
  if (mechanism !== "chromium-native-session") {
    const destinations = new Set(evidences.map(evidence =>
      evidence.value.source_binding.source_destination));
    if (destinations.size !== 2) {
      fail(`${mechanism} requires two distinct source destinations`);
    }
    if (mechanism === "neutral-topology") {
      const sessions = new Set(evidences.map(evidence =>
        evidence.value.source_binding.source_session_sha256));
      const archives = new Set(evidences.map(evidence =>
        evidence.value.source_binding.archive_sha256));
      if (sessions.size !== 1 || archives.size !== 1) {
        fail("neutral evidence does not bind one replicated source generation");
      }
    } else {
      const archives = new Set(evidences.map(evidence =>
        evidence.value.source_binding.archive_sha256));
      const expected = new Set(evidences.map(evidence =>
        evidence.value.source_binding.expected_evidence_sha256));
      if (archives.size !== 1 || expected.size !== 1) {
        fail("full-profile replicas do not bind one source generation");
      }
    }
  }
  const completed = Math.min(...evidences.map(evidence =>
    evidence.value.completed_unix));
  const evidenceHash = sha256(Buffer.from(
    `${evidences.map(evidence => evidence.sha256).sort().join("\n")}\n`));
  const status = [
    "version=1",
    `mechanism=${mechanism}`,
    "state=healthy",
    `source_device=${device}`,
    `profile=${profile}`,
    `completed_unix=${completed}`,
    `generation=${first.generation}`,
    `evidence=${evidenceHash}`,
    "",
  ].join("\n");
  const target = path.join(statusRoot, `${mechanism}.status`);
  atomicWrite(target, status);
  console.log(JSON.stringify({
    mechanism,
    status: target,
    evidence_count: evidences.length,
    evidence_sha256: evidenceHash,
  }));
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (!command) {
    usage();
  } else {
    const options = parseOptions(args, new Set(["--evidence-dir"]));
    switch (command) {
      case "init-key":
        initKey(options);
        break;
      case "init-evidence-root":
        initRoot(options, "evidence");
        break;
      case "init-status-root":
        initRoot(options, "status");
        break;
      case "verify":
        verify(options);
        break;
      case "emit":
        emit(options);
        break;
      default:
        usage();
    }
  }
} catch (error) {
  console.error(`tab-proof-status: ${error.message}`);
  process.exitCode = 1;
}
