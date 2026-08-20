#!/usr/bin/env node

import {spawn, spawnSync} from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {capturePhysicalDeviceIdentity} from
  "../android-acceptance/physical-device-identity.mjs";
import {captureLinuxHostIdentity} from
  "../sync-runtime/execution-identity.mjs";

import {
  EVIDENCE_DIRECTORY_MARKER,
  EVIDENCE_DIRECTORY_MARKER_CONTENT,
  EVIDENCE_MARKER,
  EVIDENCE_MARKER_CONTENT,
  NATIVE_ROOT_MARKER,
  NATIVE_ROOT_MARKER_CONTENT,
  atomicWrite,
  exactKeys,
  fail,
  fsyncDirectory,
  hmac,
  loadSigningKey,
  normalizeTopology,
  readAuthenticatedEvidence,
  readPrivateEnv,
  readPrivateJSON,
  requireAbsolute,
  requireMarker,
  requirePrivateDirectory,
  requirePrivateFile,
  sha256,
  sha256File,
  topologyDigest,
  validDevice,
  validSHA256,
  validSlug,
  validateEvidence,
} from "./tab-proof-lib.mjs";

const PROFILE_RESTORE_MARKER = ".helium-disposable-profile-restore-root";
const NATIVE_PROFILE_MARKER = ".helium-tab-runtime-native-profile-v1";
const NATIVE_PROFILE_MARKER_CONTENT =
  "helium-tab-runtime-native-profile-v1\n";
const NEUTRAL_PROFILE_MARKER =
  ".helium-tabs-disposable-browser-profile-v2";
const NEUTRAL_ROOT_MARKER = ".helium-tabs-disposable-root-v1";
const NEUTRAL_ROOT_MARKER_CONTENT = "helium-tabs-disposable-root-v1\n";
const PROFILE_RECEIPT = ".helium-profile-restore-receipt.env";
const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const ANDROID_PROFILE_ADAPTER = path.join(SCRIPT_DIRECTORY,
  "android-tab-profile.sh");
const ANDROID_BROWSER_BOUNDARY = path.join(SCRIPT_DIRECTORY, "..",
  "android-media", "disposable-browser.sh");
const ANDROID_PACKAGE = "computer.helium.sync.test";
const ANDROID_SOCKET = "helium_sync_test_devtools_remote";

function usage() {
  console.error(`usage:
  tab-runtime-proof.mjs native COMMON
  tab-runtime-proof.mjs neutral COMMON --helium-tabs FILE \\
    --source-receipt FILE
  tab-runtime-proof.mjs full-profile COMMON --expected-evidence DIR

COMMON:
  --browser ABSOLUTE-FILE --browser-sha256 HEX
  --package-id desktop|computer.helium.sync.test
  --display-mode headless|headed|device
  --profile-dir ABSOLUTE-DRILL-DIR
  --source-device d|da|oneplus --profile SLUG
  --evidence-dir ABSOLUTE-NEW-PROOF-DIR --signing-key FILE
  [--timeout-seconds 45]

For Android, --browser is the exact Browser-test.apk and these additional
options are required:
  --acceptance-dir ABSOLUTE-DIRECTORY --adb-serial SERIAL

Android admits only computer.helium.sync.test, oneplus, and device display.
Every install/launch remains inside the checksum-bound disposable boundary.`);
  process.exitCode = 64;
}

function parseOptions(args) {
  const options = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail("options must be --name value pairs");
    }
    if (options.has(key)) {
      fail(`duplicate option: ${key}`);
    }
    options.set(key, value);
  }
  return options;
}

function requireOptions(options, required, optional = []) {
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

function requireExecutable(file, label) {
  requireAbsolute(file, label);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (stat.mode & 0o111) === 0 || fs.realpathSync(file) !== file) {
    fail(`${label} must be an explicit real executable`);
  }
  return stat;
}

function requireRegularFile(file, label) {
  requireAbsolute(file, label);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() ||
      fs.realpathSync(file) !== file || stat.size < 1) {
    fail(`${label} must be an explicit real nonempty file`);
  }
  return stat;
}

function requireDirectDrillChild(directory, parentMarker, parentContent,
                                 label) {
  requireAbsolute(directory, label);
  const name = path.basename(directory);
  if (!/^drill-[a-z0-9][a-z0-9._-]{0,57}$/.test(name)) {
    fail(`${label} name must be a drill-* slug`);
  }
  const parent = path.dirname(directory);
  if (parentContent === null) {
    requirePrivateDirectory(parent, `${label} parent`);
    const markerPath = path.join(parent, parentMarker);
    const stat = fs.lstatSync(markerPath);
    if (!stat.isFile() || stat.isSymbolicLink() ||
        stat.size !== 0 || (stat.mode & 0o077) !== 0 ||
        (typeof process.getuid === "function" && stat.uid !== process.getuid())) {
      fail(`${label} parent has an invalid empty marker`);
    }
  } else {
    requireMarker(parent, parentMarker, parentContent, `${label} parent`);
  }
  return parent;
}

function createNativeProfile(directory, android = false) {
  const parent = requireDirectDrillChild(directory, NATIVE_ROOT_MARKER,
    NATIVE_ROOT_MARKER_CONTENT, "native disposable profile");
  if (fs.existsSync(directory)) {
    fail("native disposable profile must not exist");
  }
  fs.mkdirSync(directory, {mode: 0o700});
  try {
    if (android) {
      fs.mkdirSync(path.join(directory, "Default"), {mode: 0o700});
    }
    atomicWrite(path.join(directory, NATIVE_PROFILE_MARKER),
      NATIVE_PROFILE_MARKER_CONTENT);
    fsyncDirectory(directory);
    fsyncDirectory(parent);
  } catch (error) {
    fs.rmSync(directory, {recursive: true});
    throw error;
  }
}

function requireNeutralProfile(directory) {
  requireDirectDrillChild(directory, NEUTRAL_ROOT_MARKER,
    NEUTRAL_ROOT_MARKER_CONTENT, "neutral disposable profile");
  requirePrivateDirectory(directory, "neutral disposable profile");
  requirePrivateFile(path.join(directory, NEUTRAL_PROFILE_MARKER),
    "neutral disposable profile marker", 256);
}

function requireFullProfile(directory) {
  requireDirectDrillChild(directory, PROFILE_RESTORE_MARKER, null,
    "full-profile disposable profile");
  requirePrivateDirectory(directory, "full-profile disposable profile");
}

