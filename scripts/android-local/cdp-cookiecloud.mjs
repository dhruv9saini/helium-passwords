#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";

import {
  cookieIdentity,
  cookieToCDPParams,
  migrateCookiePayload,
  replicaGeneration,
  updateDomainFromSource,
  validateCookiePolicies,
} from "./cookie-replication.mjs";

const usage = `usage:
  cdp-cookiecloud.mjs upload --device NAME --cdp URL --server URL --config-file PATH
  cdp-cookiecloud.mjs download --device NAME --cdp URL --server URL --config-file PATH
  cdp-cookiecloud.mjs sync --targets NAME=URL[,NAME=URL...] --server URL --config-file PATH
  cdp-cookiecloud.mjs daemon --targets NAME=URL[,NAME=URL...] --server URL --config-file PATH [--interval SECONDS]

The config must contain uuid, password, cookie_policies, and optionally targets,
legacy_source_device, state_file, endpoint, and interval.
`;

const args = parseArgs(process.argv.slice(2));
const command = args._[0];
if (!["upload", "download", "sync", "daemon"].includes(command)) failUsage();
const options = resolveOptions(args);

class CDP {
  static async connect(baseURL) {
    const normalized = trimSlash(baseURL);
    const version = await fetch(`${normalized}/json/version`).then(response => response.json());
    if (!version.webSocketDebuggerUrl) throw new Error(`no browser CDP target at ${baseURL}`);
    const client = new CDP(version.webSocketDebuggerUrl);
    await client.open();
    return client;
  }

  constructor(webSocketURL) {
    this.webSocketURL = webSocketURL;
    this.nextID = 0;
    this.pending = new Map();
  }

  open() {
    this.ws = new WebSocket(this.webSocketURL);
    this.ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (!message.id || !this.pending.has(message.id)) return;
      const { resolve, reject, timer } = this.pending.get(message.id);
      clearTimeout(timer);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result || {});
    };
    return new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
  }

  call(method, params = {}) {
    const id = ++this.nextID;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout for ${method}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  getAllCookies() {
    return this.call("Storage.getCookies");
  }

  setCookie(cookie) {
    return this.call("Storage.setCookies", { cookies: [cookie] });
  }

  expireCookie(cookie) {
    const params = cookieToCDPParams({ ...cookie, value: "", session: false, expires: 1 });
    if (!params) throw new Error("cannot encode cookie deletion");
    return this.setCookie(params);
  }

  close() {
    this.ws?.close();
  }
}

async function runOnce(mode) {
  const remote = await readRemotePayload();
  const state = await loadState(options.stateFile);
  const summaries = [];
  let remoteChanged = false;

  if (mode === "upload" || mode === "sync") {
    const sourceSnapshots = new Map();
    const targets = new Map(options.targets.map(target => [target.device, target]));
    for (const policy of options.policies) {
      const target = targets.get(policy.source);
      if (!target) continue;
      if (!sourceSnapshots.has(policy.source)) {
        sourceSnapshots.set(policy.source, await snapshotCookies(target));
      }
      const changed = updateDomainFromSource(
        remote.payload,
        policy,
        policy.source,
        sourceSnapshots.get(policy.source),
      );
      remoteChanged ||= changed;
      summaries.push({ device: policy.source, domain: policy.domain, action: changed ? "published" : "unchanged" });
    }
    if (remoteChanged || (remote.migrated && sourceSnapshots.size > 0)) {
      await writeRemotePayload(remote.payload, remote.revision);
    }
  }

  if (mode === "download" || mode === "sync") {
    for (const target of options.targets) {
      summaries.push(...await applyReplicaGenerations(target, remote.payload, state));
    }
    await saveState(options.stateFile, state);
  }
  return { action: mode, remote_changed: remoteChanged, results: summaries };
}

async function snapshotCookies(target) {
  return withCDP(target.cdp, async cdp => {
    const result = await cdp.getAllCookies();
    return result.cookies || [];
  });
}

