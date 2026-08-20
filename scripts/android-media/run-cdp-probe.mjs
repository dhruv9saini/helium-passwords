#!/usr/bin/env node

import crypto from "node:crypto";
import fsp from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const COMMIT_PATTERN = /^[0-9a-f]{40}$/;
const SPKI_PATTERN = /^[A-Za-z0-9+/]{43}=$/;
const SPKI_SWITCH = "--ignore-certificate-errors-spki-list=";
const SOCKET_SWITCH = "--remote-debugging-socket-name=";
const PACKAGE_PATTERN = /^computer\.helium\.(?:passwords|control)\.test$/;
const SOCKET_PATTERN = /^helium_(?:sync|control)_test_devtools_remote$/;

export function validateFixtureBrowserCommandLine(argumentsList, expectedSPKI) {
  if (!SPKI_PATTERN.test(expectedSPKI || "")) {
    throw new Error("fixture SPKI must be one Base64-encoded SHA-256 fingerprint");
  }
  if (!Array.isArray(argumentsList) || argumentsList.some(value => typeof value !== "string")) {
    throw new Error("browser command line evidence was unavailable");
  }
  const admitted = `${SPKI_SWITCH}${expectedSPKI}`;
  const certificateOverrides = argumentsList.filter(value =>
    value === "--ignore-certificate-errors" || value.startsWith(SPKI_SWITCH));
  if (certificateOverrides.length !== 1 || certificateOverrides[0] !== admitted) {
    throw new Error("browser must use only the admitted disposable fixture SPKI override");
  }
  return admitted;
}

export function validateAndroidBrowserIdentity(browserInfo, options) {
  if (!PACKAGE_PATTERN.test(options.expectedPackage || "") ||
      !COMMIT_PATTERN.test(options.expectedChromiumCommit || "") ||
      !COMMIT_PATTERN.test(options.expectedHeliumSyncCommit || "") ||
      !SHA256_PATTERN.test(options.expectedArtifactSha256 || "")) {
    throw new Error("expected Android artifact identity is invalid");
  }
  if (browserInfo?.["Android-Package"] !== options.expectedPackage) {
    throw new Error("CDP endpoint belongs to a different Android package");
  }
  const webkitVersion = browserInfo?.["WebKit-Version"] || "";
  if (!webkitVersion.includes(`@${options.expectedChromiumCommit}`)) {
    throw new Error("CDP browser revision does not match the admitted Chromium commit");
  }
  return {
    package: options.expectedPackage,
    artifact_sha256: options.expectedArtifactSha256,
    chromium_commit: options.expectedChromiumCommit,
    helium_sync_commit: options.expectedHeliumSyncCommit,
  };
}

export function validateRemoteDebuggingSocket(argumentsList, expectedSocket) {
  if (!SOCKET_PATTERN.test(expectedSocket || "")) {
    throw new Error("expected disposable DevTools socket is invalid");
  }
  if (!Array.isArray(argumentsList) || argumentsList.some(value => typeof value !== "string")) {
    throw new Error("browser command line evidence was unavailable");
  }
  const admitted = `${SOCKET_SWITCH}${expectedSocket}`;
  const switches = argumentsList.filter(value => value.startsWith(SOCKET_SWITCH));
  if (switches.length !== 1 || switches[0] !== admitted) {
    throw new Error("browser must use the package-specific disposable DevTools socket");
  }
  if (argumentsList.filter(value => value === "--enable-automation").length !== 1) {
    throw new Error("browser must use one explicit enable-automation switch for command-line evidence");
  }
  return admitted;
}

