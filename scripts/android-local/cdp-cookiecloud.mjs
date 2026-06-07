#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";

const usage = `usage:
  cdp-cookiecloud.mjs upload --cdp URL --server URL [--uuid ID --password SECRET | --config-file PATH] [--include domain,domain] [--blacklist domain,domain]
  cdp-cookiecloud.mjs download --cdp URL --server URL [--uuid ID --password SECRET | --config-file PATH]
  cdp-cookiecloud.mjs sync --android-cdp URL --chroot-cdp URL --server URL [--uuid ID --password SECRET | --config-file PATH]
  cdp-cookiecloud.mjs daemon --android-cdp URL --chroot-cdp URL --server URL [--uuid ID --password SECRET | --config-file PATH] [--interval SECONDS]
`;

const args = parseArgs(process.argv.slice(2));
const command = args._[0];
const options = resolveOptions(args);
const needsSingleCDP = ["upload", "download"].includes(command);
const needsPairCDP = ["sync", "daemon"].includes(command);
if (
  ![ "upload", "download", "sync", "daemon" ].includes(command) ||
  !options.server ||
  !options.uuid ||
  !options.password ||
  (needsSingleCDP && !options.cdp) ||
  (needsPairCDP && (!options.androidCdp || !options.chrootCdp))
) {
  process.stderr.write(usage);
  process.exit(64);
}

class CDP {
  static async connect(baseURL) {
    const targets = await fetch(trimSlash(baseURL) + "/json/list").then((response) => response.json());
    const page = targets.find((target) => target.type === "page" && !String(target.url).startsWith("chrome")) ||
      targets.find((target) => target.type === "page");
    if (!page) throw new Error(`no CDP page target at ${baseURL}`);
    const client = new CDP(page.webSocketDebuggerUrl);
    await client.open();
    await client.call("Network.enable");
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
      if (message.id && this.pending.has(message.id)) {
        const { resolve, timer } = this.pending.get(message.id);
        clearTimeout(timer);
        this.pending.delete(message.id);
        resolve(message);
      }
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
      }, 5000);
      this.pending.set(id, { resolve, reject, timer });
    }).then((message) => {
      if (message.error) throw new Error(`${method}: ${JSON.stringify(message.error)}`);
      return message;
    });
  }

  close() {
    this.ws.close();
  }
}

