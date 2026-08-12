#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

import {auditLinuxFullGraphEvidence} from "../linux-full-graph-audit.mjs";

const SCHEMA_VERSION = 2;
export const DISPOSABLE_PROFILE_MARKER = "helium-password-runtime-v2\n";
const SCREENSHOT_MAX_BYTES = 32 * 1024 * 1024;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const ANDROID_TEST_PACKAGE = /^(?:[a-z][a-z0-9_]*\.){2,}[a-z][a-z0-9_]*\.test$/;
const RUN_NONCE = /^[0-9a-f]{64}$/;
const LINUX_PRODUCT = "helium-passwords";
const LINUX_ARCH = "x86_64";
const LINUX_BUNDLE = `${LINUX_PRODUCT}-linux-${LINUX_ARCH}`;
const PNG_CRC_TABLE = Object.freeze(Array.from({length: 256}, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) {
    crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return crc >>> 0;
}));

export const NATIVE_PASSWORD_STEPS = Object.freeze([
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
  "deleted_store",
  "deleted_restart_empty",
]);

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
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

function exactKeys(value, expected, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    throw new Error(`${name} has an unexpected field inventory`);
  }
}

function validAndroidTestPackage(packageName) {
  return typeof packageName === "string" && ANDROID_TEST_PACKAGE.test(packageName);
}

async function readPreparedAndroidAdmission(artifactPath, artifactHash, packageName) {
  if (!validAndroidTestPackage(packageName)) {
    throw new Error("Android acceptance requires a separately installable package ending in .test");
  }
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
  const expectedMetadataKeys = [
    "schema_version", "package", "helium_sync_commit", "chromium_commit",
    "version_code", "version_name", "source_archive_sha256", "apk_sha256",
    "runtime_kit_sha256", "prepared_at",
  ].sort();
  if (JSON.stringify([...values.keys()].sort()) !== JSON.stringify(expectedMetadataKeys)) {
    throw new Error("Android acceptance metadata has an unexpected field inventory");
  }
  if (values.get("schema_version") !== "2" || values.get("package") !== packageName ||
      values.get("apk_sha256") !== artifactHash) {
    throw new Error("Android acceptance metadata does not admit this test APK and package");
  }
  for (const name of ["helium_sync_commit", "chromium_commit"]) {
    if (!/^[0-9a-f]{40}$/.test(values.get(name) || "")) {
      throw new Error(`Android acceptance metadata has an invalid ${name}`);
    }
  }
  for (const name of ["source_archive_sha256", "apk_sha256", "runtime_kit_sha256"]) {
    if (!/^[0-9a-f]{64}$/.test(values.get(name) || "")) {
      throw new Error(`Android acceptance metadata has an invalid ${name}`);
    }
  }
  if (!/^[1-9][0-9]*$/.test(values.get("version_code") || "") ||
      !/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(values.get("version_name") || "") ||
      !Number.isFinite(Date.parse(values.get("prepared_at") || ""))) {
    throw new Error("Android acceptance metadata has an invalid version or timestamp");
  }

  const recordedFiles = new Map();
  for (const line of (await fsp.readFile(inventory.resolved, "utf8")).split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  \.\/(.+)$/.exec(line);
    if (!match || match[2].startsWith("/") || match[2].includes("\\") ||
        match[2].split("/").some(component => component === "" ||
          component === "." || component === "..") ||
        recordedFiles.has(match[2])) {
      throw new Error("Android acceptance checksum inventory is malformed");
    }
    recordedFiles.set(match[2], match[1]);
  }

  const actualFiles = new Map();
  async function walk(relativeDirectory = "") {
    const absoluteDirectory = path.join(directory, relativeDirectory);
    for (const entry of await fsp.readdir(absoluteDirectory, {withFileTypes: true})) {
      const relative = relativeDirectory ?
        path.posix.join(relativeDirectory, entry.name) : entry.name;
      if (relative === "PACKAGE_SHA256SUMS") continue;
      if (entry.isDirectory()) {
        await walk(relative);
      } else if (entry.isFile()) {
        const file = await regularFile(path.join(directory, relative),
          `Android acceptance file ${relative}`);
        actualFiles.set(relative, await sha256File(file.resolved));
      } else {
        throw new Error(`Android acceptance entry is unsafe: ${relative}`);
      }
    }
  }
  await walk();
  if (JSON.stringify([...recordedFiles.keys()].sort()) !==
      JSON.stringify([...actualFiles.keys()].sort())) {
    throw new Error("Android acceptance checksum inventory is incomplete or unexpected");
  }
  for (const [relative, digest] of actualFiles) {
    if (recordedFiles.get(relative) !== digest) {
      throw new Error(`Android acceptance file changed after preparation: ${relative}`);
    }
  }
  if (recordedFiles.get("Browser-test.apk") !== artifactHash) {
    throw new Error("Android checksum inventory does not admit this test APK");
  }
}