export function createContentFreeChatGPTTiming(options) {
  const allowedFields = new Set([
    "status", "startedAt", "firstUpdateMs", "observationMs", "visibleUpdateCount",
    "package", "artifactSha256", "heliumSyncCommit", "chromiumCommit",
  ]);
  const unexpected = Object.keys(options).filter(name => !allowedFields.has(name));
  if (unexpected.length) {
    throw new Error(`ChatGPT timing evidence rejects unexpected fields: ${unexpected.join(", ")}`);
  }
  const status = options.status;
  if (!new Set(["completed", "failed", "timeout"]).has(status)) {
    throw new Error("ChatGPT timing status must be completed, failed, or timeout");
  }
  if (!new Set(["computer.helium.sync.test", "computer.helium.control.test"]).has(options.package)) {
    throw new Error("ChatGPT timing evidence requires a disposable browser package");
  }
  if (!SHA256_PATTERN.test(options.artifactSha256 || "")) {
    throw new Error("ChatGPT timing evidence requires the admitted artifact SHA-256");
  }
  for (const [name, commit] of [
    ["Helium Sync", options.heliumSyncCommit], ["Chromium", options.chromiumCommit],
  ]) {
    if (!COMMIT_PATTERN.test(commit || "")) {
      throw new Error(`ChatGPT timing evidence requires the ${name} full commit`);
    }
  }
  const startedAt = new Date(options.startedAt || "");
  if (!Number.isFinite(startedAt.valueOf()) || !String(options.startedAt).endsWith("Z")) {
    throw new Error("ChatGPT timing started-at must be an ISO-8601 UTC timestamp");
  }
  const observationMs = strictInteger(options.observationMs, "observation-ms", 1, 1_800_000);
  const visibleUpdateCount = strictInteger(
    options.visibleUpdateCount, "visible-update-count", 0, 1_000_000,
  );
  const firstUpdateMs = options.firstUpdateMs === undefined ? null :
    strictInteger(options.firstUpdateMs, "first-update-ms", 0, observationMs);
  if (status === "completed" && (firstUpdateMs === null || visibleUpdateCount < 3)) {
    throw new Error("completed ChatGPT timing requires a first update and at least three visible updates");
  }
  return {
    schema_version: 1,
    scenario: "chatgpt_stream_timing",
    status,
    started_at: startedAt.toISOString(),
    first_update_ms: firstUpdateMs,
    observation_ms: observationMs,
    visible_update_count_lower_bound: visibleUpdateCount,
    package: options.package,
    artifact_sha256: options.artifactSha256,
    helium_sync_commit: options.heliumSyncCommit,
    chromium_commit: options.chromiumCommit,
  };
}

