#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import {
  normalizePasswordState,
  passwordFingerprint,
  reconcilePasswords,
} from "./password-reconcile.mjs";

const usage = `usage:
  cdp-password-sync.mjs once --cdp URL --server URL --token-file PATH --device NAME [--state-file PATH]
  cdp-password-sync.mjs push --cdp URL --server URL --token-file PATH --device NAME [--state-file PATH]
  cdp-password-sync.mjs pull --cdp URL --server URL --token-file PATH --device NAME [--state-file PATH]
  cdp-password-sync.mjs daemon --cdp URL --server URL --token-file PATH --device NAME [--state-file PATH] [--interval SECONDS]
`;

const args = parseArgs(process.argv.slice(2));
const command = args._[0];
if (!["once", "push", "pull", "daemon"].includes(command) || !args.cdp || !args.server || !args.device) {
  process.stderr.write(usage);
  process.exit(64);
}

const token = args.token || (args["token-file"] ? await readSecret(args["token-file"]) : "");
if (!token) {
  process.stderr.write(usage);
  process.exit(64);
}

const stateFile = args["state-file"] || path.join(
  process.env.XDG_STATE_HOME || path.join(process.env.HOME || "/tmp", ".local", "state"),
  "helium-sync",
  "cdp-password-sync-state.json",
);
const intervalMs = Math.max(5, Number(args.interval || 30)) * 1000;

class CDP {
  static async openPasswordManager(baseURL) {
    const normalized = trimSlash(baseURL);
    let createdID = "";
    let targets = await this.targets(normalized);
    let target = targets.find((item) => item.type === "page" && item.url.startsWith("chrome://password-manager"));

    if (!target) {
      const browser = await this.openBrowser(normalized);
      try {
        const created = await browser.call("Target.createTarget", {
          url: "chrome://password-manager/passwords",
          background: true,
          focus: false,
        });
        createdID = created.targetId || "";
      } finally {
        await browser.close({ closeCreatedTarget: false });
      }
      targets = await this.targets(normalized);
      target = targets.find((item) => item.id === createdID) ||
        targets.find((item) => item.type === "page" && item.url.startsWith("chrome://password-manager"));
    }
    if (!target?.webSocketDebuggerUrl) throw new Error(`no CDP page target at ${baseURL}`);

    const client = new CDP(normalized, target.webSocketDebuggerUrl, createdID);
    await client.open();
    await client.call("Runtime.enable");
    await client.waitForPasswordsPrivate();
    return client;
  }

  static async targets(normalizedBaseURL) {
    return fetch(`${normalizedBaseURL}/json/list`).then((response) => response.json());
  }

  static async openBrowser(normalizedBaseURL) {
    const version = await fetch(`${normalizedBaseURL}/json/version`).then((response) => response.json());
    if (!version.webSocketDebuggerUrl) throw new Error(`no browser CDP target at ${normalizedBaseURL}`);
    const client = new CDP(normalizedBaseURL, version.webSocketDebuggerUrl, "");
    await client.open();
    return client;
  }

  constructor(baseURL, webSocketURL, createdID) {
    this.baseURL = baseURL;
    this.webSocketURL = webSocketURL;
    this.createdID = createdID;
    this.nextID = 0;
    this.pending = new Map();
  }

