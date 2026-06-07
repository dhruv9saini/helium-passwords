#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

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
    let target;
    const createURL = `${normalized}/json/new?${encodeURIComponent("chrome://password-manager/passwords")}`;
    const createResponse = await fetch(createURL, { method: "PUT" }).catch(() => null);
    if (createResponse?.ok) {
      target = await createResponse.json();
      createdID = target.id || "";
    } else {
      const targets = await fetch(`${normalized}/json/list`).then((response) => response.json());
      target = targets.find((item) => item.type === "page" && item.url.startsWith("chrome://password-manager")) ||
        targets.find((item) => item.type === "page");
    }
    if (!target?.webSocketDebuggerUrl) throw new Error(`no CDP page target at ${baseURL}`);

    const client = new CDP(normalized, target.webSocketDebuggerUrl, createdID);
    await client.open();
    await client.call("Runtime.enable");
    if (!createdID) {
      await client.call("Page.enable").catch(() => {});
      await client.call("Page.navigate", { url: "chrome://password-manager/passwords" }).catch(() => {});
    }
    await client.waitForPasswordsPrivate();
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
          id: entry.id,
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
        await chrome.passwordsPrivate.changeCredential(${JSON.stringify({
          id: entry.id,
          storedIn: entry.storedIn,
          username: payload.username,
          password: payload.password,
          note: payload.note || "",
        })});
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

  async close() {
    try {
      this.ws?.close();
    } finally {
      if (this.createdID) {
        await fetch(`${this.baseURL}/json/close/${encodeURIComponent(this.createdID)}`).catch(() => {});
      }
    }
  }
}

async function syncOnce(mode) {
  const state = await loadState(stateFile);
  const page = await CDP.openPasswordManager(args.cdp);
  try {
    let pushed = 0;
    let pulled = 0;
    if (mode === "once" || mode === "push") {
      pushed = await pushLocalChanges(page, state);
    }
    if (mode === "once" || mode === "pull") {
      pulled = await pullRemoteChanges(page, state);
    }
    await saveState(stateFile, state);
    return { pushed, pulled };
  } finally {
    await page.close();
  }
}

async function pushLocalChanges(page, state) {
  const credentials = await page.snapshot();
  const seen = new Set();
  const records = [];
  for (const credential of credentials) {
    const payload = payloadFromCredential(credential);
    if (!payload) continue;
    const key = keyFromPayload(payload);
    const fingerprint = fingerprintPayload(payload);
    seen.add(key);
    if (state.fingerprints[key] === fingerprint) continue;
    records.push({ kind: "passwords", key, payload });
    state.fingerprints[key] = fingerprint;
  }
  for (const key of Object.keys(state.fingerprints)) {
    if (seen.has(key)) continue;
    records.push({ kind: "passwords", key, deleted: true, payload: {} });
    delete state.fingerprints[key];
  }
  if (records.length) {
    await pushRecords(records);
  }
  return records.length;
}

async function pullRemoteChanges(page, state) {
  const latest = await fetchLatest();
  const records = (latest.records || []).filter(record =>
    record.kind === "passwords" && record.origin_device !== args.device);
  if (!records.length) return 0;

  let current = await page.snapshot();
  const byKey = new Map();
  for (const entry of current) {
    const payload = payloadFromCredential(entry);
    if (payload) byKey.set(keyFromPayload(payload), entry);
  }
  let applied = 0;
  for (const record of records) {
    const existing = byKey.get(record.key);
    if (record.deleted) {
      if (existing) {
        const result = await page.removeCredential(existing);
        if (!result.ok) continue;
        byKey.delete(record.key);
      }
      delete state.fingerprints[record.key];
      applied++;
      continue;
    }
    const payload = normalizedPayload(record.payload);
    if (!payload) continue;
    const fingerprint = fingerprintPayload(payload);
    if (existing) {
      if (fingerprintPayload(payloadFromCredential(existing)) === fingerprint) {
        state.fingerprints[record.key] = fingerprint;
        continue;
      }
      const result = await page.changePassword(existing, payload);
      if (!result.ok) continue;
    } else {
      const result = await page.addPassword(payload);
      if (!result.ok) continue;
    }
    state.fingerprints[record.key] = fingerprint;
    applied++;
    current = await page.snapshot();
    byKey.clear();
    for (const entry of current) {
      const currentPayload = payloadFromCredential(entry);
      if (currentPayload) byKey.set(keyFromPayload(currentPayload), entry);
    }
  }
  return applied;
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

function fingerprintPayload(payload) {
  return crypto.createHash("sha256").update(JSON.stringify([
    payload.url,
    payload.signon_realm,
    payload.username,
    payload.password,
    payload.note || "",
  ])).digest("hex");
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
  const response = await fetch(`${trimSlash(args.server)}/v1/records/latest?kind=passwords&include_deleted=true`, {
    headers: { "Authorization": `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`latest failed: ${response.status} ${await response.text()}`);
  return response.json();
}

async function loadState(file) {
  try {
    const parsed = JSON.parse(await fs.readFile(file, "utf8"));
    return { fingerprints: parsed.fingerprints && typeof parsed.fingerprints === "object" ? parsed.fingerprints : {} };
  } catch {
    return { fingerprints: {} };
  }
}

async function saveState(file, state) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(`${file}.tmp`, JSON.stringify(state, null, 2), { mode: 0o600 });
  await fs.rename(`${file}.tmp`, file);
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