export function validateProbeResult(result) {
  if (!result || result.schema_version !== 1 || !result.finished_at) {
    throw new Error("probe did not finish with schema version 1");
  }
  if (result.fatal) throw new Error(`probe fatal error: ${result.fatal}`);
  if (!Number.isSafeInteger(result.expected_chunks) || result.expected_chunks < 3) {
    throw new Error("probe did not report a valid expected chunk count");
  }
  if (!Number.isSafeInteger(result.expected_delay_ms) ||
      result.expected_delay_ms < 10 || result.expected_delay_ms > 5000) {
    throw new Error("probe did not report the admitted chunk delay");
  }
  const expectedValues = Array.from(
    { length: result.expected_chunks }, (_, index) => `chunk-${String(index + 1).padStart(2, "0")}`,
  );
  const expected = `${expectedValues.join("\n")}\n`;
  for (const encoding of ["identity", "gzip", "br"]) {
    const stream = result[`fetch_${encoding}`];
    validateFetchStream(
      stream, encoding, expected, result.expected_chunks, result.expected_delay_ms,
    );
  }
  const serviceWorker = result.service_worker;
  if (serviceWorker?.supported !== true || serviceWorker?.controlled !== true ||
      serviceWorker?.script_url !== "/service-worker.js") {
    throw new Error("Service Worker did not control the disposable streaming probe");
  }
  validateFetchStream(
    serviceWorker.stream, "Service Worker", expected, result.expected_chunks,
    result.expected_delay_ms,
  );
  if (!Array.isArray(result.required_transport_protocols) ||
      result.required_transport_protocols.some(protocol => !new Set(["h2", "h3"]).has(protocol)) ||
      new Set(result.required_transport_protocols).size !== result.required_transport_protocols.length) {
    throw new Error("required transport protocol list was invalid");
  }
  for (const protocol of result.required_transport_protocols) {
    validateFetchStream(
      result[`fetch_${protocol}`], protocol, expected, result.expected_chunks,
      result.expected_delay_ms, protocol,
    );
  }
  if (result.required_transport_protocols.includes("h3")) {
    const warmup = result.transport_warmup_h3;
    if (warmup?.status !== 200 || !Number.isInteger(warmup.completed_ms) ||
        warmup.completed_ms <= 0 || typeof warmup.protocol !== "string") {
      throw new Error("HTTP/3 Alt-Svc warmup evidence was absent or invalid");
    }
  }
  if (JSON.stringify(result.sse?.values) !== JSON.stringify(expectedValues)) {
    throw new Error("SSE stream was incomplete or reordered");
  }
  if (!Array.isArray(result.sse.arrivals) || result.sse.arrivals.length < 3) {
    throw new Error("SSE stream did not arrive progressively");
  }
  validateProgressiveTimes(result.sse.arrivals, "SSE", result.expected_delay_ms);
  if (!Number.isInteger(result.sse.interaction_ticks) || result.sse.interaction_ticks < 2) {
    throw new Error("SSE stream blocked page progress");
  }
  const mediaFiles = result.media_manifest?.files || {};
  const expectedMediaNames = {
    mp4: "h264-aac.mp4",
    mp4_high: "h264-high-aac.mp4",
    webm: "vp9-opus.webm",
    av1: "av1-opus.webm",
    mse: "h264-aac-fragmented.mp4",
    hls_manifest: "hls/stream.m3u8",
    hls_init: "hls/init.mp4",
    hls_segment_0: "hls/segment-000.m4s",
    hls_segment_1: "hls/segment-001.m4s",
    dash_manifest: "dash/stream.mpd",
    dash_media: "dash/h264-aac-fragmented.mp4",
  };
  for (const kind of Object.keys(expectedMediaNames)) {
    const fixture = mediaFiles[kind];
    if (!fixture || fixture.name !== expectedMediaNames[kind] ||
        !Number.isSafeInteger(fixture.bytes) || fixture.bytes <= 0 ||
        !/^[0-9a-f]{64}$/.test(fixture.sha256 || "")) {
      throw new Error(`${kind} media fixture was absent or unverified`);
    }
  }
  if (!result.capabilities?.mp4_h264_aac || !result.capabilities?.webm_vp9_opus ||
      result.capabilities?.mse_mp4_h264_aac !== true) {
    throw new Error("required MP4/WebM/MSE codec capability was not reported");
  }
  for (const capability of ["mp4_h264_high_aac", "webm_av1_opus", "hls"]) {
    if (typeof result.capabilities?.[capability] !== "string") {
      throw new Error(`${capability} capability was not recorded`);
    }
  }
  for (const capability of ["mp4_file", "mp4_high_file", "webm_file", "av1_file", "mp4_mse"]) {
    if (typeof result.media_capabilities?.[capability]?.supported !== "boolean") {
      throw new Error(`${capability} MediaCapabilities result was not recorded`);
    }
  }
  for (const capability of ["mp4_file", "webm_file", "mp4_mse"]) {
    if (!result.media_capabilities[capability].supported) {
      throw new Error(`${capability} required codec configuration was not declared supported`);
    }
  }
  const requiredPlayback = new Set(["mp4", "webm", "mse", "hls", "dash"]);
  if (result.capabilities.mp4_h264_high_aac || result.media_capabilities.mp4_high_file.supported) {
    requiredPlayback.add("mp4_high");
  }
  if (result.capabilities.webm_av1_opus || result.media_capabilities.av1_file.supported) {
    requiredPlayback.add("av1");
  }
  for (const kind of ["mp4", "mp4_high", "webm", "av1", "mse", "hls", "dash"]) {
    const playback = result.playback?.find(item => item.name === kind);
    if (!playback || typeof playback.ok !== "boolean") {
      throw new Error(`${kind} media playback outcome was not recorded`);
    }
    if (!requiredPlayback.has(kind) && !playback.ok) continue;
    if (!playback.ok || !(playback.duration > 0)) {
      throw new Error(`${kind} media fixture did not play to completion`);
    }
    if (!(playback.width > 0) || !(playback.height > 0)) {
      throw new Error(`${kind} media fixture produced no video dimensions`);
    }
    if (!(playback.audio_decoded_bytes > 0)) {
      throw new Error(`${kind} media fixture produced no decoded audio evidence`);
    }
    if (!(playback.total_frames > 0) ||
        !Number.isFinite(playback.dropped_frames) || playback.dropped_frames < 0) {
      throw new Error(`${kind} media fixture produced invalid frame evidence`);
    }
  }
  const widevine = result.drm?.widevine;
  if (typeof widevine?.api_available !== "boolean" ||
      typeof widevine?.key_system_available !== "boolean" ||
      widevine?.key_system !== "com.widevine.alpha") {
    throw new Error("Widevine EME availability was not recorded separately from codec playback");
  }
  if (!result.runtime?.browser_product || !result.runtime?.browser_protocol_version ||
      !result.runtime?.browser_webkit_version || !result.runtime?.fixture_origin ||
      !PACKAGE_PATTERN.test(result.runtime?.android_package || "") ||
      !SHA256_PATTERN.test(result.runtime?.artifact_sha256 || "") ||
      !COMMIT_PATTERN.test(result.runtime?.chromium_commit || "") ||
      !COMMIT_PATTERN.test(result.runtime?.helium_sync_commit || "") ||
      !SOCKET_PATTERN.test(result.runtime?.device_socket || "")) {
    throw new Error("runtime browser and fixture provenance was not recorded");
  }
  const lifecycleEvents = result.lifecycle?.events;
  if (!Array.isArray(lifecycleEvents) || lifecycleEvents.length < 2 ||
      lifecycleEvents[0]?.event !== "started" || lifecycleEvents.at(-1)?.event !== "completed" ||
      lifecycleEvents.some(event => !Number.isInteger(event?.at_ms) ||
        typeof event?.visibility !== "string" || typeof event?.online !== "boolean")) {
    throw new Error("browser lifecycle observations were absent or invalid");
  }
  const lifecycleRequirements = result.required_lifecycle || {};
  if (typeof lifecycleRequirements.background_foreground !== "boolean" ||
      typeof lifecycleRequirements.network_handoff !== "boolean") {
    throw new Error("browser lifecycle requirements were absent or invalid");
  }
  if (lifecycleRequirements.background_foreground) {
    const hiddenIndex = lifecycleEvents.findIndex(event =>
      event.event === "visibilitychange" && event.visibility === "hidden");
    const visibleIndex = lifecycleEvents.findIndex((event, index) =>
      index > hiddenIndex && event.event === "visibilitychange" && event.visibility === "visible");
    if (hiddenIndex < 0 || visibleIndex < 0) {
      throw new Error("required background/foreground lifecycle was not observed");
    }
  }
  if (lifecycleRequirements.network_handoff &&
      !lifecycleEvents.some(event => event.event === "connectionchange")) {
    throw new Error("required network handoff was not observed");
  }
  if (result.media_diagnostics?.source !== "CDP Media domain" ||
      result.media_diagnostics?.enabled !== true ||
      !Number.isSafeInteger(result.media_diagnostics?.event_count) ||
      result.media_diagnostics.event_count < 1 ||
      !Number.isSafeInteger(result.media_diagnostics?.player_count) ||
      result.media_diagnostics.player_count < 1) {
    throw new Error("browser-observable CDP Media diagnostics were absent");
  }
  return result;
}

