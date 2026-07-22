#!/usr/bin/env node

import crypto from "node:crypto";
import fsp from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function validateProbeResult(result) {
  if (!result || result.schema_version !== 1 || !result.finished_at) {
    throw new Error("probe did not finish with schema version 1");
  }
  if (result.fatal) throw new Error(`probe fatal error: ${result.fatal}`);
  if (!Number.isSafeInteger(result.expected_chunks) || result.expected_chunks < 3) {
    throw new Error("probe did not report a valid expected chunk count");
  }
  const expectedValues = Array.from(
    { length: result.expected_chunks }, (_, index) => `chunk-${String(index + 1).padStart(2, "0")}`,
  );
  const expected = `${expectedValues.join("\n")}\n`;
  for (const encoding of ["identity", "gzip", "br"]) {
    const stream = result[`fetch_${encoding}`];
    if (stream?.text !== expected) throw new Error(`${encoding} Fetch stream was incomplete or reordered`);
    if (!Array.isArray(stream.arrivals) || stream.arrivals.length < 2) {
      throw new Error(`${encoding} Fetch stream did not arrive progressively`);
    }
    if (!Number.isInteger(stream.interaction_ticks) || stream.interaction_ticks < 2) {
      throw new Error(`${encoding} Fetch stream blocked page progress`);
    }
    if (!Array.isArray(stream.chunk_milestones) || stream.chunk_milestones.length < 3) {
      throw new Error(`${encoding} Fetch stream did not expose three progressive chunk milestones`);
    }
    const milestoneCounts = stream.chunk_milestones.map(item => item?.count);
    if (milestoneCounts.at(-1) !== result.expected_chunks ||
        milestoneCounts.slice(0, -1).some((count, index) =>
          !Number.isInteger(count) || count < 1 || count >= milestoneCounts[index + 1])) {
      throw new Error(`${encoding} Fetch chunk milestones were invalid or reordered`);
    }
    if (!Number.isInteger(stream.headers_ms) || !Number.isInteger(stream.completed_ms) ||
        stream.headers_ms < 0 || stream.completed_ms <= stream.headers_ms) {
      throw new Error(`${encoding} Fetch timing evidence was invalid`);
    }
    const milestoneTimes = stream.chunk_milestones.map(item => item?.at_ms);
    if (milestoneTimes.some((time, index) =>
      !Number.isInteger(time) || time < stream.headers_ms || time > stream.completed_ms ||
      (index > 0 && time < milestoneTimes[index - 1]))) {
      throw new Error(`${encoding} Fetch milestone timing evidence was invalid`);
    }
  }
  if (JSON.stringify(result.sse?.values) !== JSON.stringify(expectedValues)) {
    throw new Error("SSE stream was incomplete or reordered");
  }
  if (!Array.isArray(result.sse.arrivals) || result.sse.arrivals.length < 3) {
    throw new Error("SSE stream did not arrive progressively");
  }
  if (!Number.isInteger(result.sse.interaction_ticks) || result.sse.interaction_ticks < 2) {
    throw new Error("SSE stream blocked page progress");
  }
  const mediaFiles = result.media_manifest?.files || {};
  const expectedMediaNames = {
    mp4: "h264-aac.mp4",
    webm: "vp9-opus.webm",
    mse: "h264-aac-fragmented.mp4",
  };
  for (const kind of ["mp4", "webm", "mse"]) {
    const fixture = mediaFiles[kind];
    if (!fixture || fixture.name !== expectedMediaNames[kind] ||
        !Number.isSafeInteger(fixture.bytes) || fixture.bytes <= 0 ||
        !/^[0-9a-f]{64}$/.test(fixture.sha256 || "")) {
      throw new Error(`${kind} media fixture was absent or unverified`);
    }
    const playback = result.playback?.find(item => item.name === kind);
    if (!playback?.ok || !(playback.duration > 0)) {
      throw new Error(`${kind} media fixture did not play to completion`);
    }
    if (!(playback.width > 0) || !(playback.height > 0)) {
      throw new Error(`${kind} media fixture produced no video dimensions`);
    }
    if (!(playback.audio_decoded_bytes > 0)) {
      throw new Error(`${kind} media fixture produced no decoded audio evidence`);
    }
  }
  if (!result.capabilities?.mp4_h264_aac || !result.capabilities?.webm_vp9_opus ||
      result.capabilities?.mse_mp4_h264_aac !== true) {
    throw new Error("required MP4/WebM/MSE codec capability was not reported");
  }
  const widevine = result.drm?.widevine;
  if (typeof widevine?.api_available !== "boolean" ||
      typeof widevine?.key_system_available !== "boolean" ||
      widevine?.key_system !== "com.widevine.alpha") {
    throw new Error("Widevine EME availability was not recorded separately from codec playback");
  }
  if (!result.runtime?.browser_product || !result.runtime?.browser_protocol_version ||
      !result.runtime?.browser_webkit_version || !result.runtime?.fixture_origin) {
    throw new Error("runtime browser and fixture provenance was not recorded");
  }
  return result;
}