async function readLinuxArtifactAdmission(artifactPath, artifactHash, receiptPath) {
  if (!receiptPath) throw new Error("Linux acceptance requires a verified artifact receipt");
  const receipt = await regularFile(receiptPath, "Linux artifact receipt");
  if ((receipt.stat.mode & 0o077) !== 0) {
    throw new Error("Linux artifact receipt must not be group- or world-accessible");
  }
  const raw = await fsp.readFile(receipt.resolved, "utf8");
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    if (separator < 1) throw new Error("Linux artifact receipt is malformed");
    const key = line.slice(0, separator);
    if (values.has(key)) throw new Error("Linux artifact receipt contains duplicate keys");
    values.set(key, line.slice(separator + 1));
  }
  const expectedKeys = [
    "schema_version", "product", "platform", "arch", "source_commit",
    "helium_core_commit", "chromium_version", "chromium_commit",
    "platform_commit", "bundle", "bundle_sha256",
    "provenance_manifest_sha256", "browser_executable", "browser_sha256",
    "runtime_inventory", "runtime_inventory_sha256", "full_graph_receipt",
    "full_graph_receipt_sha256", "full_graph_inventory",
    "full_graph_inventory_sha256", "verified_at",
  ].sort();
  if (JSON.stringify([...values.keys()].sort()) !== JSON.stringify(expectedKeys)) {
    throw new Error("Linux artifact receipt has an unexpected field inventory");
  }
  const commitFields = [
    "source_commit", "helium_core_commit", "chromium_commit", "platform_commit",
  ];
  const digestFields = [
    "bundle_sha256", "provenance_manifest_sha256", "browser_sha256",
    "full_graph_receipt_sha256", "full_graph_inventory_sha256",
  ];
  if (values.get("schema_version") !== "3" ||
      values.get("product") !== LINUX_PRODUCT ||
      values.get("platform") !== "linux" || values.get("arch") !== LINUX_ARCH ||
      path.resolve(path.dirname(receipt.resolved),
        values.get("browser_executable") || "") !== artifactPath ||
      values.get("browser_sha256") !== artifactHash ||
      commitFields.some(name => !/^[0-9a-f]{40}$/.test(values.get(name) || "")) ||
      digestFields.some(name => !/^[0-9a-f]{64}$/.test(values.get(name) || ""))) {
    throw new Error("Linux artifact receipt does not admit this audited browser executable");
  }

  const inventoryRelative = values.get("runtime_inventory") || "";
  if (inventoryRelative !== `${LINUX_BUNDLE}/provenance/runtime.sha256` ||
      !/^[0-9a-f]{64}$/.test(values.get("runtime_inventory_sha256") || "")) {
    throw new Error("Linux artifact receipt has an invalid runtime inventory");
  }
  const receiptRoot = path.dirname(receipt.resolved);
  const bundleRoot = path.join(receiptRoot, LINUX_BUNDLE);
  const runtimeRoot = path.join(bundleRoot, "runtime");
  const inventory = await regularFile(
    path.join(receiptRoot, inventoryRelative), "Linux runtime inventory");
  const inventoryRaw = await fsp.readFile(inventory.resolved, "utf8");
  if (sha256(inventoryRaw) !== values.get("runtime_inventory_sha256")) {
    throw new Error("Linux runtime inventory changed after artifact verification");
  }
  const seen = new Set();
  for (const line of inventoryRaw.split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  (runtime\/.+)$/.exec(line);
    if (!match || match[2].includes("/../") || match[2].endsWith("/..") ||
        seen.has(match[2])) {
      throw new Error("Linux runtime inventory is malformed");
    }
    seen.add(match[2]);
    const runtimeFile = await regularFile(
      path.join(bundleRoot, match[2]), `Linux runtime file ${match[2]}`);
    if (!runtimeFile.resolved.startsWith(`${runtimeRoot}${path.sep}`) ||
        await sha256File(runtimeFile.resolved) !== match[1]) {
      throw new Error(`Linux runtime file changed after artifact verification: ${match[2]}`);
    }
  }
  if (!seen.has("runtime/helium") ||
      !seen.has("runtime/helium-wrapper")) {
    throw new Error("Linux runtime inventory omits the browser or launcher");
  }
  const graphRootRelative = `${LINUX_BUNDLE}/provenance/full-graph`;
  if (values.get("full_graph_receipt") !== `${graphRootRelative}/receipt.env` ||
      values.get("full_graph_inventory") !== `${graphRootRelative}/SHA256SUMS`) {
    throw new Error("Linux artifact receipt has invalid full-graph paths");
  }
  const graph = await auditLinuxFullGraphEvidence(
    path.join(receiptRoot, graphRootRelative), {
      sourceCommit: values.get("source_commit"),
      coreCommit: values.get("helium_core_commit"),
      chromiumCommit: values.get("chromium_commit"),
      platformCommit: values.get("platform_commit"),
    });
  if (graph.receiptSha256 !== values.get("full_graph_receipt_sha256") ||
      graph.inventorySha256 !== values.get("full_graph_inventory_sha256")) {
    throw new Error("Linux artifact receipt does not bind its full-graph evidence");
  }
  return {resolved: receipt.resolved, raw};
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