function validateFetchStream(
  stream, label, expected, expectedChunks, expectedDelayMs, expectedProtocol = "",
) {
  if (stream?.text !== expected) throw new Error(`${label} Fetch stream was incomplete or reordered`);
  if (!Array.isArray(stream.arrivals) || stream.arrivals.length < 2) {
    throw new Error(`${label} Fetch stream did not arrive progressively`);
  }
  if (!Number.isInteger(stream.interaction_ticks) || stream.interaction_ticks < 2) {
    throw new Error(`${label} Fetch stream blocked page progress`);
  }
  if (!Array.isArray(stream.chunk_milestones) || stream.chunk_milestones.length < 3) {
    throw new Error(`${label} Fetch stream did not expose three progressive chunk milestones`);
  }
  const milestoneCounts = stream.chunk_milestones.map(item => item?.count);
  if (milestoneCounts.at(-1) !== expectedChunks ||
      milestoneCounts.slice(0, -1).some((count, index) =>
        !Number.isInteger(count) || count < 1 || count >= milestoneCounts[index + 1])) {
    throw new Error(`${label} Fetch chunk milestones were invalid or reordered`);
  }
  if (!Number.isInteger(stream.headers_ms) || !Number.isInteger(stream.completed_ms) ||
      stream.headers_ms < 0 || stream.completed_ms <= stream.headers_ms) {
    throw new Error(`${label} Fetch timing evidence was invalid`);
  }
  const milestoneTimes = stream.chunk_milestones.map(item => item?.at_ms);
  if (milestoneTimes.some(time =>
    !Number.isInteger(time) || time < stream.headers_ms || time > stream.completed_ms)) {
    throw new Error(`${label} Fetch milestone timing evidence was invalid`);
  }
  validateProgressiveTimes(milestoneTimes, `${label} Fetch`, expectedDelayMs);
  if (expectedProtocol && stream.protocol !== expectedProtocol) {
    throw new Error(`${label} Fetch negotiated ${stream.protocol || "no protocol"}, expected ${expectedProtocol}`);
  }
}

