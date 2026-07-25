#!/usr/bin/env node

import {spawn, spawnSync} from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

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

function usage() {
  console.error(`usage:
  tab-runtime-proof.mjs native COMMON
  tab-runtime-proof.mjs neutral COMMON --helium-tabs FILE \\
    --source-receipt FILE
  tab-runtime-proof.mjs full-profile COMMON --expected-evidence DIR

COMMON:
  --browser ABSOLUTE-FILE --browser-sha256 HEX
  --package-id desktop|computer.helium.sync.test
  --display-mode headless|headed
  --profile-dir ABSOLUTE-DRILL-DIR
  --source-device d|da|oneplus --profile SLUG
  --evidence-dir ABSOLUTE-NEW-PROOF-DIR --signing-key FILE
  [--timeout-seconds 45]

Desktop is implemented. The only admitted Android identity is
computer.helium.sync.test, but it fails before any package or profile access
until a dedicated Android app-sandbox CDP adapter exists.`);
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

function createNativeProfile(directory) {
  const parent = requireDirectDrillChild(directory, NATIVE_ROOT_MARKER,
    NATIVE_ROOT_MARKER_CONTENT, "native disposable profile");
  if (fs.existsSync(directory)) {
    fail("native disposable profile must not exist");
  }
  fs.mkdirSync(directory, {mode: 0o700});
  try {
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

async function launchBrowser(common, extraArgs = []) {
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

async function readTopology(browser, expected) {
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
    const window = await browser.request("Browser.getWindowForTarget",
      {targetId: target.targetId});
    if (!Number.isSafeInteger(window.windowId)) {
      fail("CDP window identity is invalid");
    }
    const urls = windows.get(window.windowId) ?? [];
    urls.push(target.url);
    windows.set(window.windowId, urls);
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

async function waitForTopology(browser, expected, timeout) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await readTopology(browser, expected);
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

async function setNativeFixture(browser, expected) {
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
        newWindow: windowIndex > 0 && tabIndex === 0,
        background: true,
      });
      if (typeof created.targetId !== "string") {
        fail("CDP fixture tab creation failed");
      }
    }
  }
}

async function fixtureServer() {
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
    windows: [{urls: urls.slice(0, 2)}, {urls: urls.slice(2)}],
  });
  return {
    server,
    origin,
    topology,
    close: () => new Promise((resolve, reject) =>
      server.close(error => error ? reject(error) : resolve())),
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
  createNativeProfile(common.profileDir);
  const fixture = await fixtureServer();
  let active;
  try {
    const first = await launchBrowser(common);
    active = first.browser;
    await setNativeFixture(first.browser, fixture.topology);
    const initial = await waitForTopology(first.browser, fixture.topology,
      common.timeout);
    await first.browser.close();
    active = undefined;

    const clean = await launchBrowser(common, ["--restore-last-session"]);
    active = clean.browser;
    sameVersion(first.version, clean.version);
    const cleanTopology = await waitForTopology(clean.browser, fixture.topology,
      common.timeout);
    await clean.browser.crash();
    active = undefined;

    const crash = await launchBrowser(common, ["--restore-last-session"]);
    active = crash.browser;
    sameVersion(first.version, crash.version);
    const crashTopology = await waitForTopology(crash.browser, fixture.topology,
      common.timeout);
    await crash.browser.close();
    active = undefined;

    const second = await launchBrowser(common, ["--restore-last-session"]);
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser,
      fixture.topology, common.timeout);
    await second.browser.close();
    active = undefined;

    return {
      version: first.version,
      expectedTopology: fixture.topology,
      generation: `native-${Math.floor(Date.now() / 1000)}-${topologyDigest(fixture.topology).slice(0, 16)}`,
      profileMarker: NATIVE_PROFILE_MARKER,
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
  let active;
  try {
    const first = await launchBrowser(common, [
      `--helium-restore-disposable-tabs=${common.device}`,
    ]);
    active = first.browser;
    const firstTopology = await waitForTopology(first.browser, expected,
      common.timeout);
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
    await first.browser.close();
    active = undefined;

    const second = await launchBrowser(common, ["--restore-last-session"]);
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser, expected,
      common.timeout);
    await second.browser.close();
    active = undefined;
    const receiptPath = path.join(common.profileDir,
      ".helium-tabs-restore-receipt-v2.json");
    requirePrivateFile(receiptPath, "neutral native receipt", 64 * 1024);
    return {
      version: first.version,
      expectedTopology: expected,
      generation: manifest.source_generation,
      profileMarker: NEUTRAL_PROFILE_MARKER,
      sourceBinding: {
        source_generation: manifest.source_generation,
        source_session_sha256: manifest.source_session.sha256,
        source_destination: sourceReceipt.get("source_destination"),
        archive_sha256: sourceReceipt.get("archive_sha256"),
        backup_manifest_sha256:
          sourceReceipt.get("backup_manifest_sha256"),
        source_receipt_sha256: await sha256File(sourceReceiptPath),
        native_receipt_sha256: await sha256File(receiptPath),
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
      expectedEvidence.value.browser.sha256 !== common.browserSHA256) {
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
  let active;
  try {
    const first = await launchBrowser(common, ["--restore-last-session"]);
    active = first.browser;
    const firstTopology = await waitForTopology(first.browser, expected,
      common.timeout);
    await first.browser.close();
    active = undefined;

    const second = await launchBrowser(common, ["--restore-last-session"]);
    active = second.browser;
    sameVersion(first.version, second.version);
    const secondTopology = await waitForTopology(second.browser, expected,
      common.timeout);
    await second.browser.close();
    active = undefined;
    return {
      version: first.version,
      expectedTopology: expected,
      generation: fields.get("generation"),
      profileMarker: PROFILE_RECEIPT,
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
  requireOptions(options, [...commonRequired, ...extras],
    ["--timeout-seconds"]);

  const packageID = options.get("--package-id");
  if (packageID === "computer.helium.sync.test") {
    fail("Android adapter unavailable: computer.helium.sync.test was admitted but no package or profile was touched");
  }
  if (packageID !== "desktop") {
    fail("package identity is not admitted");
  }
  const displayMode = options.get("--display-mode");
  if (!["headless", "headed"].includes(displayMode)) {
    fail("display mode must be headless or headed");
  }
  const browser = options.get("--browser");
  const browserStat = requireExecutable(browser, "browser");
  const browserSHA256 = validSHA256(options.get("--browser-sha256"),
    "expected browser SHA-256");
  if (await sha256File(browser) !== browserSHA256) {
    fail("browser SHA-256 does not match the pinned artifact");
  }
  const device = validDevice(options.get("--source-device"));
  const profile = validSlug(options.get("--profile"), "profile");
  const profileDir = requireAbsolute(options.get("--profile-dir"),
    "disposable profile");
  const evidenceDir = requireAbsolute(options.get("--evidence-dir"),
    "evidence directory");
  const signingKey = loadSigningKey(options.get("--signing-key"));
  const common = {
    browser,
    browserSHA256,
    profileDir,
    device,
    profile,
    displayMode,
    timeout: parseTimeout(options.get("--timeout-seconds")),
  };

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
  const evidence = {
    schema_version: 1,
    evidence_type: "helium-tab-runtime-proof-v1",
    mechanism,
    state: "healthy",
    platform: "desktop",
    package_id: "desktop",
    source_device: device,
    profile,
    generation: result.generation,
    completed_unix: completed,
    browser: {
      path: browser,
      sha256: browserSHA256,
      size: browserStat.size,
      product: result.version.product,
      revision: result.version.revision,
      protocol_version: result.version.protocolVersion,
      user_agent: result.version.userAgent,
      js_version: result.version.jsVersion,
      display_mode: displayMode,
    },
    disposable_profile: {
      path: profileDir,
      marker: result.profileMarker,
    },
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