  open() {
    this.ws = new WebSocket(this.webSocketURL);
    this.ws.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject, timer } = this.pending.get(message.id);
        clearTimeout(timer);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
      }
    };
    return new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });
  }

  call(method, params = {}, timeout = 10000) {
    const id = ++this.nextID;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout for ${method}`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  async evaluate(expression, timeout = 20000) {
    const result = await this.call("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    }, timeout);
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text || "password manager evaluation failed");
    }
    return result.result?.value;
  }

  async waitForPasswordsPrivate() {
    const value = await this.evaluate(`new Promise(async (resolve) => {
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      for (let i = 0; i < 80; i++) {
        if (globalThis.chrome?.passwordsPrivate?.getSavedPasswordList) return resolve(true);
        await sleep(250);
      }
      resolve(false);
    })`, 25000);
    if (!value) throw new Error("chrome.passwordsPrivate is unavailable");
  }

  snapshot() {
    return this.evaluate(`new Promise(async (resolve) => {
      const entries = (await chrome.passwordsPrivate.getSavedPasswordList()).filter(entry => !entry.isPasskey);
      const ids = entries.map(entry => entry.id);
      const details = ids.length ? await chrome.passwordsPrivate.requestCredentialsDetails(ids) : [];
      const out = details.filter(entry => !entry.isPasskey && entry.password).map(entry => {
        const domain = entry.affiliatedDomains?.[0] || {};
        return {
          affiliatedDomains: entry.affiliatedDomains || [],
          backupPassword: entry.backupPassword,
          changePasswordUrl: entry.changePasswordUrl,
          compromisedInfo: entry.compromisedInfo,
          creationTime: entry.creationTime,
          displayName: entry.displayName,
          federationText: entry.federationText,
          hidden: Boolean(entry.hidden),
          id: entry.id,
          isPasskey: false,
          storedIn: entry.storedIn,
          url: domain.url || domain.signonRealm || "",
          signon_realm: domain.signonRealm || "",
          username: entry.username || "",
          password: entry.password || "",
          note: entry.note || "",
        };
      });
      resolve(out);
    })`);
  }

  async addPassword(payload) {
    return this.evaluate(`new Promise(async (resolve) => {
      try {
        await chrome.passwordsPrivate.addPassword(${JSON.stringify({
          url: payload.url,
          username: payload.username,
          password: payload.password,
          note: payload.note || "",
          useAccountStore: false,
        })});
        resolve({ok:true});
      } catch (error) {
        resolve({ok:false, error:String(error)});
      }
    })`);
  }

  async changePassword(entry, payload) {
    return this.evaluate(`new Promise(async (resolve) => {
      try {
        const credential = ${JSON.stringify(passwordUiEntryForChange(entry, payload))};
        await chrome.passwordsPrivate.changeCredential(credential);
        resolve({ok:true});
      } catch (error) {
        resolve({ok:false, error:String(error)});
      }
    })`);
  }

  async removeCredential(entry) {
    return this.evaluate(`new Promise((resolve) => {
      try {
        chrome.passwordsPrivate.removeCredential(${Number(entry.id)}, ${JSON.stringify(entry.storedIn || "DEVICE")});
        resolve({ok:true});
      } catch (error) {
        resolve({ok:false, error:String(error)});
      }
    })`);
  }

  async close(options = {}) {
    const closeCreatedTarget = options.closeCreatedTarget !== false;
    try {
      this.ws?.close();
    } finally {
      if (closeCreatedTarget && this.createdID) {
        await fetch(`${this.baseURL}/json/close/${encodeURIComponent(this.createdID)}`).catch(() => {});
      }
    }
  }
}

async function syncOnce(mode) {
  const loaded = await loadState(stateFile);
  const state = loaded.state;
  const page = await CDP.openPasswordManager(args.cdp);
  try {
    let pushed = 0;
    let pulled = 0;
    if (mode === "once") {
      const result = await reconcileOnce(page, state, loaded.trusted);
      pushed = result.published;
      pulled = result.applied;
    } else if (mode === "push") {
      pushed = await pushLocalChanges(page, state);
    } else if (mode === "pull") {
      pulled = await pullRemoteChanges(page, state);
    }
    await saveState(stateFile, state);
    return { pushed, pulled };
  } finally {
    await page.close();
  }
}

async function reconcileOnce(page, state, stateTrusted) {
  const latest = await fetchLatest();
  return reconcilePasswords({
    state,
    stateTrusted,
    remoteRecords: (latest.records || []).filter(record => record.kind === "passwords"),
    snapshot: async () => (await page.snapshot()).map(credential => {
      const payload = payloadFromCredential(credential);
      return payload ? {
        key: keyFromPayload(payload),
        payload,
        credential,
      } : null;
    }).filter(Boolean),
    normalizeRemote: normalizedPayload,
    applyRemote: async (key, payload, existing) => {
      const indexes = existing ? null : buildCredentialIndexes(await page.snapshot());
      const credential = existing || findByOriginUser(indexes, payload);
      const result = credential
        ? await page.changePassword(credential, payload)
        : await page.addPassword(payload);
      if (!result.ok) {
        logPasswordSyncWarning(credential ? "change-failed" : "add-failed", {
          key,
          error: errorText(result),
        });
      }
      return result.ok;
    },
    publish: pushRecords,
  });
}

async function pushLocalChanges(page, state) {
  const credentials = await page.snapshot();
  const records = [];
  const pendingFingerprints = new Map();
  for (const credential of credentials) {
    const payload = payloadFromCredential(credential);
    if (!payload) continue;
    const key = keyFromPayload(payload);
    const fingerprint = passwordFingerprint(payload);
    if (state.credentials[key]?.fingerprint === fingerprint) continue;
    records.push({ kind: "passwords", key, payload });
    pendingFingerprints.set(key, fingerprint);
  }
  if (records.length) {
    await pushRecords(records);
    for (const [key, fingerprint] of pendingFingerprints) {
      state.credentials[key] = {
        fingerprint,
        remote_seq: state.credentials[key]?.remote_seq || 0,
      };
    }
  }
  return records.length;
}

async function pullRemoteChanges(page, state) {
  const latest = await fetchLatest();
  const records = (latest.records || []).filter(record =>
    record.kind === "passwords");
  if (!records.length) return 0;

  let indexes = buildCredentialIndexes(await page.snapshot());
  let applied = 0;
  for (const record of records) {
    if (record.deleted) {
      continue;
    }
    const remoteSeq = Number(record.seq);
    if (!Number.isSafeInteger(remoteSeq) || remoteSeq <= 0 ||
        remoteSeq <= (state.credentials[record.key]?.remote_seq || 0)) continue;
    const payload = normalizedPayload(record.payload);
    if (!payload) {
      logPasswordSyncWarning("invalid-payload", { key: record.key });
      continue;
    }
    const existing = indexes.byKey.get(record.key) || findByOriginUser(indexes, payload);
    const fingerprint = passwordFingerprint(payload);
    if (state.credentials[record.key]?.fingerprint === fingerprint) {
      state.credentials[record.key].remote_seq = remoteSeq;
      continue;
    }
    if (existing) {
      if (passwordFingerprint(payloadFromCredential(existing)) === fingerprint) {
        state.credentials[record.key] = { fingerprint, remote_seq: remoteSeq };
        continue;
      }
      const result = await page.changePassword(existing, payload);
      if (!result.ok) {
        logPasswordSyncWarning("change-failed", { key: record.key, error: errorText(result) });
        continue;
      }
    } else {
      const result = await page.addPassword(payload);
      if (!result.ok) {
        logPasswordSyncWarning("add-failed", { key: record.key, error: errorText(result) });
        continue;
      }
    }
    state.credentials[record.key] = { fingerprint, remote_seq: remoteSeq };
    applied++;
    indexes = buildCredentialIndexes(await page.snapshot());
  }
  return applied;
}

function errorText(result) {
  return String(result?.error || "unknown error").slice(0, 500);
}

function logPasswordSyncWarning(reason, fields = {}) {
  console.error(JSON.stringify({ action: "password-sync-warning", reason, ...fields }));
}

function buildCredentialIndexes(credentials) {
  const byKey = new Map();
  const byOriginUser = new Map();
  for (const entry of credentials) {
    const payload = payloadFromCredential(entry);
    if (!payload) continue;
    byKey.set(keyFromPayload(payload), entry);
    for (const key of originUserKeysForEntry(entry)) {
      byOriginUser.set(key, entry);
    }
  }
  return { byKey, byOriginUser };
}

function passwordUiEntryForChange(entry, payload) {
  const out = {
    affiliatedDomains: entry.affiliatedDomains || [],
    hidden: Boolean(entry.hidden),
    id: entry.id,
    isPasskey: Boolean(entry.isPasskey),
    password: payload.password,
    storedIn: entry.storedIn,
    username: payload.username,
  };
  if (payload.note) out.note = payload.note;
  for (const key of [
    "backupPassword",
    "changePasswordUrl",
    "compromisedInfo",
    "creationTime",
    "displayName",
    "federationText",
  ]) {
    if (entry[key] !== undefined) out[key] = entry[key];
  }
  return out;
}

function payloadFromCredential(credential) {
  return normalizedPayload({
    format: "helium-password-v1",
    url: credential.url,
    signon_realm: credential.signon_realm,
    username: credential.username,
    password: credential.password,
    note: credential.note || "",
  });
}

function normalizedPayload(payload) {
  if (!payload || payload.format !== "helium-password-v1") return null;
  const url = String(payload.url || payload.signon_realm || "");
  if (!url || !payload.password) return null;
  return {
    format: "helium-password-v1",
    url,
    signon_realm: String(payload.signon_realm || originRealm(url)),
    username: String(payload.username || ""),
    password: String(payload.password || ""),
    note: String(payload.note || ""),
  };
}

function originRealm(url) {
  try {
    return new URL(url).origin + "/";
  } catch {
    return url;
  }
}

function keyFromPayload(payload) {
  const material = `${payload.signon_realm}\0${payload.url}\0${payload.username}`;
  return `credential/${crypto.createHash("sha256").update(material).digest("hex")}`;
}

function findByOriginUser(indexes, payload) {
  for (const key of originUserKeysForPayload(payload)) {
    const entry = indexes.byOriginUser.get(key);
    if (entry) return entry;
  }
  return null;
}

function originUserKeysForEntry(entry) {
  const keys = new Set(originUserKeysForPayload(payloadFromCredential(entry)));
  for (const domain of entry.affiliatedDomains || []) {
    addOriginUserKey(keys, domain.url || domain.signonRealm || "", entry.username);
  }
  return keys;
}

function originUserKeysForPayload(payload) {
  const keys = new Set();
  if (!payload) return keys;
  addOriginUserKey(keys, payload.url, payload.username);
  addOriginUserKey(keys, payload.signon_realm, payload.username);
  return keys;
}

function addOriginUserKey(keys, value, username) {
  if (!value) return;
  keys.add(`${originRealm(value)}\0${username}`);
  keys.add(`${value}\0${username}`);
}

async function pushRecords(records) {
  const response = await fetch(`${trimSlash(args.server)}/v1/records/push`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ device: args.device, records }),
  });
  if (!response.ok) throw new Error(`push failed: ${response.status} ${await response.text()}`);
}

async function fetchLatest() {
  const response = await fetch(`${trimSlash(args.server)}/v1/records/latest?kind=passwords`, {
    headers: { "Authorization": `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`latest failed: ${response.status} ${await response.text()}`);
  return response.json();
}