async function applyReplicaGenerations(target, payload, state) {
  const actions = [];
  const relevant = options.policies.filter(policy => policy.replicas.includes(target.device));
  if (!relevant.length) return actions;

  await withCDP(target.cdp, async cdp => {
    const deviceState = state.devices[target.device] ||= {};
    for (const policy of relevant) {
      const generation = replicaGeneration(payload, policy, target.device);
      const previous = deviceState[policy.domain];
      if (!generation.generation || generation.generation <= (previous?.generation || 0)) continue;

      const nextIDs = new Set(generation.cookies.map(cookieIdentity));
      for (const oldCookie of previous?.cookies || []) {
        if (!nextIDs.has(cookieIdentity(oldCookie))) await cdp.expireCookie(oldCookie);
      }
      if (generation.action === "apply") {
        for (const cookie of generation.cookies) {
          const params = cookieToCDPParams(cookie);
          if (!params) throw new Error(`invalid cookie in ${policy.domain} generation`);
          await cdp.setCookie(params);
        }
      }
      deviceState[policy.domain] = {
        generation: generation.generation,
        status: generation.action === "reauthenticate" ? "reauthentication_required" : "applied",
        cookies: generation.cookies.map(cookie => cookieDescriptor(cookie)),
      };
      actions.push({
        device: target.device,
        domain: policy.domain,
        action: generation.action,
        generation: generation.generation,
        cookies: generation.cookies.length,
      });
    }
  });
  return actions;
}

function cookieDescriptor(cookie) {
  return {
    name: cookie.name,
    value: "",
    domain: cookie.domain,
    path: cookie.path,
    expires: cookie.expires,
    httpOnly: cookie.httpOnly,
    secure: cookie.secure,
    session: cookie.session,
    sameSite: cookie.sameSite,
    priority: cookie.priority,
    sourceScheme: cookie.sourceScheme,
    sourcePort: cookie.sourcePort,
    ...(cookie.partitionKey ? { partitionKey: cookie.partitionKey } : {}),
  };
}

async function withCDP(cdpURL, callback) {
  const cdp = await CDP.connect(cdpURL);
  try {
    return await callback(cdp);
  } finally {
    cdp.close();
  }
}

async function readRemotePayload() {
  const response = await fetch(`${trimSlash(options.server)}/get/${encodeURIComponent(options.uuid)}`);
  if (response.status === 404) {
    return {
      payload: migrateCookiePayload(null, options.policies, options.legacySourceDevice),
      migrated: false,
      revision: 0,
    };
  }
  if (!response.ok) throw new Error(`cookie download failed: ${response.status} ${await response.text()}`);
  const record = await response.json();
  if (!record.encrypted) throw new Error("cookie record has no ciphertext");
  const revision = Number(record.revision || 0);
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new Error("cookie record has invalid revision");
  }
  const raw = JSON.parse(cookieCloudDecrypt(options.uuid, record.encrypted, options.password));
  return {
    payload: migrateCookiePayload(raw, options.policies, options.legacySourceDevice),
    migrated: raw.schema_version !== 2,
    revision,
  };
}

async function writeRemotePayload(payload, expectedRevision) {
  const encrypted = cookieCloudEncrypt(options.uuid, JSON.stringify(payload), options.password);
  const response = await fetch(`${trimSlash(options.server)}/update`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      uuid: options.uuid,
      encrypted,
      crypto_type: "legacy",
      expected_revision: expectedRevision,
    }),
  });
  if (!response.ok) throw new Error(`cookie upload failed: ${response.status} ${await response.text()}`);
}

function cookieCloudEncrypt(uuid, plaintext, password) {
  const passphrase = crypto.createHash("md5").update(`${uuid}-${password}`).digest("hex").slice(0, 16);
  const salt = crypto.randomBytes(8);
  const { key, iv } = evpBytesToKey(Buffer.from(passphrase), salt);
  const cipher = crypto.createCipheriv("aes-256-cbc", key, iv);
  return Buffer.concat([
    Buffer.from("Salted__"),
    salt,
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]).toString("base64");
}

function cookieCloudDecrypt(uuid, encrypted, password) {
  const passphrase = crypto.createHash("md5").update(`${uuid}-${password}`).digest("hex").slice(0, 16);
  const raw = Buffer.from(encrypted, "base64");
  if (raw.subarray(0, 8).toString() !== "Salted__") {
    throw new Error("unsupported CookieCloud ciphertext format");
  }
  const { key, iv } = evpBytesToKey(Buffer.from(passphrase), raw.subarray(8, 16));
  const decipher = crypto.createDecipheriv("aes-256-cbc", key, iv);
  return Buffer.concat([decipher.update(raw.subarray(16)), decipher.final()]).toString("utf8");
}