function validateProgressiveTimes(times, label, expectedDelayMs) {
  if (!Array.isArray(times) || times.length < 3 ||
      times.some((time, index) => !Number.isInteger(time) || time < 0 ||
        (index > 0 && time <= times[index - 1])) ||
      times.at(-1) - times[0] < Math.max(1, Math.floor(expectedDelayMs / 2))) {
    throw new Error(`${label} timing did not prove progressive delivery`);
  }
}

export async function runProbe(options) {
  if (!options.cdp || !options.fixture || !options.output ||
      !options.mediaDiagnostics) {
    throw new Error("cdp, fixture, output, and media-diagnostics are required");
  }
  const cdpURL = requireLoopbackHTTP(options.cdp, "CDP");
  const fixtureURL = requireLoopbackHTTP(options.fixture, "fixture");
  const targetFixtureURL = new URL(fixtureURL);
  const requiredTransportProtocols = [];
  const transportFixtureOrigins = {};
  for (const protocol of ["h2", "h3"]) {
    if (!options[protocol]) continue;
    const endpoint = requireProtocolFixture(options[protocol], protocol);
    targetFixtureURL.searchParams.set(protocol, endpoint.href);
    requiredTransportProtocols.push(protocol);
    transportFixtureOrigins[protocol] = endpoint.origin;
  }
  if (requiredTransportProtocols.length && !SPKI_PATTERN.test(options.fixtureSpki || "")) {
    throw new Error("private protocol fixtures require their exact leaf SPKI fingerprint");
  }
  const cdpBase = options.cdp.replace(/\/$/, "");
  const browserInfo = await checkedJSON(`${cdpBase}/json/version`);
  if (!browserInfo.webSocketDebuggerUrl) throw new Error(`no browser CDP target at ${options.cdp}`);
  const artifactIdentity = validateAndroidBrowserIdentity(browserInfo, options);

  const browser = new CDP(requireLoopbackWebSocket(browserInfo.webSocketDebuggerUrl, "browser CDP"));
  await browser.open();
  let targetID = "";
  let browserContextID = "";
  let page;
  try {
    let admittedFixtureSwitch = "";
    const commandLine = await browser.call("Browser.getBrowserCommandLine", {}, 10000);
    const admittedSocketSwitch = validateRemoteDebuggingSocket(
      commandLine.arguments, options.expectedDeviceSocket,
    );
    if (requiredTransportProtocols.length) {
      admittedFixtureSwitch = validateFixtureBrowserCommandLine(
        commandLine.arguments, options.fixtureSpki,
      );
    }
    ({ browserContextId: browserContextID } = await browser.call(
      "Target.createBrowserContext", { disposeOnDetach: true }, 10000,
    ));
    ({ targetId: targetID } = await browser.call("Target.createTarget", {
      url: "about:blank",
      browserContextId: browserContextID,
    }, 10000));
    const target = await waitForTarget(cdpBase, targetID);
    page = new CDP(requireLoopbackWebSocket(target.webSocketDebuggerUrl, "page CDP"));
    await page.open();
    await page.call("Page.enable");
    await page.call("Runtime.enable");
    await page.call("Media.enable");
    await page.call("Page.navigate", { url: targetFixtureURL.href });
    await waitForPageURL(page, targetFixtureURL.href);
    if (options.readyFile) {
      await atomicWriteJSON(path.resolve(options.readyFile), {
        schema_version: 1,
        state: "probe_page_connected",
      });
    }
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
    rawResult.required_transport_protocols = requiredTransportProtocols;
    rawResult.required_lifecycle = {
      background_foreground: options.requireLifecycle === "true",
      network_handoff: options.requireNetworkHandoff === "true",
    };
    rawResult.runtime = {
      browser_product: browserInfo.Browser || "",
      browser_protocol_version: browserInfo["Protocol-Version"] || "",
      browser_revision: browserInfo["Revision"] || "",
      browser_webkit_version: browserInfo["WebKit-Version"] || "",
      android_package: artifactIdentity.package,
      artifact_sha256: artifactIdentity.artifact_sha256,
      chromium_commit: artifactIdentity.chromium_commit,
      helium_sync_commit: artifactIdentity.helium_sync_commit,
      device_socket: options.expectedDeviceSocket,
      device_socket_switch: admittedSocketSwitch,
      cdp_origin: cdpURL.origin,
      fixture_origin: fixtureURL.origin,
      transport_fixture_origins: transportFixtureOrigins,
      fixture_spki_sha256_base64: options.fixtureSpki || "",
      fixture_certificate_override: admittedFixtureSwitch,
    };
    const mediaDiagnostics = page.mediaDiagnostics();
    rawResult.media_diagnostics = mediaDiagnostics.summary;
    await atomicWriteJSON(
      path.resolve(options.mediaDiagnostics), mediaDiagnostics.evidence,
    );
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
    this.mediaEvents = [];
    this.mediaOverflow = false;
  }

  open() {
    this.socket = new WebSocket(this.url);
    this.socket.onmessage = event => {
      const message = JSON.parse(event.data);
      if (!message.id && message.method?.startsWith("Media.")) {
        if (this.mediaEvents.length >= 4096) {
          this.mediaOverflow = true;
          return;
        }
        this.mediaEvents.push({
          method: message.method,
          params: boundedJSON(message.params || {}, 0),
        });
        return;
      }
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

  mediaDiagnostics() {
    if (this.mediaOverflow) {
      throw new Error("CDP Media diagnostics exceeded the event bound");
    }
    const players = new Set();
    const methodCounts = {};
    for (const event of this.mediaEvents) {
      const playerID = event.params?.playerId;
      if (typeof playerID === "string" && playerID) players.add(playerID);
      methodCounts[event.method] = (methodCounts[event.method] || 0) + 1;
    }
    const summary = {
      source: "CDP Media domain",
      enabled: true,
      event_count: this.mediaEvents.length,
      player_count: players.size,
      method_counts: methodCounts,
    };
    return {
      summary,
      evidence: {
        schema_version: 1,
        synthetic_fixture_only: true,
        ...summary,
        events: this.mediaEvents,
      },
    };
  }
}

function boundedJSON(value, depth) {
  if (depth > 8) throw new Error("CDP Media diagnostic nesting exceeded");
  if (value === null || typeof value === "boolean" ||
      (typeof value === "number" && Number.isFinite(value))) {
    return value;
  }
  if (typeof value === "string") {
    return value.length > 4096 ? `${value.slice(0, 4096)}[truncated]` : value;
  }
  if (Array.isArray(value)) {
    if (value.length > 512) {
      throw new Error("CDP Media diagnostic array exceeded");
    }
    return value.map(item => boundedJSON(item, depth + 1));
  }
  if (typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length > 512) {
      throw new Error("CDP Media diagnostic object exceeded");
    }
    return Object.fromEntries(entries.map(
      ([key, item]) => [key, boundedJSON(item, depth + 1)],
    ));
  }
  throw new Error("CDP Media diagnostic contained an unsupported value");
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

async function waitForPageURL(page, expectedURL) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const response = await page.call("Runtime.evaluate", {
      expression: "location.href",
      returnByValue: true,
    }).catch(() => null);
    if (response?.result?.value === expectedURL) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`CDP page did not navigate to the admitted fixture: ${expectedURL}`);
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

function requireProtocolFixture(raw, protocol) {
  const parsed = new URL(raw);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.hash) {
    throw new Error(`${protocol} fixture URL must use credential-free HTTPS without a fragment`);
  }
  if (parsed.pathname !== "/stream/fetch" ||
      parsed.searchParams.size !== 1 || parsed.searchParams.get("encoding") !== "identity") {
    throw new Error(`${protocol} fixture URL must be the fixed identity Fetch endpoint`);
  }
  return parsed;
}