function cookieCloudEncrypt(uuid, plaintext, password) {
  const passphrase = crypto.createHash("md5").update(`${uuid}-${password}`).digest("hex").slice(0, 16);
  const salt = crypto.randomBytes(8);
  const { key, iv } = evpBytesToKey(Buffer.from(passphrase), salt);
  const cipher = crypto.createCipheriv("aes-256-cbc", key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([Buffer.from("Salted__"), salt, encrypted]).toString("base64");
}

function cookieCloudDecrypt(uuid, encrypted, password) {
  const passphrase = crypto.createHash("md5").update(`${uuid}-${password}`).digest("hex").slice(0, 16);
  const raw = Buffer.from(encrypted, "base64");
  if (raw.subarray(0, 8).toString() !== "Salted__") {
    throw new Error("unsupported CookieCloud ciphertext format");
  }
  const salt = raw.subarray(8, 16);
  const ciphertext = raw.subarray(16);
  const { key, iv } = evpBytesToKey(Buffer.from(passphrase), salt);
  const decipher = crypto.createDecipheriv("aes-256-cbc", key, iv);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
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

function normalizeSameSite(value) {
  const lower = String(value || "").toLowerCase();
  if (lower === "lax") return "Lax";
  if (lower === "strict") return "Strict";
  if (lower === "none" || lower === "no_restriction") return "None";
  return undefined;
}

function buildURL(cookie) {
  const domain = String(cookie.domain || "").replace(/^\./, "");
  return `${cookie.secure ? "https" : "http"}://${domain}${cookie.path || "/"}`;
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

function resolveOptions(rawArgs) {
  const config = readConfig(rawArgs["config-file"] || process.env.COOKIECLOUD_CONFIG || defaultConfigPath());
  return {
    cdp: rawArgs.cdp,
    androidCdp: rawArgs["android-cdp"],
    chrootCdp: rawArgs["chroot-cdp"],
    server: rawArgs.server || config.endpoint,
    uuid: rawArgs.uuid || config.uuid,
    password: rawArgs.password || config.password,
    include: rawArgs.include || toList(config.domains).join(","),
    blacklist: rawArgs.blacklist || toList(config.blacklist).join(","),
    interval: positiveNumber(rawArgs.interval || config.interval, 60),
  };
}

function readConfig(path) {
  if (!path) return {};
  try {
    return JSON.parse(readTextFile(path));
  } catch (error) {
    if (error.code === "ENOENT" && !process.argv.includes("--config-file")) return {};
    throw error;
  }
}

function readTextFile(path) {
  return fs.readFileSync(path, "utf8");
}

function defaultConfigPath() {
  return "/root/.local/share/helium-local-sync/cookiecloud-client.json";
}

function toList(value) {
  if (Array.isArray(value)) return value.map(String).filter(Boolean);
  if (typeof value === "string") return value.split(",").map((item) => item.trim()).filter(Boolean);
  return [];
}

function positiveNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withCDP(cdpURL, callback) {
  const cdp = await CDP.connect(cdpURL);
  try {
    return await callback(cdp);
  } finally {
    cdp.close();
  }
}

async function upload(cdpURL) {
  return await withCDP(cdpURL, async (cdp) => {
    const cookies = await cdp.call("Network.getAllCookies");
    const include = new Set((options.include || "").split(",").map((item) => item.trim()).filter(Boolean));
    const blacklist = new Set((options.blacklist || "").split(",").map((item) => item.trim()).filter(Boolean));
    const cookie_data = {};
    for (const cookie of cookies.result.cookies || []) {
      if (!cookie.domain) continue;
      if (include.size > 0 && ![...include].some((item) => cookie.domain.includes(item))) continue;
      if ([...blacklist].some((item) => cookie.domain.includes(item))) continue;
      cookie_data[cookie.domain] ||= [];
      cookie_data[cookie.domain].push({
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path || "/",
        secure: !!cookie.secure,
        httpOnly: !!cookie.httpOnly,
        sameSite: cookie.sameSite || "unspecified",
        expirationDate: cookie.expires && cookie.expires > 0 ? cookie.expires : undefined,
      });
    }
    const payload = {
      cookie_data,
      local_storage_data: {},
      update_time: new Date().toISOString(),
    };
    const encrypted = cookieCloudEncrypt(options.uuid, JSON.stringify(payload), options.password);
    const response = await fetch(trimSlash(options.server) + "/update", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ uuid: options.uuid, encrypted, crypto_type: "legacy" }),
    });
    if (!response.ok) throw new Error(`CookieCloud upload failed: ${response.status} ${await response.text()}`);
    return { action: "uploaded", domains: Object.keys(cookie_data).length };
  });
}

async function download(cdpURL) {
  return await withCDP(cdpURL, async (cdp) => {
    const response = await fetch(trimSlash(options.server) + "/get/" + encodeURIComponent(options.uuid));
    if (!response.ok) throw new Error(`CookieCloud download failed: ${response.status} ${await response.text()}`);
    const record = await response.json();
    const payload = JSON.parse(cookieCloudDecrypt(options.uuid, record.encrypted, options.password));
    let applied = 0;
    for (const cookies of Object.values(payload.cookie_data || {})) {
      if (!Array.isArray(cookies)) continue;
      for (const cookie of cookies) {
        const params = {
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path || "/",
          secure: !!cookie.secure,
          httpOnly: !!cookie.httpOnly,
          url: buildURL(cookie),
        };
        const sameSite = normalizeSameSite(cookie.sameSite);
        if (sameSite) params.sameSite = sameSite;
        const expires = Number(cookie.expirationDate || cookie.expires || 0);
        if (expires > 0) params.expires = expires;
        const result = await cdp.call("Network.setCookie", params);
        if (result.result?.success) applied++;
      }
    }
    return { action: "downloaded", applied };
  });
}

async function syncOnce() {
  const androidUpload = await upload(options.androidCdp);
  const chrootDownload = await download(options.chrootCdp);
  const chrootUpload = await upload(options.chrootCdp);
  const androidDownload = await download(options.androidCdp);
  return {
    action: "synced",
    androidUploadedDomains: androidUpload.domains,
    chrootApplied: chrootDownload.applied,
    chrootUploadedDomains: chrootUpload.domains,
    androidApplied: androidDownload.applied,
  };
}

async function main() {
  if (command === "upload") {
    console.log(JSON.stringify(await upload(options.cdp)));
  } else if (command === "download") {
    console.log(JSON.stringify(await download(options.cdp)));
  } else if (command === "sync") {
    console.log(JSON.stringify(await syncOnce()));
  } else {
    while (true) {
      try {
        console.log(JSON.stringify(await syncOnce()));
      } catch (error) {
        console.error(`cookiecloud-sync: ${error.message}`);
      }
      await sleep(Math.max(5, options.interval) * 1000);
    }
  }
}

await main();