function evpBytesToKey(passphrase, salt) {
  let previous = Buffer.alloc(0);
  let out = Buffer.alloc(0);
  while (out.length < 48) {
    previous = crypto.createHash("md5").update(Buffer.concat([previous, passphrase, salt])).digest();
    out = Buffer.concat([out, previous]);
  }
  return { key: out.subarray(0, 32), iv: out.subarray(32, 48) };
}

function resolveOptions(rawArgs) {
  const configPath = rawArgs["config-file"] || process.env.COOKIECLOUD_CONFIG || defaultConfigPath();
  const config = readConfig(configPath);
  const policies = validateCookiePolicies(config.cookie_policies);
  const targets = rawArgs.cdp
    ? [{ device: String(rawArgs.device || ""), cdp: String(rawArgs.cdp) }]
    : parseTargets(rawArgs.targets || config.targets);
  if (!targets.length || targets.some(target => !target.device || !target.cdp)) failUsage();
  const duplicateDevices = targets.map(target => target.device)
    .filter((device, index, devices) => devices.indexOf(device) !== index);
  if (duplicateDevices.length) throw new Error(`duplicate cookie target: ${duplicateDevices[0]}`);
  const server = rawArgs.server || config.endpoint;
  const uuid = rawArgs.uuid || config.uuid;
  const password = rawArgs.password || config.password;
  if (!server || !uuid || !password) failUsage();
  return {
    server,
    uuid,
    password,
    policies,
    targets,
    legacySourceDevice: String(config.legacy_source_device || ""),
    stateFile: rawArgs["state-file"] || config.state_file || defaultStatePath(),
    interval: positiveNumber(rawArgs.interval || config.interval, 60),
  };
}

function parseTargets(raw) {
  if (Array.isArray(raw)) {
    return raw.map(target => ({ device: String(target.device || ""), cdp: String(target.cdp || "") }));
  }
  if (raw && typeof raw === "object") {
    return Object.entries(raw).map(([device, cdp]) => ({ device, cdp: String(cdp) }));
  }
  return String(raw || "").split(",").filter(Boolean).map(item => {
    const separator = item.indexOf("=");
    if (separator <= 0) return { device: "", cdp: "" };
    return { device: item.slice(0, separator).trim(), cdp: item.slice(separator + 1).trim() };
  });
}

function readConfig(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`cookie config not found: ${file}`);
    throw error;
  }
}

async function loadState(file) {
  try {
    const parsed = JSON.parse(await fsp.readFile(file, "utf8"));
    if (parsed?.schema_version !== 1 || !parsed.devices || typeof parsed.devices !== "object") {
      throw new Error("unsupported cookie replication state");
    }
    return parsed;
  } catch (error) {
    if (error.code === "ENOENT") return { schema_version: 1, devices: {} };
    throw error;
  }
}

async function saveState(file, state) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp`;
  const handle = await fsp.open(temporary, "w", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(state, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fsp.rename(temporary, file);
  const directory = await fsp.open(path.dirname(file), "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (!arg.startsWith("--")) out._.push(arg);
    else out[arg.slice(2)] = argv[++index];
  }
  return out;
}

function trimSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function positiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function defaultConfigPath() {
  return `${process.env.HOME || "/root"}/.local/share/helium-local-sync/cookiecloud-client.json`;
}

function defaultStatePath() {
  return path.join(
    process.env.XDG_STATE_HOME || path.join(process.env.HOME || "/tmp", ".local", "state"),
    "helium-sync",
    "cookie-replication-state.json",
  );
}

function failUsage() {
  process.stderr.write(usage);
  process.exit(64);
}

if (command === "daemon") {
  for (;;) {
    try {
      console.log(JSON.stringify(await runOnce("sync")));
    } catch (error) {
      console.error(JSON.stringify({ action: "cookie-sync-error", error: String(error.message || error) }));
    }
    await new Promise(resolve => setTimeout(resolve, Math.max(5, options.interval) * 1000));
  }
} else {
  console.log(JSON.stringify(await runOnce(command)));
}