function createEvidenceDirectory(directory) {
  requireAbsolute(directory, "evidence directory");
  const name = path.basename(directory);
  if (!/^proof-[a-z0-9][a-z0-9._-]{0,57}$/.test(name)) {
    fail("evidence directory name must be a proof-* slug");
  }
  const parent = path.dirname(directory);
  requireMarker(parent, EVIDENCE_MARKER, EVIDENCE_MARKER_CONTENT,
    "evidence root");
  if (fs.existsSync(directory)) {
    fail("evidence directory already exists");
  }
  fs.mkdirSync(directory, {mode: 0o700});
  atomicWrite(path.join(directory, EVIDENCE_DIRECTORY_MARKER),
    EVIDENCE_DIRECTORY_MARKER_CONTENT);
}

function parseTimeout(value) {
  if (value === undefined) {
    return 45_000;
  }
  if (!/^[0-9]+$/.test(value)) {
    fail("timeout seconds is invalid");
  }
  const seconds = Number(value);
  if (!Number.isSafeInteger(seconds) || seconds < 5 || seconds > 120) {
    fail("timeout seconds must be between 5 and 120");
  }
  return seconds * 1000;
}

function withTimeout(promise, milliseconds, label) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)),
        milliseconds);
    }),
  ]).finally(() => clearTimeout(timer));
}

function strictEnv(raw, expectedKeys, label) {
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (line === "") {
      continue;
    }
    const separator = line.indexOf("=");
    if (separator < 1) {
      fail(`${label} emitted an invalid line`);
    }
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (!expectedKeys.has(key) || values.has(key) || value === "" ||
        /[\r\n\0]/.test(value)) {
      fail(`${label} emitted an invalid field`);
    }
    values.set(key, value);
  }
  if (values.size !== expectedKeys.size) {
    fail(`${label} output is incomplete`);
  }
  return values;
}

function runText(command, args, label) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 || result.signal !== null) {
    fail(`${label} failed: ${result.stderr.trim()}`);
  }
  return result.stdout;
}

function adbText(common, args, label) {
  return runText("adb", ["-s", common.adbSerial, ...args], label).trim();
}

function validateAndroidSerial(serial) {
  if (typeof serial !== "string" ||
      !/^[A-Za-z0-9._:-]+$/.test(serial)) {
    fail("ADB serial contains unsupported characters");
  }
  return serial;
}

async function readAndroidAcceptance(common, directory) {
  requireAbsolute(directory, "Android acceptance directory");
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      fs.realpathSync(directory) !== directory) {
    fail("Android acceptance directory must be an explicit real directory");
  }
  const envPath = path.join(directory, "acceptance.env");
  const sumsPath = path.join(directory, "PACKAGE_SHA256SUMS");
  requireRegularFile(envPath, "Android acceptance metadata");
  requireRegularFile(sumsPath, "Android acceptance checksum inventory");
  const keys = new Set([
    "schema_version",
    "package",
    "helium_sync_commit",
    "chromium_commit",
    "version_code",
    "version_name",
    "source_archive_sha256",
    "apk_sha256",
    "runtime_kit_sha256",
    "prepared_at",
  ]);
  const metadata = strictEnv(fs.readFileSync(envPath, "utf8"), keys,
    "Android acceptance metadata");
  if (metadata.get("schema_version") !== "2" ||
      metadata.get("package") !== ANDROID_PACKAGE ||
      !/^[0-9a-f]{40}$/.test(metadata.get("helium_sync_commit")) ||
      !/^[0-9a-f]{40}$/.test(metadata.get("chromium_commit")) ||
      !/^[1-9][0-9]*$/.test(metadata.get("version_code")) ||
      !/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(
        metadata.get("version_name"))) {
    fail("Android acceptance metadata identity is invalid");
  }
  validSHA256(metadata.get("source_archive_sha256"),
    "Android source archive SHA-256");
  validSHA256(metadata.get("runtime_kit_sha256"),
    "Android runtime kit SHA-256");
  const apkPath = path.join(directory, "Browser-test.apk");
  if (fs.realpathSync(apkPath) !== common.browser) {
    fail("Android --browser must be the acceptance Browser-test.apk");
  }
  const apkSHA256 = validSHA256(metadata.get("apk_sha256"),
    "Android APK SHA-256");
  if (apkSHA256 !== common.browserSHA256 ||
      await sha256File(apkPath) !== apkSHA256) {
    fail("Android acceptance APK does not match the pinned browser hash");
  }
  return {
    directory,
    apkSHA256,
    heliumSyncCommit: metadata.get("helium_sync_commit"),
    chromiumCommit: metadata.get("chromium_commit"),
    sourceArchiveSHA256: metadata.get("source_archive_sha256"),
    versionCode: metadata.get("version_code"),
    versionName: metadata.get("version_name"),
  };
}

function stageAndroidProfile(common, mode) {
  const output = runText(ANDROID_PROFILE_ADAPTER, [
    "stage",
    common.acceptance.directory,
    common.adbSerial,
    mode,
    common.profileDir,
  ], "Android tab profile stage");
  const fields = strictEnv(output, new Set([
    "operation",
    "package",
    "mode",
    "local_profile",
    "device_profile",
    "apk_sha256",
    "profile_tree_sha256",
    "binding_sha256",
  ]), "Android tab profile stage");
  if (fields.get("operation") !== "stage" ||
      fields.get("package") !== ANDROID_PACKAGE ||
      fields.get("mode") !== mode ||
      fields.get("local_profile") !== common.profileDir ||
      fields.get("apk_sha256") !== common.browserSHA256) {
    fail("Android tab profile stage identity is invalid");
  }
  const deviceProfile = fields.get("device_profile");
  const dataPrefix = `/data/user/0/${ANDROID_PACKAGE}`;
  const expectedSuffix = mode === "native"
    ? "/app_chrome"
    : `/helium-tab-runtime-${mode}/${path.basename(common.profileDir)}`;
  if (deviceProfile !== `${dataPrefix}${expectedSuffix}`) {
    fail("Android tab profile stage returned an unexpected device path");
  }
  return {
    deviceProfile,
    profileTreeSHA256: validSHA256(fields.get("profile_tree_sha256"),
      "staged Android profile SHA-256"),
    bindingSHA256: validSHA256(fields.get("binding_sha256"),
      "staged Android marker or receipt SHA-256"),
    receiptSHA256: sha256(Buffer.from(output)),
  };
}