export async function runProbe(options) {
  if (!options.cdp || !options.fixture || !options.output) {
    throw new Error("cdp, fixture, and output are required");
  }
  const cdpURL = requireLoopbackHTTP(options.cdp, "CDP");
  const fixtureURL = requireLoopbackHTTP(options.fixture, "fixture");
  const cdpBase = options.cdp.replace(/\/$/, "");
  const browserInfo = await checkedJSON(`${cdpBase}/json/version`);
  if (!browserInfo.webSocketDebuggerUrl) throw new Error(`no browser CDP target at ${options.cdp}`);

  const browser = new CDP(requireLoopbackWebSocket(browserInfo.webSocketDebuggerUrl, "browser CDP"));
  await browser.open();
  let targetID = "";
  let browserContextID = "";
  let page;
  try {
    ({ browserContextId: browserContextID } = await browser.call(
      "Target.createBrowserContext", { disposeOnDetach: true }, 10000,
    ));
    ({ targetId: targetID } = await browser.call("Target.createTarget", {
      url: options.fixture,
      browserContextId: browserContextID,
    }, 10000));
    const target = await waitForTarget(cdpBase, targetID);
    page = new CDP(requireLoopbackWebSocket(target.webSocketDebuggerUrl, "page CDP"));
    await page.open();
    await page.call("Runtime.enable");
    const response = await page.call("Runtime.evaluate", {
      expression: `new Promise(resolve => {
        const started = Date.now();
        const timer = setInterval(() => {
          if (globalThis.__heliumMediaResult) {
            clearInterval(timer);
            resolve(globalThis.__heliumMediaResult);
          } else if (Date.now() - started > 90000) {
            clearInterval(timer);
            resolve({schema_version:1, fatal:'browser probe timeout'});
          }
        }, 100);
      })`,
      awaitPromise: true,
      returnByValue: true,
    }, 95000);
    const rawResult = response.result?.value;
    if (!rawResult || typeof rawResult !== "object") {
      throw new Error("browser probe returned no structured result");
    }
    rawResult.runtime = {
      browser_product: browserInfo.Browser || "",
      browser_protocol_version: browserInfo["Protocol-Version"] || "",
      browser_revision: browserInfo["Revision"] || "",
      browser_webkit_version: browserInfo["WebKit-Version"] || "",
      cdp_origin: cdpURL.origin,
      fixture_origin: fixtureURL.origin,
    };
    const result = validateProbeResult(rawResult);
    await atomicWriteJSON(path.resolve(options.output), result);
    return result;
  } finally {
    page?.close();
    if (browserContextID) {
      await browser.call("Target.disposeBrowserContext", { browserContextId: browserContextID }).catch(() => {});
    } else if (targetID) {
      await browser.call("Target.closeTarget", { targetId: targetID }).catch(() => {});
    }
    browser.close();
  }
}

class CDP {
  constructor(url) {
    this.url = url;
    this.nextID = 0;
    this.pending = new Map();
  }

  open() {
    this.socket = new WebSocket(this.url);
    this.socket.onmessage = event => {
      const message = JSON.parse(event.data);
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result || {});
    };
    return new Promise((resolve, reject) => {
      this.socket.onopen = resolve;
      this.socket.onerror = reject;
    });
  }

  call(method, params = {}, timeout = 10000) {
    const id = ++this.nextID;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout for ${method}`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  close() {
    this.socket?.close();
  }
}

async function waitForTarget(cdpBase, targetID) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const targets = await checkedJSON(`${cdpBase}/json/list`);
    const target = targets.find(item => item.id === targetID && item.webSocketDebuggerUrl);
    if (target) return target;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`CDP target did not become available: ${targetID}`);
}

async function checkedJSON(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} returned HTTP ${response.status}`);
  return response.json();
}

export async function atomicWriteJSON(filePath, value) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  if (await fsp.lstat(filePath).then(() => true).catch(error => {
    if (error.code === "ENOENT") return false;
    throw error;
  })) {
    throw new Error(`refusing to overwrite existing probe evidence: ${filePath}`);
  }
  const temporary = `${filePath}.tmp-${process.pid}-${crypto.randomUUID()}`;
  try {
    await fsp.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
    await fsp.link(temporary, filePath);
    await fsp.unlink(temporary);
  } catch (error) {
    await fsp.rm(temporary, { force: true });
    throw error;
  }
}

function requireLoopbackHTTP(raw, name) {
  const parsed = new URL(raw);
  if (parsed.protocol !== "http:" || !new Set(["127.0.0.1", "localhost", "[::1]"]).has(parsed.hostname)) {
    throw new Error(`${name} URL must use loopback HTTP`);
  }
  return parsed;
}

function requireLoopbackWebSocket(raw, name) {
  const parsed = new URL(raw);
  if (parsed.protocol !== "ws:" || !new Set(["127.0.0.1", "localhost", "[::1]"]).has(parsed.hostname)) {
    throw new Error(`${name} URL must use a loopback WebSocket`);
  }
  return parsed.href;
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) throw new Error(`invalid argument: ${key}`);
    result[key.slice(2)] = argv[++index];
  }
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const result = await runProbe(args);
    process.stdout.write(`${JSON.stringify({event:"probe_passed", output:path.resolve(args.output), capabilities:result.capabilities})}\n`);
  } catch (error) {
    process.stderr.write(`Android media probe failed: ${error.message}\n`);
    process.exit(1);
  }
}