function strictInteger(value, name, minimum, maximum) {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return parsed;
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
    if (args["chatgpt-status"]) {
      if (!args.output) throw new Error("output is required");
      const allowedArgs = new Set([
        "chatgpt-status", "started-at", "first-update-ms", "observation-ms",
        "visible-update-count", "package", "artifact-sha256", "helium-sync-commit",
        "chromium-commit", "output",
      ]);
      const unexpected = Object.keys(args).filter(name => !allowedArgs.has(name));
      if (unexpected.length) {
        throw new Error(`ChatGPT timing mode rejects unexpected arguments: ${unexpected.join(", ")}`);
      }
      const result = createContentFreeChatGPTTiming({
        status: args["chatgpt-status"],
        startedAt: args["started-at"],
        firstUpdateMs: args["first-update-ms"],
        observationMs: args["observation-ms"],
        visibleUpdateCount: args["visible-update-count"],
        package: args.package,
        artifactSha256: args["artifact-sha256"],
        heliumSyncCommit: args["helium-sync-commit"],
        chromiumCommit: args["chromium-commit"],
      });
      await atomicWriteJSON(path.resolve(args.output), result);
      process.stdout.write(`${JSON.stringify({
        event:"content_free_chatgpt_timing_recorded", output:path.resolve(args.output), status:result.status,
      })}\n`);
    } else {
      const allowedArgs = new Set([
        "cdp", "fixture", "output", "h2", "h3", "ready-file",
        "fixture-spki", "require-lifecycle", "require-network-handoff",
        "expected-package", "expected-artifact-sha256", "expected-chromium-commit",
        "expected-helium-sync-commit", "expected-device-socket",
      ]);
      const unexpected = Object.keys(args).filter(name => !allowedArgs.has(name));
      if (unexpected.length) {
        throw new Error(`probe mode rejects unexpected arguments: ${unexpected.join(", ")}`);
      }
      for (const name of ["require-lifecycle", "require-network-handoff"]) {
        if (args[name] !== undefined && !new Set(["true", "false"]).has(args[name])) {
          throw new Error(`${name} must be true or false`);
        }
      }
      args.readyFile = args["ready-file"];
      args.fixtureSpki = args["fixture-spki"];
      args.requireLifecycle = args["require-lifecycle"] || "false";
      args.requireNetworkHandoff = args["require-network-handoff"] || "false";
      args.expectedPackage = args["expected-package"];
      args.expectedArtifactSha256 = args["expected-artifact-sha256"];
      args.expectedChromiumCommit = args["expected-chromium-commit"];
      args.expectedHeliumSyncCommit = args["expected-helium-sync-commit"];
      args.expectedDeviceSocket = args["expected-device-socket"];
      const result = await runProbe(args);
      process.stdout.write(`${JSON.stringify({event:"probe_passed", output:path.resolve(args.output), capabilities:result.capabilities})}\n`);
    }
  } catch (error) {
    process.stderr.write(`Android media acceptance failed: ${error.message}\n`);
    process.exit(1);
  }
}