function fetchAndroidNeutralState(common, expectedDeviceProfile) {
  const output = runText(ANDROID_PROFILE_ADAPTER, [
    "fetch-neutral",
    common.acceptance.directory,
    common.adbSerial,
    "neutral",
    common.profileDir,
  ], "Android neutral state fetch");
  const fields = strictEnv(output, new Set([
    "operation",
    "package",
    "mode",
    "local_profile",
    "device_profile",
    "native_receipt_sha256",
  ]), "Android neutral state fetch");
  if (fields.get("operation") !== "fetch-neutral" ||
      fields.get("package") !== ANDROID_PACKAGE ||
      fields.get("mode") !== "neutral" ||
      fields.get("local_profile") !== common.profileDir ||
      fields.get("device_profile") !== expectedDeviceProfile) {
    fail("Android neutral state fetch identity is invalid");
  }
  return validSHA256(fields.get("native_receipt_sha256"),
    "Android neutral native receipt SHA-256");
}

class CDPBrowser {
  constructor(child, timeout) {
    this.child = child;
    this.timeout = timeout;
    this.nextID = 1;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.stderr = Buffer.alloc(0);
    this.exited = new Promise(resolve => {
      child.once("exit", (code, signal) => {
        const error = new Error(
          `browser exited before CDP completion (code=${code}, signal=${signal})`);
        for (const pending of this.pending.values()) {
          pending.reject(error);
        }
        this.pending.clear();
        resolve({code, signal});
      });
    });
    child.stdio[4].on("data", chunk => this.consume(chunk));
    child.stdio[4].on("error", error => this.rejectAll(error));
    child.stderr.on("data", chunk => {
      this.stderr = Buffer.concat([this.stderr, chunk]).subarray(-65536);
    });
  }

  consume(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const boundary = this.buffer.indexOf(0);
      if (boundary < 0) {
        break;
      }
      const raw = this.buffer.subarray(0, boundary);
      this.buffer = this.buffer.subarray(boundary + 1);
      if (raw.length === 0) {
        continue;
      }
      let message;
      try {
        message = JSON.parse(raw);
      } catch {
        this.rejectAll(new Error("browser emitted invalid CDP JSON"));
        continue;
      }
      if (!Number.isInteger(message.id) || !this.pending.has(message.id)) {
        continue;
      }
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(
          `${pending.method}: ${message.error.message ?? "CDP error"}`));
      } else {
        pending.resolve(message.result ?? {});
      }
    }
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }

  request(method, params = {}, sessionId) {
    const id = this.nextID++;
    const message = {id, method, params};
    if (sessionId !== undefined) {
      message.sessionId = sessionId;
    }
    const promise = new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject, method});
      this.child.stdio[3].write(`${JSON.stringify(message)}\0`, error => {
        if (error && this.pending.has(id)) {
          this.pending.delete(id);
          reject(error);
        }
      });
    });
    return withTimeout(promise, this.timeout, method);
  }

  async close() {
    const request = this.request("Browser.close").catch(() => undefined);
    await Promise.race([request, this.exited]);
    let result = await Promise.race([
      this.exited,
      new Promise(resolve => setTimeout(() => resolve(null), 5000)),
    ]);
    if (result === null) {
      this.child.kill("SIGTERM");
      result = await withTimeout(this.exited, 5000, "browser clean exit");
    }
    if (result.signal !== null || result.code !== 0) {
      fail(`browser did not close cleanly (code=${result.code}, signal=${result.signal})`);
    }
  }

  async crash() {
    if (!this.child.kill("SIGKILL")) {
      fail("failed to crash disposable browser");
    }
    const result = await withTimeout(this.exited, 5000, "browser crash exit");
    if (result.signal !== "SIGKILL") {
      fail(`browser crash was not SIGKILL (code=${result.code}, signal=${result.signal})`);
    }
  }

  async stopAfterFailure() {
    if (this.child.exitCode === null && this.child.signalCode === null) {
      this.child.kill("SIGKILL");
      await this.exited;
    }
  }
}

function androidPID(common) {
  const value = adbText(common, ["shell", `pidof ${ANDROID_PACKAGE} || true`],
    "Android package PID query");
  if (value === "") {
    return "";
  }
  if (!/^[1-9][0-9]*$/.test(value)) {
    fail("Android disposable package does not have one exact main PID");
  }
  return value;
}

async function waitForAndroidExit(common, expectedPID, label) {
  const deadline = Date.now() + Math.min(common.timeout, 15_000);
  while (Date.now() < deadline) {
    const current = androidPID(common);
    if (current === "") {
      return;
    }
    if (current !== expectedPID) {
      fail(`${label} replaced the disposable browser main process`);
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  fail(`${label} did not stop the disposable browser`);
}

function removeAndroidForward(common, port, required = true) {
  const result = spawnSync("adb", [
    "-s", common.adbSerial, "forward", "--remove", `tcp:${port}`,
  ], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
  if (required && (result.status !== 0 || result.signal !== null)) {
    fail(`Android CDP forward removal failed: ${result.stderr.trim()}`);
  }
}

class AndroidCDPBrowser {
  constructor(common, socket, pid, forwardPort) {
    this.common = common;
    this.socket = socket;
    this.pid = pid;
    this.forwardPort = forwardPort;
    this.nextID = 1;
    this.pending = new Map();
    this.forwardRemoved = false;
    this.closed = new Promise(resolve => {
      socket.onclose = () => {
        const error = new Error("Android browser CDP socket closed");
        this.rejectAll(error);
        resolve();
      };
    });
    socket.onmessage = event => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        this.rejectAll(new Error("Android browser emitted invalid CDP JSON"));
        return;
      }
      if (!Number.isInteger(message.id) || !this.pending.has(message.id)) {
        return;
      }
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(
          `${pending.method}: ${message.error.message ?? "CDP error"}`));
      } else {
        pending.resolve(message.result ?? {});
      }
    };
    socket.onerror = () => {
      this.rejectAll(new Error("Android browser CDP socket failed"));
    };
  }

  rejectAll(error) {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }

  request(method, params = {}, sessionId) {
    const id = this.nextID++;
    const message = {id, method, params};
    if (sessionId !== undefined) {
      message.sessionId = sessionId;
    }
    const promise = new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject, method});
      try {
        this.socket.send(JSON.stringify(message));
      } catch (error) {
        this.pending.delete(id);
        reject(error);
      }
    });
    return withTimeout(promise, this.common.timeout, method);
  }

  removeForward(required = true) {
    if (!this.forwardRemoved) {
      removeAndroidForward(this.common, this.forwardPort, required);
      this.forwardRemoved = true;
    }
  }

  async close() {
    const closeRequest = this.request("Browser.close").catch(() => undefined);
    await Promise.race([
      closeRequest,
      this.closed,
      new Promise(resolve => setTimeout(resolve, 5000)),
    ]);
    await waitForAndroidExit(this.common, this.pid,
      "Android Browser.close");
    this.socket.close();
    this.removeForward();
  }

  async crash() {
    const result = spawnSync("adb", [
      "-s", this.common.adbSerial, "exec-out", "run-as", ANDROID_PACKAGE,
      "kill", "-9", this.pid,
    ], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
    if (result.status !== 0 || result.signal !== null) {
      fail(`failed to crash Android disposable browser: ${result.stderr.trim()}`);
    }
    await waitForAndroidExit(this.common, this.pid, "Android same-UID SIGKILL");
    this.socket.close();
    this.removeForward();
  }

  async stopAfterFailure() {
    spawnSync("adb", [
      "-s", this.common.adbSerial, "shell", "am", "force-stop",
      ANDROID_PACKAGE,
    ], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
    this.socket.close();
    this.removeForward(false);
  }
}

async function connectWebSocket(url, timeout) {
  if (typeof WebSocket !== "function") {
    fail("this Node runtime has no WebSocket implementation");
  }
  const socket = new WebSocket(url);
  await withTimeout(new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error("Android CDP WebSocket failed"));
  }), timeout, "Android CDP WebSocket connection");
  return socket;
}