async function loadState(file) {
  try {
    const parsed = JSON.parse(await fs.readFile(file, "utf8"));
    const recognized = parsed?.schema_version === 2 ||
      (parsed?.fingerprints && typeof parsed.fingerprints === "object");
    return { state: normalizePasswordState(parsed), trusted: Boolean(recognized) };
  } catch (error) {
    if (error.code === "ENOENT") {
      return { state: normalizePasswordState(null), trusted: true };
    }
    logPasswordSyncWarning("state-invalid", { error: errorText(error) });
    return { state: normalizePasswordState(null), trusted: false };
  }
}

async function saveState(file, state) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp`;
  const handle = await fs.open(temporary, "w", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(state, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(temporary, file);
  const directory = await fs.open(path.dirname(file), "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

async function readSecret(file) {
  return (await fs.readFile(file, "utf8")).trim();
}

function trimSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (!arg.startsWith("--")) {
      out._.push(arg);
      continue;
    }
    out[arg.slice(2)] = argv[++index];
  }
  return out;
}

if (command === "daemon") {
  for (;;) {
    try {
      const result = await syncOnce("once");
      console.log(JSON.stringify({ action: "password-sync", ...result }));
    } catch (error) {
      console.error(`password-sync: ${error.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
} else {
  const result = await syncOnce(command);
  console.log(JSON.stringify({ action: "password-sync", ...result }));
}