async function loadRun(runRoot) {
  const root = path.resolve(runRoot);
  const {value} = await readJSON(path.join(root, "run.json"), "acceptance run");
  exactKeys(value, [
    "schema_version", "run_root", "platform", "package", "artifact_path",
    "artifact_sha256", "artifact_receipt", "artifact_receipt_sha256",
    "profile_path", "created_at", "run_nonce", "expected_steps", "captures",
  ], "acceptance run");
  if (value.schema_version !== SCHEMA_VERSION || value.run_root !== root ||
      !RUN_NONCE.test(value.run_nonce) ||
      !Array.isArray(value.expected_steps) || !Array.isArray(value.captures)) {
    throw new Error("acceptance run metadata is invalid");
  }
  return {root, run: value};
}

export async function initializeRun({
  artifact, output, platform, packageName = "", artifactReceipt = "",
}) {
  if (platform !== "linux" && platform !== "android") {
    throw new Error("platform must be linux or android");
  }
  if (platform === "android" && !validAndroidTestPackage(packageName)) {
    throw new Error("Android acceptance requires a separately installable package ending in .test");
  }
  if (platform === "linux" && packageName) {
    throw new Error("Linux acceptance does not take an Android package");
  }
  const artifactInfo = await regularFile(artifact, "browser artifact");
  const artifactHash = sha256(await fsp.readFile(artifactInfo.resolved));
  if (platform === "linux" && (artifactInfo.stat.mode & 0o111) === 0) {
    throw new Error("Linux browser artifact must be the executable that will be launched");
  }
  let linuxAdmission = null;
  if (platform === "android") {
    await readPreparedAndroidAdmission(artifactInfo.resolved, artifactHash, packageName);
  } else {
    linuxAdmission = await readLinuxArtifactAdmission(
      artifactInfo.resolved, artifactHash, artifactReceipt);
  }
  const root = path.resolve(output);
  await fsp.mkdir(path.dirname(root), {recursive: true});
  await fsp.mkdir(root, {mode: 0o700});
  await fsp.mkdir(path.join(root, "screenshots"), {mode: 0o700});
  let profile = null;
  if (platform === "linux") {
    profile = path.join(root, "profile");
    await fsp.mkdir(profile, {mode: 0o700});
    await fsp.writeFile(
      path.join(profile, "SYNTHETIC_ONLY"),
      DISPOSABLE_PROFILE_MARKER,
      {mode: 0o600, flag: "wx"},
    );
  }
  const run = {
    schema_version: SCHEMA_VERSION,
    run_root: root,
    platform,
    package: packageName,
    artifact_path: artifactInfo.resolved,
    artifact_sha256: artifactHash,
    artifact_receipt: linuxAdmission?.resolved || null,
    artifact_receipt_sha256: linuxAdmission ? sha256(linuxAdmission.raw) : null,
    profile_path: profile,
    created_at: new Date().toISOString(),
    run_nonce: crypto.randomBytes(32).toString("hex"),
    expected_steps: NATIVE_PASSWORD_STEPS,
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
  const png = await fsp.readFile(resolved);
  if (!png.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
    throw new Error("native UI screenshot is not PNG");
  }
  let offset = PNG_SIGNATURE.length;
  let chunkCount = 0;
  let sawImageData = false;
  let sawEnd = false;
  while (offset < png.length) {
    if (png.length - offset < 12) throw new Error("native UI PNG chunk is truncated");
    const length = png.readUInt32BE(offset);
    const typeOffset = offset + 4;
    const dataOffset = typeOffset + 4;
    const crcOffset = dataOffset + length;
    const nextOffset = crcOffset + 4;
    if (nextOffset > png.length) throw new Error("native UI PNG chunk exceeds the file");
    const type = png.toString("ascii", typeOffset, dataOffset);
    if (!/^[A-Za-z]{4}$/.test(type)) throw new Error("native UI PNG chunk type is invalid");
    let crc = 0xffffffff;
    for (let index = typeOffset; index < crcOffset; index += 1) {
      crc = PNG_CRC_TABLE[(crc ^ png[index]) & 0xff] ^ (crc >>> 8);
    }
    if (((crc ^ 0xffffffff) >>> 0) !== png.readUInt32BE(crcOffset)) {
      throw new Error(`native UI PNG ${type} checksum is invalid`);
    }
    if (chunkCount === 0) {
      if (type !== "IHDR" || length !== 13) {
        throw new Error("native UI PNG does not start with IHDR");
      }
      const width = png.readUInt32BE(dataOffset);
      const height = png.readUInt32BE(dataOffset + 4);
      if (width < 1 || height < 1 || width > 32768 || height > 32768) {
        throw new Error("native UI PNG dimensions are invalid");
      }
    } else if (type === "IHDR") {
      throw new Error("native UI PNG contains a duplicate IHDR");
    }
    if (type === "IDAT") sawImageData = true;
    if (type === "IEND") {
      if (length !== 0 || nextOffset !== png.length) {
        throw new Error("native UI PNG has an invalid IEND");
      }
      sawEnd = true;
    }
    chunkCount += 1;
    offset = nextOffset;
  }
  if (!sawImageData || !sawEnd) throw new Error("native UI PNG is incomplete");
  return resolved;
}

export async function captureStep({runRoot, step, screenshot}) {
  const {root, run} = await loadRun(runRoot);
  const expected = NATIVE_PASSWORD_STEPS[run.captures.length];
  if (step !== expected) throw new Error(`expected acceptance step ${expected}, got ${step}`);
  const screenshotPath = await validateScreenshot(screenshot);
  const screenshotName = `${String(run.captures.length + 1).padStart(2, "0")}-${step}.png`;
  const copiedScreenshot = path.join(root, "screenshots", screenshotName);
  await fsp.copyFile(screenshotPath, copiedScreenshot, fs.constants.COPYFILE_EXCL);
  await fsp.chmod(copiedScreenshot, 0o600);
  const capture = {
    step,
    captured_at: new Date().toISOString(),
    screenshot: `screenshots/${screenshotName}`,
    screenshot_sha256: sha256(await fsp.readFile(copiedScreenshot)),
  };
  run.captures.push(capture);
  await writeJSON(path.join(root, "run.json"), run);
  return capture;
}

function equalJSON(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validateFixtureEvidence(fixtureEvidence, runNonce) {
  exactKeys(fixtureEvidence, [
    "schema_version", "completed_at", "fixture_origin", "observations",
    "evidence_contains_submitted_values", "run_nonce",
  ], "fixture evidence");
  if (fixtureEvidence.schema_version !== SCHEMA_VERSION ||
      fixtureEvidence.evidence_contains_submitted_values !== false) {
    throw new Error("fixture evidence schema or secret boundary is invalid");
  }
  if (!RUN_NONCE.test(fixtureEvidence.run_nonce) || fixtureEvidence.run_nonce !== runNonce) {
    throw new Error("fixture evidence belongs to a different acceptance run");
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
}

export function validateAcceptance(run, fixtureEvidence) {
  if (!equalJSON(run.expected_steps, NATIVE_PASSWORD_STEPS) ||
      !equalJSON(run.captures.map(item => item.step), NATIVE_PASSWORD_STEPS)) {
    throw new Error("acceptance steps are incomplete or out of order");
  }
  validateFixtureEvidence(fixtureEvidence, run.run_nonce);
  return {
    schema_version: SCHEMA_VERSION,
    result: "passed",
    artifact_sha256: run.artifact_sha256,
    artifact_receipt_sha256: run.artifact_receipt_sha256,
    platform: run.platform,
    package: run.package,
    run_nonce: run.run_nonce,
    fixture_origin: fixtureEvidence.fixture_origin,
    screenshots: run.captures.map(capture => ({
      step: capture.step,
      sha256: capture.screenshot_sha256,
    })),
  };
}

export async function auditArtifactAdmission(runRoot) {
  const {root, run} = await loadRun(runRoot);
  const artifact = await regularFile(run.artifact_path, "browser artifact");
  if (sha256(await fsp.readFile(artifact.resolved)) !== run.artifact_sha256) {
    throw new Error("browser artifact changed after acceptance initialization");
  }
  if (run.platform === "linux") {
    const marker = path.join(root, "profile", "SYNTHETIC_ONLY");
    if (run.profile_path !== path.join(root, "profile") ||
        await fsp.readFile(marker, "utf8") !== DISPOSABLE_PROFILE_MARKER) {
      throw new Error("Linux disposable profile marker is missing or invalid");
    }
    const admission = await readLinuxArtifactAdmission(
      artifact.resolved, run.artifact_sha256, run.artifact_receipt);
    if (sha256(admission.raw) !== run.artifact_receipt_sha256) {
      throw new Error("Linux artifact receipt changed after acceptance initialization");
    }
  } else if (run.platform === "android" && validAndroidTestPackage(run.package)) {
    await readPreparedAndroidAdmission(artifact.resolved, run.artifact_sha256, run.package);
  } else {
    throw new Error("acceptance platform or Android test-package boundary is invalid");
  }
  return {root, run};
}

export async function auditRun({runRoot, fixtureEvidence}) {
  const {root, run} = await auditArtifactAdmission(runRoot);
  for (const capture of run.captures) {
    exactKeys(capture, ["step", "captured_at", "screenshot", "screenshot_sha256"], `capture ${capture.step}`);
    const screenshotPath = path.resolve(root, capture.screenshot);
    const screenshotRoot = `${path.join(root, "screenshots")}${path.sep}`;
    if (!screenshotPath.startsWith(screenshotRoot)) {
      throw new Error(`screenshot path escaped the run: ${capture.step}`);
    }
    const screenshot = await validateScreenshot(screenshotPath);
    if (sha256(await fsp.readFile(screenshot)) !== capture.screenshot_sha256) {
      throw new Error(`screenshot changed after capture: ${capture.step}`);
    }
  }
  const fixture = await readJSON(fixtureEvidence, "fixture evidence");
  const receipt = validateAcceptance(run, fixture.value);
  return {
    root,
    run,
    receipt: {
      ...receipt,
      fixture_evidence_sha256: sha256(fixture.raw),
    },
  };
}

export async function verifyRun({runRoot, fixtureEvidence}) {
  const audited = await auditRun({runRoot, fixtureEvidence});
  const receipt = {...audited.receipt, verified_at: new Date().toISOString()};
  await writeJSON(path.join(audited.root, "receipt.json"), receipt, {exclusive: true});
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
  const actual = Object.keys(args).sort();
  const expected = [...names].sort();
  if (!equalJSON(actual, expected)) throw new Error(`expected arguments: ${expected.join(", ")}`);
}

function usage() {
  return `usage:
  acceptance.mjs init --artifact FILE --artifact-receipt FILE --platform linux --output NEW_DIR
  acceptance.mjs init --artifact Browser-test.apk --platform android --package APP.test --output NEW_DIR
  acceptance.mjs capture --run DIR --step STEP --screenshot PNG
  acceptance.mjs verify --run DIR --fixture-evidence JSON\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    const args = parseArgs(process.argv.slice(3));
    if (command === "init") {
      const expected = args.platform === "android" ?
        ["artifact", "platform", "package", "output"] :
        ["artifact", "artifact-receipt", "platform", "output"];
      requireArgs(args, expected);
      const run = await initializeRun({
        artifact: args.artifact,
        output: args.output,
        platform: args.platform,
        packageName: args.package || "",
        artifactReceipt: args["artifact-receipt"] || "",
      });
      process.stdout.write(`${JSON.stringify({
        event: "initialized",
        run: run.run_root,
        profile: run.profile_path,
        run_nonce: run.run_nonce,
      })}\n`);
    } else if (command === "capture") {
      requireArgs(args, ["run", "step", "screenshot"]);
      const capture = await captureStep({runRoot: args.run, step: args.step, screenshot: args.screenshot});
      process.stdout.write(`${JSON.stringify({event: "captured", step: capture.step})}\n`);
    } else if (command === "verify") {
      requireArgs(args, ["run", "fixture-evidence"]);
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