async function fetchAndroidVersion(port, timeout) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const value = await response.json();
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        fail("Android CDP version endpoint is invalid");
      }
      return value;
    } catch (error) {
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  throw new Error(`Android CDP version endpoint did not become ready: ${lastError?.message ?? "unknown error"}`);
}

function requireSingleArgument(argumentsList, expected, label) {
  if (argumentsList.filter(value => value === expected).length !== 1) {
    fail(`Android browser command line has invalid ${label}`);
  }
}

function validateAndroidCommandLine(argumentsList, common, restore) {
  if (!Array.isArray(argumentsList) ||
      argumentsList.some(value => typeof value !== "string")) {
    fail("Android browser command line evidence is unavailable");
  }
  requireSingleArgument(argumentsList, "--enable-automation",
    "automation switch");
  requireSingleArgument(argumentsList,
    `--remote-debugging-socket-name=${ANDROID_SOCKET}`,
    "DevTools socket switch");
  requireSingleArgument(argumentsList,
    `--user-data-dir=${common.androidStage.deviceProfile}`,
    "user-data-dir switch");
  requireSingleArgument(argumentsList, "--no-first-run", "first-run switch");
  requireSingleArgument(argumentsList, "--no-default-browser-check",
    "default-browser switch");
  if (argumentsList.some(value => value === "--remote-debugging-pipe" ||
      value.startsWith("--remote-debugging-port="))) {
    fail("Android tab runtime exposed an unadmitted debugging transport");
  }
  const nativeRestores = argumentsList.filter(value =>
    value === "--restore-last-session");
  const neutralRestores = argumentsList.filter(value =>
    value.startsWith("--helium-restore-disposable-tabs="));
  if (restore === "none" &&
      (nativeRestores.length !== 0 || neutralRestores.length !== 0)) {
    fail("initial Android native launch unexpectedly requested restore");
  }
  if (restore === "native" &&
      (nativeRestores.length !== 1 || neutralRestores.length !== 0)) {
    fail("Android native session restore switch is invalid");
  }
  if (restore === "neutral" &&
      (nativeRestores.length !== 0 || neutralRestores.length !== 1 ||
       neutralRestores[0] !== "--helium-restore-disposable-tabs=oneplus")) {
    fail("Android neutral importer switch is invalid");
  }
}

async function launchDesktopBrowser(common, extraArgs = []) {
  const args = [
    `--user-data-dir=${common.profileDir}`,
    "--remote-debugging-pipe",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-sync",
    "--disable-breakpad",
  ];
  if (common.displayMode === "headless") {
    args.push("--headless=new");
  }
  args.push(...extraArgs);
  const child = spawn(common.browser, args, {
    cwd: path.dirname(common.profileDir),
    env: process.env,
    stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"],
  });
  const browser = new CDPBrowser(child, common.timeout);
  try {
    const version = await browser.request("Browser.getVersion");
    exactKeys(version, [
      "protocolVersion",
      "product",
      "revision",
      "userAgent",
      "jsVersion",
    ], "CDP browser version");
    return {browser, version};
  } catch (error) {
    await browser.stopAfterFailure();
    throw error;
  }
}

async function launchAndroidBrowser(common, mode, restore) {
  if (!common.androidStage) {
    fail("Android profile was not staged before launch");
  }
  let forwardPort;
  let browser;
  try {
    const output = runText(ANDROID_BROWSER_BOUNDARY, [
      "launch",
      common.acceptance.directory,
      common.adbSerial,
      "--tab-runtime-profile",
      path.basename(common.profileDir),
      "--tab-runtime-mode",
      mode,
      "--tab-runtime-restore",
      restore,
    ], "Android disposable browser launch");
    const fields = strictEnv(output, new Set([
      "operation",
      "package",
      "apk_sha256",
      "device_socket",
      "command_line_sha256",
      "tab_runtime_mode",
      "tab_runtime_user_data_dir",
      "tab_runtime_restore",
    ]), "Android disposable browser launch");
    if (fields.get("operation") !== "launch" ||
        fields.get("package") !== ANDROID_PACKAGE ||
        fields.get("apk_sha256") !== common.browserSHA256 ||
        fields.get("device_socket") !== ANDROID_SOCKET ||
        fields.get("tab_runtime_mode") !== mode ||
        fields.get("tab_runtime_user_data_dir") !==
          common.androidStage.deviceProfile ||
        fields.get("tab_runtime_restore") !== restore) {
      fail("Android disposable browser launch identity is invalid");
    }
    validSHA256(fields.get("command_line_sha256"),
      "Android command-line SHA-256");
    const portRaw = adbText(common, [
      "forward", "tcp:0", `localabstract:${ANDROID_SOCKET}`,
    ], "Android CDP forward");
    if (!/^[1-9][0-9]{3,4}$/.test(portRaw)) {
      fail("Android CDP forward returned an invalid local port");
    }
    forwardPort = Number(portRaw);
    if (!Number.isSafeInteger(forwardPort) || forwardPort > 65535) {
      fail("Android CDP forward returned an out-of-range local port");
    }
    const forwarding = adbText(common, ["forward", "--list"],
      "Android CDP forward inventory").split("\n");
    if (forwarding.filter(line =>
      line === `${common.adbSerial} tcp:${forwardPort} localabstract:${ANDROID_SOCKET}`
    ).length !== 1) {
      fail("Android CDP forward inventory does not contain the exact socket");
    }
    const browserInfo = await fetchAndroidVersion(forwardPort, common.timeout);
    if (browserInfo["Android-Package"] !== ANDROID_PACKAGE ||
        typeof browserInfo["WebKit-Version"] !== "string" ||
        !browserInfo["WebKit-Version"].includes(
          `@${common.acceptance.chromiumCommit}`)) {
      fail("Android CDP endpoint does not match the admitted package revision");
    }
    const webSocketURL = new URL(browserInfo.webSocketDebuggerUrl ?? "");
    if (webSocketURL.protocol !== "ws:" ||
        !["127.0.0.1", "localhost", "[::1]"].includes(webSocketURL.hostname) ||
        Number(webSocketURL.port) !== forwardPort) {
      fail("Android CDP endpoint returned a non-loopback browser WebSocket");
    }
    const socket = await connectWebSocket(webSocketURL.href, common.timeout);
    const pid = androidPID(common);
    if (pid === "") {
      socket.close();
      fail("Android disposable browser exited before CDP admission");
    }
    browser = new AndroidCDPBrowser(common, socket, pid, forwardPort);
    const version = await browser.request("Browser.getVersion");
    exactKeys(version, [
      "protocolVersion",
      "product",
      "revision",
      "userAgent",
      "jsVersion",
    ], "CDP browser version");
    const commandLine = await browser.request("Browser.getBrowserCommandLine");
    exactKeys(commandLine, ["arguments"], "Android browser command line");
    validateAndroidCommandLine(commandLine.arguments, common, restore);
    return {browser, version};
  } catch (error) {
    if (browser) {
      await browser.stopAfterFailure();
    } else {
      spawnSync("adb", [
        "-s", common.adbSerial, "shell", "am", "force-stop",
        ANDROID_PACKAGE,
      ], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
      if (forwardPort !== undefined) {
        removeAndroidForward(common, forwardPort, false);
      }
    }
    throw error;
  }
}

async function launchBrowser(common, options = {}) {
  if (common.platform === "android") {
    return launchAndroidBrowser(common, options.mode, options.restore);
  }
  return launchDesktopBrowser(common, options.desktopArgs ?? []);
}

async function readTopology(browser, expected, platform) {
  const result = await browser.request("Target.getTargets");
  if (!Array.isArray(result.targetInfos)) {
    fail("CDP target inventory is invalid");
  }
  const pages = result.targetInfos.filter(target => target.type === "page");
  if (pages.length !== expected.tab_count) {
    fail(`CDP tab count mismatch: got ${pages.length}, expected ${expected.tab_count}`);
  }
  const windows = new Map();
  for (const target of pages) {
    if (typeof target.targetId !== "string" || typeof target.url !== "string") {
      fail("CDP page target is invalid");
    }
    let windowID = "android-window";
    if (platform === "desktop") {
      const window = await browser.request("Browser.getWindowForTarget",
        {targetId: target.targetId});
      if (!Number.isSafeInteger(window.windowId)) {
        fail("CDP window identity is invalid");
      }
      windowID = window.windowId;
    }
    const urls = windows.get(windowID) ?? [];
    urls.push(target.url);
    windows.set(windowID, urls);
  }
  const topology = normalizeTopology({
    schema_version: 1,
    windows: [...windows.values()].map(urls => ({urls})),
  }, "live CDP topology");
  if (JSON.stringify(topology) !== JSON.stringify(expected)) {
    fail("live CDP topology does not match expected window/URL topology");
  }
  return topology;
}

async function waitForTopology(browser, expected, timeout, platform) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await readTopology(browser, expected, platform);
    } catch (error) {
      lastError = error;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  throw new Error(`topology did not converge: ${lastError?.message ?? "unknown error"}`);
}

function step(name, topology, browserExit) {
  return {
    name,
    completed_unix: Math.floor(Date.now() / 1000),
    topology_sha256: topologyDigest(topology),
    window_count: topology.window_count,
    tab_count: topology.tab_count,
    browser_exit: browserExit,
  };
}

function sameVersion(expected, actual) {
  for (const key of [
    "protocolVersion",
    "product",
    "revision",
    "userAgent",
    "jsVersion",
  ]) {
    if (expected[key] !== actual[key]) {
      fail("browser version changed within one runtime proof");
    }
  }
}

async function navigateTarget(browser, targetId, url) {
  const attached = await browser.request("Target.attachToTarget",
    {targetId, flatten: true});
  if (typeof attached.sessionId !== "string") {
    fail("CDP target attachment failed");
  }
  await browser.request("Page.enable", {}, attached.sessionId);
  const navigated = await browser.request("Page.navigate", {url},
    attached.sessionId);
  if (navigated.errorText) {
    fail(`fixture navigation failed: ${navigated.errorText}`);
  }
}

async function setNativeFixture(browser, expected, platform) {
  const inventory = await browser.request("Target.getTargets");
  const pages = inventory.targetInfos.filter(target => target.type === "page");
  if (pages.length < 1) {
    fail("browser did not create an initial disposable page");
  }
  await navigateTarget(browser, pages[0].targetId,
    expected.windows[0].urls[0]);
  for (const target of pages.slice(1)) {
    await browser.request("Target.closeTarget", {targetId: target.targetId});
  }
  for (let windowIndex = 0;
       windowIndex < expected.windows.length;
       windowIndex += 1) {
    const urls = expected.windows[windowIndex].urls;
    const firstTab = windowIndex === 0 ? 1 : 0;
    for (let tabIndex = firstTab; tabIndex < urls.length; tabIndex += 1) {
      const created = await browser.request("Target.createTarget", {
        url: urls[tabIndex],
        newWindow: platform === "desktop" &&
          windowIndex > 0 && tabIndex === 0,
        background: true,
      });
      if (typeof created.targetId !== "string") {
        fail("CDP fixture tab creation failed");
      }
    }
  }
}

async function fixtureServer(common) {
  const pages = new Map([
    ["/alpha", "<title>Helium tab alpha</title><h1>alpha</h1>"],
    ["/bravo", "<title>Helium tab bravo</title><h1>bravo</h1>"],
    ["/charlie", "<title>Helium tab charlie</title><h1>charlie</h1>"],
  ]);
  const server = http.createServer((request, response) => {
    if (!pages.has(request.url)) {
      response.writeHead(404, {"content-type": "text/plain"});
      response.end("not found\n");
      return;
    }
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    response.end(`<!doctype html>${pages.get(request.url)}`);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;
  const urls = [...pages.keys()].map(item => `${origin}${item}`);
  const topology = normalizeTopology({
    schema_version: 1,
    windows: common.platform === "android"
      ? [{urls}]
      : [{urls: urls.slice(0, 2)}, {urls: urls.slice(2)}],
  });
  let reverseCreated = false;
  if (common.platform === "android") {
    try {
      adbText(common, [
        "reverse", "--no-rebind", `tcp:${address.port}`,
        `tcp:${address.port}`,
      ], "Android tab fixture reverse");
      reverseCreated = true;
    } catch (error) {
      await new Promise(resolve => server.close(resolve));
      throw error;
    }
  }
  return {
    server,
    origin,
    topology,
    close: async () => {
      if (reverseCreated) {
        const result = spawnSync("adb", [
          "-s", common.adbSerial, "reverse", "--remove",
          `tcp:${address.port}`,
        ], {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
        if (result.status !== 0 || result.signal !== null) {
          fail(`Android tab fixture reverse removal failed: ${result.stderr.trim()}`);
        }
      }
      await new Promise((resolve, reject) =>
        server.close(error => error ? reject(error) : resolve()));
    },
  };
}

function topologyFromNeutralSession(session) {
  if (!session || session.schema_version !== 2 ||
      !Array.isArray(session.windows)) {
    fail("neutral source session schema is invalid");
  }
  return normalizeTopology({
    schema_version: 1,
    windows: session.windows.map(window => ({
      urls: window.tabs.map(tab => {
        if (!Number.isSafeInteger(tab.current_index) ||
            !Array.isArray(tab.navigations) ||
            !tab.navigations[tab.current_index] ||
            typeof tab.navigations[tab.current_index].url !== "string") {
          fail("neutral source has an invalid current navigation");
        }
        return tab.navigations[tab.current_index].url;
      }),
    })),
  }, "neutral source topology");
}

function runHeliumTabs(binary, args, label) {
  const result = spawnSync(binary, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 || result.signal !== null) {
    fail(`${label} failed: ${result.stderr.trim()}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    fail(`${label} emitted invalid JSON`);
  }
}

async function runNative(common) {
  createNativeProfile(common.profileDir, common.platform === "android");
  if (common.platform === "android") {
    common.androidStage = stageAndroidProfile(common, "native");
  }
  const fixture = await fixtureServer(common);
  let active;
  try {
    const first = await launchBrowser(common, {
      mode: "native",
      restore: "none",
    });
    active = first.browser;
    await setNativeFixture(first.browser, fixture.topology, common.platform);
    const initial = await waitForTopology(first.browser, fixture.topology,
      common.timeout, common.platform);
    await first.browser.close();
    active = undefined;

    const clean = await launchBrowser(common, {
      mode: "native",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = clean.browser;
    sameVersion(first.version, clean.version);
    const cleanTopology = await waitForTopology(clean.browser, fixture.topology,
      common.timeout, common.platform);
    await clean.browser.crash();
    active = undefined;

    const crash = await launchBrowser(common, {
      mode: "native",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = crash.browser;
    sameVersion(first.version, crash.version);
    const crashTopology = await waitForTopology(crash.browser, fixture.topology,
      common.timeout, common.platform);
    await crash.browser.close();
    active = undefined;

    const second = await launchBrowser(common, {
      mode: "native",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser,
      fixture.topology, common.timeout, common.platform);
    await second.browser.close();
    active = undefined;

    return {
      version: first.version,
      expectedTopology: fixture.topology,
      generation: `native-${Math.floor(Date.now() / 1000)}-${topologyDigest(fixture.topology).slice(0, 16)}`,
      profileMarker: NATIVE_PROFILE_MARKER,
      androidStage: common.androidStage,
      sourceBinding: {
        fixture_sha256: sha256(Buffer.from(
          `${JSON.stringify(fixture.topology)}\n`)),
        fixture_origin: fixture.origin,
      },
      steps: [
        step("initial-created", initial, "clean"),
        step("clean-restart", cleanTopology, "crash"),
        step("crash-restart", crashTopology, "clean"),
        step("second-restart", secondTopology, "clean"),
      ],
    };
  } finally {
    if (active) {
      await active.stopAfterFailure();
    }
    await fixture.close();
  }
}

async function runNeutral(common, heliumTabs, sourceReceiptPath) {
  requireNeutralProfile(common.profileDir);
  const toolStat = requireExecutable(heliumTabs, "helium-tabs");
  if (toolStat.size < 1) {
    fail("helium-tabs is empty");
  }
  const manifest = runHeliumTabs(heliumTabs, [
    "validate-browser-profile",
    "--profile-dir",
    common.profileDir,
  ], "neutral pre-launch validation");
  if (manifest.source_device !== common.device ||
      manifest.source_profile !== common.profile) {
    fail("neutral profile namespace does not match requested proof");
  }
  const source = readPrivateJSON(
    path.join(common.profileDir, "restore-source", "session.json"),
    "neutral source session", 16 * 1024 * 1024);
  const expected = topologyFromNeutralSession(source.value);
  const sourceReceipt = readPrivateEnv(sourceReceiptPath, new Set([
    "schema_version",
    "mechanism",
    "source_device",
    "profile",
    "generation",
    "source_destination",
    "archive_sha256",
    "backup_manifest_sha256",
    "restore_session_sha256",
    "restored_at",
  ]), "neutral off-device source receipt");
  if (sourceReceipt.get("schema_version") !== "1" ||
      sourceReceipt.get("mechanism") !== "neutral-topology" ||
      sourceReceipt.get("source_device") !== common.device ||
      sourceReceipt.get("profile") !== common.profile ||
      sourceReceipt.get("generation") !== manifest.source_generation ||
      sourceReceipt.get("restore_session_sha256") !==
        manifest.source_session.sha256 ||
      Number.isNaN(Date.parse(sourceReceipt.get("restored_at")))) {
    fail("neutral off-device source receipt does not match the prepared profile");
  }
  validSlug(sourceReceipt.get("source_destination"),
    "neutral source destination");
  validSHA256(sourceReceipt.get("archive_sha256"),
    "neutral archive SHA-256");
  validSHA256(sourceReceipt.get("backup_manifest_sha256"),
    "neutral backup manifest SHA-256");
  if (common.platform === "android") {
    if (expected.window_count !== 1) {
      fail("Android neutral proof requires one native browser window");
    }
    common.androidStage = stageAndroidProfile(common, "neutral");
  }
  let active;
  try {
    const first = await launchBrowser(common, {
      mode: "neutral",
      restore: "neutral",
      desktopArgs: [`--helium-restore-disposable-tabs=${common.device}`],
    });
    active = first.browser;
    const firstTopology = await waitForTopology(first.browser, expected,
      common.timeout, common.platform);
    await first.browser.close();
    active = undefined;
    let fetchedReceiptSHA256;
    if (common.platform === "android") {
      fetchedReceiptSHA256 = fetchAndroidNeutralState(common,
        common.androidStage.deviceProfile);
    }
    const state = runHeliumTabs(heliumTabs, [
      "validate-browser-state",
      "--destination",
      common.profileDir,
    ], "neutral native receipt validation");
    if (state.marker !== ".helium-tabs-restore-consumed-v2" ||
        state.receipt?.state !== "applied" ||
        state.receipt?.readback_validation !==
          "exact-supported-live-topology") {
      fail("neutral native importer did not reach an applied terminal state");
    }
    const receiptPath = path.join(common.profileDir,
      ".helium-tabs-restore-receipt-v2.json");
    requirePrivateFile(receiptPath, "neutral native receipt", 64 * 1024);
    const nativeReceiptSHA256 = await sha256File(receiptPath);
    if (fetchedReceiptSHA256 !== undefined &&
        fetchedReceiptSHA256 !== nativeReceiptSHA256) {
      fail("fetched Android neutral receipt hash changed before validation");
    }

    const second = await launchBrowser(common, {
      mode: "neutral",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser, expected,
      common.timeout, common.platform);
    await second.browser.close();
    active = undefined;
    return {
      version: first.version,
      expectedTopology: expected,
      generation: manifest.source_generation,
      profileMarker: NEUTRAL_PROFILE_MARKER,
      androidStage: common.androidStage,
      sourceBinding: {
        source_generation: manifest.source_generation,
        source_session_sha256: manifest.source_session.sha256,
        source_destination: sourceReceipt.get("source_destination"),
        archive_sha256: sourceReceipt.get("archive_sha256"),
        backup_manifest_sha256:
          sourceReceipt.get("backup_manifest_sha256"),
        source_receipt_sha256: await sha256File(sourceReceiptPath),
        native_receipt_sha256: nativeReceiptSHA256,
        native_validation: state.receipt.readback_validation,
      },
      steps: [
        step("first-import", firstTopology, "clean"),
        step("second-restart", secondTopology, "clean"),
      ],
    };
  } finally {
    if (active) {
      await active.stopAfterFailure();
    }
  }
}

async function runFullProfile(common, expectedEvidenceDirectory, signingKey) {
  requireFullProfile(common.profileDir);
  const expectedEvidence = readAuthenticatedEvidence(
    expectedEvidenceDirectory, signingKey);
  if (expectedEvidence.value.mechanism !== "chromium-native-session" ||
      expectedEvidence.value.source_device !== common.device ||
      expectedEvidence.value.profile !== common.profile ||
      expectedEvidence.value.browser.sha256 !== common.browserSHA256 ||
      expectedEvidence.value.platform !== common.platform ||
      expectedEvidence.value.package_id !== common.packageID ||
      (common.platform === "android" &&
       expectedEvidence.value.browser.source_archive_sha256 !==
         common.acceptance.sourceArchiveSHA256)) {
    fail("full-profile expectation must be an authenticated matching native proof");
  }
  const receiptPath = path.join(common.profileDir, PROFILE_RECEIPT);
  const fields = readPrivateEnv(receiptPath, new Set([
    "schema_version",
    "generation",
    "source_device",
    "profile_id",
    "archive_sha256",
    "source_destination",
    "restored_at",
  ]), "full-profile restore receipt");
  if (fields.get("schema_version") !== "3" ||
      fields.get("source_device") !== common.device ||
      fields.get("profile_id") !== common.profile ||
      Number.isNaN(Date.parse(fields.get("restored_at")))) {
    fail("full-profile restore receipt namespace is invalid");
  }
  validSHA256(fields.get("archive_sha256"),
    "full-profile receipt archive SHA-256");
  validSlug(fields.get("source_destination"),
    "full-profile source destination");
  const expected = expectedEvidence.value.expected_topology;
  if (common.platform === "android") {
    if (expected.window_count !== 1) {
      fail("Android full-profile proof requires one native browser window");
    }
    common.androidStage = stageAndroidProfile(common, "full-profile");
  }
  let active;
  try {
    const first = await launchBrowser(common, {
      mode: "full-profile",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = first.browser;
    const firstTopology = await waitForTopology(first.browser, expected,
      common.timeout, common.platform);
    await first.browser.close();
    active = undefined;

    const second = await launchBrowser(common, {
      mode: "full-profile",
      restore: "native",
      desktopArgs: ["--restore-last-session"],
    });
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser, expected,
      common.timeout, common.platform);
    await second.browser.close();
    active = undefined;
    return {
      version: first.version,
      expectedTopology: expected,
      generation: fields.get("generation"),
      profileMarker: PROFILE_RECEIPT,
      androidStage: common.androidStage,
      sourceBinding: {
        generation: fields.get("generation"),
        source_destination: fields.get("source_destination"),
        archive_sha256: fields.get("archive_sha256"),
        restore_receipt_sha256: await sha256File(receiptPath),
        expected_evidence_sha256: expectedEvidence.sha256,
      },
      steps: [
        step("first-restore-start", firstTopology, "clean"),
        step("second-restart", secondTopology, "clean"),
      ],
    };
  } finally {
    if (active) {
      await active.stopAfterFailure();
    }
  }
}

async function main(command, options) {
  const commonRequired = [
    "--browser",
    "--browser-sha256",
    "--package-id",
    "--display-mode",
    "--profile-dir",
    "--source-device",
    "--profile",
    "--evidence-dir",
    "--signing-key",
  ];
  const extras = command === "neutral"
    ? ["--helium-tabs", "--source-receipt"]
    : command === "full-profile"
      ? ["--expected-evidence"]
      : [];
  requireOptions(options, [...commonRequired, ...extras], [
    "--timeout-seconds",
    "--acceptance-dir",
    "--adb-serial",
  ]);

  const packageID = options.get("--package-id");
  if (!["desktop", ANDROID_PACKAGE].includes(packageID)) {
    fail("package identity is not admitted");
  }
  const platform = packageID === "desktop" ? "desktop" : "android";
  const displayMode = options.get("--display-mode");
  if ((platform === "desktop" &&
       !["headless", "headed"].includes(displayMode)) ||
      (platform === "android" && displayMode !== "device")) {
    fail("display mode does not match the admitted platform");
  }
  const browser = options.get("--browser");
  const browserStat = platform === "desktop"
    ? requireExecutable(browser, "browser")
    : requireRegularFile(browser, "Android APK");
  const browserSHA256 = validSHA256(options.get("--browser-sha256"),
    "expected browser SHA-256");
  if (await sha256File(browser) !== browserSHA256) {
    fail("browser SHA-256 does not match the pinned artifact");
  }
  const device = validDevice(options.get("--source-device"));
  if (platform === "android" && device !== "oneplus") {
    fail("Android runtime proof is bound to source device oneplus");
  }
  const profile = validSlug(options.get("--profile"), "profile");
  const profileDir = requireAbsolute(options.get("--profile-dir"),
    "disposable profile");
  const evidenceDir = requireAbsolute(options.get("--evidence-dir"),
    "evidence directory");
  const signingKey = loadSigningKey(options.get("--signing-key"));
  const common = {
    browser,
    browserSHA256,
    browserStat,
    packageID,
    platform,
    profileDir,
    device,
    profile,
    displayMode,
    timeout: parseTimeout(options.get("--timeout-seconds")),
  };
  if (platform === "android") {
    if (!options.has("--acceptance-dir") || !options.has("--adb-serial")) {
      fail("Android runtime proof requires acceptance-dir and adb-serial");
    }
    common.adbSerial = validateAndroidSerial(options.get("--adb-serial"));
    common.acceptance = await readAndroidAcceptance(common,
      options.get("--acceptance-dir"));
    common.runtimeProofSHA256 = await sha256File(fileURLToPath(import.meta.url));
    common.profileAdapterSHA256 = await sha256File(ANDROID_PROFILE_ADAPTER);
    common.browserBoundarySHA256 = await sha256File(ANDROID_BROWSER_BOUNDARY);
    common.executionIdentity = capturePhysicalDeviceIdentity(common.adbSerial);
  } else if (options.has("--acceptance-dir") || options.has("--adb-serial")) {
    fail("desktop runtime proof rejects Android adapter options");
  } else {
    common.executionIdentity = captureLinuxHostIdentity(device);
  }

  let result;
  if (command === "native") {
    result = await runNative(common);
  } else if (command === "neutral") {
    result = await runNeutral(common, options.get("--helium-tabs"),
      options.get("--source-receipt"));
  } else if (command === "full-profile") {
    result = await runFullProfile(common, options.get("--expected-evidence"),
      signingKey);
  } else {
    fail("unknown runtime proof mechanism");
  }
  const mechanism = command === "native"
    ? "chromium-native-session"
    : command === "neutral" ? "neutral-topology" : "full-profile";
  const completed = Math.floor(Date.now() / 1000);
  const browserEvidence = {
    path: browser,
    sha256: browserSHA256,
    size: browserStat.size,
    product: result.version.product,
    revision: result.version.revision,
    protocol_version: result.version.protocolVersion,
    user_agent: result.version.userAgent,
    js_version: result.version.jsVersion,
    display_mode: displayMode,
  };
  const profileEvidence = {
    path: profileDir,
    marker: result.profileMarker,
  };
  if (platform === "android") {
    Object.assign(browserEvidence, {
      acceptance_dir: common.acceptance.directory,
      source_archive_sha256: common.acceptance.sourceArchiveSHA256,
      chromium_commit: common.acceptance.chromiumCommit,
      helium_sync_commit: common.acceptance.heliumSyncCommit,
      version_code: common.acceptance.versionCode,
      version_name: common.acceptance.versionName,
      device_socket: ANDROID_SOCKET,
      adb_serial: common.adbSerial,
      runtime_proof_sha256: common.runtimeProofSHA256,
      profile_adapter_sha256: common.profileAdapterSHA256,
      browser_boundary_sha256: common.browserBoundarySHA256,
    });
    if (!result.androidStage) {
      fail("Android runtime proof has no staged profile binding");
    }
    Object.assign(profileEvidence, {
      device_path: result.androidStage.deviceProfile,
      staged_profile_sha256: result.androidStage.profileTreeSHA256,
      binding_sha256: result.androidStage.bindingSHA256,
      adapter_receipt_sha256: result.androidStage.receiptSHA256,
    });
  }
  const evidence = {
    schema_version: 1,
    evidence_type: "helium-tab-runtime-proof-v1",
    mechanism,
    state: "healthy",
    platform,
    package_id: packageID,
    source_device: device,
    execution_identity: common.executionIdentity,
    profile,
    generation: result.generation,
    completed_unix: completed,
    browser: browserEvidence,
    disposable_profile: profileEvidence,
    source_binding: result.sourceBinding,
    expected_topology: result.expectedTopology,
    steps: result.steps,
  };
  validateEvidence(evidence);
  createEvidenceDirectory(evidenceDir);
  const raw = Buffer.from(`${JSON.stringify(evidence, null, 2)}\n`);
  atomicWrite(path.join(evidenceDir, "evidence.json"), raw);
  atomicWrite(path.join(evidenceDir, "evidence.hmac"),
    `${hmac(raw, signingKey)}\n`);
  console.log(JSON.stringify({
    mechanism,
    evidence: evidenceDir,
    evidence_sha256: sha256(raw),
    generation: result.generation,
  }));
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (!["native", "neutral", "full-profile"].includes(command)) {
    usage();
  } else {
    await main(command, parseOptions(args));
  }
} catch (error) {
  console.error(`tab-runtime-proof: ${error.message}`);
  process.exitCode = 1;
}
