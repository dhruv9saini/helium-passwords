#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";
import zlib from "node:zlib";

const DEFAULT_PORT = 44721;
const DEFAULT_CHUNKS = 4;
const DEFAULT_DELAY_MS = 100;
const MEDIA_FILES = {
  mp4: "h264-aac.mp4",
  mp4_high: "h264-high-aac.mp4",
  mse: "h264-aac-fragmented.mp4",
  webm: "vp9-opus.webm",
  av1: "av1-opus.webm",
  hls_manifest: "hls/stream.m3u8",
  hls_init: "hls/init.mp4",
  hls_segment_0: "hls/segment-000.m4s",
  hls_segment_1: "hls/segment-001.m4s",
  dash_manifest: "dash/stream.mpd",
  dash_media: "dash/h264-aac-fragmented.mp4",
};

export async function createFixtureServer(options = {}) {
  const host = options.host || "127.0.0.1";
  const port = numberOption(options.port, DEFAULT_PORT, 0, 65535, "port");
  const chunks = numberOption(options.chunks, DEFAULT_CHUNKS, 3, 20, "chunks");
  const delayMs = numberOption(options.delayMs, DEFAULT_DELAY_MS, 10, 5000, "delay-ms");
  const mediaDir = options.mediaDir ? path.resolve(options.mediaDir) : "";
  if (mediaDir && !(await isDirectory(mediaDir))) {
    throw new Error(`media directory does not exist: ${mediaDir}`);
  }

  const server = http.createServer((request, response) => {
    handleRequest(request, response, { chunks, delayMs, mediaDir }).catch(error => {
      if (!response.headersSent) {
        response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      }
      response.end(`fixture error: ${error.message}\n`);
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fixture server has no TCP address");
  return {
    host,
    port: address.port,
    origin: `http://${host}:${address.port}`,
    close: () => new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}

async function handleRequest(request, response, options) {
  const url = new URL(request.url || "/", "http://fixture.invalid");
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/probe")) {
    send(response, 200, "text/html; charset=utf-8", probePage(options.chunks));
    return;
  }
  if (request.method === "GET" && url.pathname === "/manifest.json") {
    send(response, 200, "application/json", JSON.stringify(await mediaManifest(options.mediaDir)));
    return;
  }
  if (request.method === "GET" && url.pathname === "/stream/fetch") {
    const encoding = url.searchParams.get("encoding") || "identity";
    await sendNumberedStream(response, encoding, options.chunks, options.delayMs);
    return;
  }
  if (request.method === "GET" && url.pathname === "/stream/sse") {
    await sendEventStream(response, options.chunks, options.delayMs);
    return;
  }
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname.startsWith("/media/")) {
    await sendMedia(request, response, options.mediaDir, url.pathname.slice("/media/".length));
    return;
  }
  send(response, 404, "text/plain; charset=utf-8", "not found\n");
}

async function sendNumberedStream(response, encoding, chunks, delayMs) {
  if (!new Set(["identity", "gzip", "br"]).has(encoding)) {
    send(response, 400, "text/plain; charset=utf-8", "unknown encoding\n");
    return;
  }
  const headers = {
    "access-control-allow-origin": "*",
    "cache-control": "no-store, no-transform",
    "content-type": "text/plain; charset=utf-8",
    "timing-allow-origin": "*",
    "x-content-type-options": "nosniff",
  };
  if (encoding !== "identity") headers["content-encoding"] = encoding;
  response.writeHead(200, headers);
  response.flushHeaders();

  let output = response;
  if (encoding === "gzip") {
    output = zlib.createGzip({ flush: zlib.constants.Z_SYNC_FLUSH });
    output.pipe(response);
  } else if (encoding === "br") {
    output = zlib.createBrotliCompress({
      flush: zlib.constants.BROTLI_OPERATION_FLUSH,
      params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 1 },
    });
    output.pipe(response);
  }

  for (let index = 1; index <= chunks; index += 1) {
    output.write(`chunk-${String(index).padStart(2, "0")}\n`);
    if (output !== response) await flushCompression(output);
    if (index !== chunks) await delay(delayMs);
  }
  output.end();
}

async function sendEventStream(response, chunks, delayMs) {
  response.writeHead(200, {
    "cache-control": "no-store, no-transform",
    "content-type": "text/event-stream; charset=utf-8",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
  response.flushHeaders();
  for (let index = 1; index <= chunks; index += 1) {
    response.write(`id: ${index}\nevent: chunk\ndata: chunk-${String(index).padStart(2, "0")}\n\n`);
    if (index !== chunks) await delay(delayMs);
  }
  response.end("event: done\ndata: done\n\n");
}

async function sendMedia(request, response, mediaDir, requestedName) {
  if (!mediaDir || !Object.values(MEDIA_FILES).includes(requestedName)) {
    send(response, 404, "text/plain; charset=utf-8", "media fixture not found\n");
    return;
  }
  const filePath = path.join(mediaDir, requestedName);
  const stat = await fsp.stat(filePath).catch(() => null);
  if (!stat?.isFile()) {
    send(response, 404, "text/plain; charset=utf-8", "media fixture not found\n");
    return;
  }

  const range = parseRange(request.headers.range, stat.size);
  if (range === null) {
    response.writeHead(416, { "content-range": `bytes */${stat.size}` });
    response.end();
    return;
  }
  const type = mediaType(requestedName);
  const headers = {
    "accept-ranges": "bytes",
    "cache-control": "no-store",
    "content-type": type,
  };
  if (range) {
    headers["content-length"] = String(range.end - range.start + 1);
    headers["content-range"] = `bytes ${range.start}-${range.end}/${stat.size}`;
    response.writeHead(206, headers);
  } else {
    headers["content-length"] = String(stat.size);
    response.writeHead(200, headers);
  }
  if (request.method === "HEAD") {
    response.end();
    return;
  }
  const stream = fs.createReadStream(filePath, range || undefined);
  stream.on("error", error => response.destroy(error));
  stream.pipe(response);
}

function parseRange(header, size) {
  if (!header) return undefined;
  const match = /^bytes=(\d+)-(\d*)$/.exec(header);
  if (!match) return null;
  const start = Number(match[1]);
  const end = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) return null;
  return { start, end: Math.min(end, size - 1) };
}

async function mediaManifest(mediaDir) {
  const manifest = { schema_version: 1, files: {} };
  if (!mediaDir) return manifest;
  for (const [kind, name] of Object.entries(MEDIA_FILES)) {
    const filePath = path.join(mediaDir, name);
    const data = await fsp.readFile(filePath).catch(() => null);
    if (data) {
      manifest.files[kind] = {
        name,
        bytes: data.length,
        sha256: crypto.createHash("sha256").update(data).digest("hex"),
      };
    }
  }
  return manifest;
}

function mediaType(name) {
  if (name.endsWith(".webm")) return "video/webm";
  if (name.endsWith(".m3u8")) return "application/vnd.apple.mpegurl";
  if (name.endsWith(".mpd")) return "application/dash+xml";
  if (name.endsWith(".m4s")) return "video/iso.segment";
  return "video/mp4";
}

function probePage(expectedChunks) {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Helium Android media and streaming probe</title>
<style>body{font:14px system-ui;margin:1rem}pre{white-space:pre-wrap}video{display:block;max-width:320px;margin:.5rem 0}</style>
<h1>Helium Android media and streaming probe</h1>
<pre id="result">running</pre>
<div id="videos"></div>
<script>
const resultNode = document.querySelector('#result');
const results = {schema_version: 1, expected_chunks: ${expectedChunks}, user_agent: navigator.userAgent, started_at: new Date().toISOString()};
const mp4Mime = 'video/mp4; codecs="avc1.42E01E, mp4a.40.2"';
const mp4HighMime = 'video/mp4; codecs="avc1.640028, mp4a.40.2"';
const webmMime = 'video/webm; codecs="vp09.00.10.08, opus"';
const av1Mime = 'video/webm; codecs="av01.0.04M.08, opus"';
const hlsMime = 'application/vnd.apple.mpegurl';
let interactionTicks = 0;
setInterval(() => { interactionTicks += 1; }, 25);
function show(){ resultNode.textContent = JSON.stringify(results, null, 2); }
function connectionSnapshot(event) {
  const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  return {
    event,
    at_ms: Math.round(performance.now()),
    visibility: document.visibilityState,
    online: navigator.onLine,
    effective_type: connection?.effectiveType || '',
    type: connection?.type || '',
    downlink_mbps: Number.isFinite(connection?.downlink) ? connection.downlink : null,
    rtt_ms: Number.isFinite(connection?.rtt) ? connection.rtt : null,
  };
}
results.lifecycle = {events:[connectionSnapshot('started')]};
document.addEventListener('visibilitychange', () => {
  results.lifecycle.events.push(connectionSnapshot('visibilitychange')); show();
});
for (const event of ['online','offline','pageshow','pagehide']) {
  addEventListener(event, () => { results.lifecycle.events.push(connectionSnapshot(event)); show(); });
}
const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
connection?.addEventListener?.('change', () => { results.lifecycle.events.push(connectionSnapshot('connectionchange')); show(); });
async function stream(path) {
  const started = performance.now(), ticksBefore = interactionTicks;
  const response = await fetch(path, {cache:'no-store'});
  const headersAt = performance.now();
  if (!response.ok || !response.body) throw new Error('HTTP ' + response.status);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const arrivals = [], chunk_milestones = [];
  let text = '';
  let observedChunks = 0;
  while (true) {
    const item = await reader.read();
    if (item.done) break;
    arrivals.push(Math.round(performance.now() - started));
    text += decoder.decode(item.value, {stream:true});
    const completeChunks = (text.match(/chunk-\\d{2}\\n/g) || []).length;
    if (completeChunks > observedChunks) {
      observedChunks = completeChunks;
      chunk_milestones.push({count:completeChunks, at_ms:Math.round(performance.now() - started)});
    }
  }
  text += decoder.decode();
  const timing = performance.getEntriesByName(response.url).at(-1);
  return {
    text, arrivals, chunk_milestones,
    headers_ms: Math.round(headersAt - started),
    completed_ms: Math.round(performance.now() - started),
    interaction_ticks: interactionTicks - ticksBefore,
    protocol: timing?.nextHopProtocol || '',
    response_encoding: response.headers.get('content-encoding') || 'identity',
  };
}
async function warmTransport(path) {
  const started = performance.now();
  const response = await fetch(path, {cache:'no-store'});
  await response.arrayBuffer();
  const timing = performance.getEntriesByName(response.url).at(-1);
  return {
    status: response.status,
    completed_ms: Math.max(1, Math.round(performance.now() - started)),
    protocol: timing?.nextHopProtocol || '',
  };
}
function sse() {
  return new Promise((resolve, reject) => {
    const started = performance.now(), ticksBefore = interactionTicks;
    const values = [], arrivals = [], source = new EventSource('/stream/sse');
    const timer = setTimeout(() => { source.close(); reject(new Error('SSE timeout')); }, 10000);
    source.addEventListener('chunk', event => { values.push(event.data); arrivals.push(Math.round(performance.now() - started)); });
    source.addEventListener('done', () => {
      clearTimeout(timer); source.close();
      resolve({values, arrivals, interaction_ticks:interactionTicks - ticksBefore});
    });
    source.onerror = () => { clearTimeout(timer); source.close(); reject(new Error('SSE failed')); };
  });
}
function play(name, src) {
  return new Promise(resolve => {
    const video = document.createElement('video');
    video.controls = true; video.muted = true; video.playsInline = true; video.src = src;
    document.querySelector('#videos').append(video);
    const timer = setTimeout(() => resolve({name, ok:false, error:'timeout', ready_state:video.readyState}), 12000);
    video.onended = () => {
      clearTimeout(timer);
      const quality = video.getVideoPlaybackQuality?.();
      resolve({
        name, ok:true, duration:video.duration, width:video.videoWidth, height:video.videoHeight,
        total_frames: quality?.totalVideoFrames ?? null,
        dropped_frames: quality?.droppedVideoFrames ?? null,
        audio_decoded_bytes: video.webkitAudioDecodedByteCount ?? null,
      });
    };
    video.onerror = () => { clearTimeout(timer); resolve({name, ok:false, error:video.error?.message || String(video.error?.code || 'media error')}); };
    video.play().catch(error => { clearTimeout(timer); resolve({name, ok:false, error:String(error)}); });
  });
}
async function playMseParts(sources, name = 'mse') {
  if (!window.MediaSource || !MediaSource.isTypeSupported(mp4Mime)) return {name, ok:false, error:'unsupported'};
  const video = document.createElement('video'); video.controls=true; video.muted=true; video.playsInline=true;
  document.querySelector('#videos').append(video);
  const mediaSource = new MediaSource(); video.src = URL.createObjectURL(mediaSource);
  await new Promise((resolve,reject) => { mediaSource.onsourceopen=resolve; mediaSource.onerror=reject; });
  const sourceBuffer = mediaSource.addSourceBuffer(mp4Mime);
  for (const src of sources) {
    const response = await fetch(src, {cache:'no-store'});
    if (!response.ok) throw new Error('MSE media HTTP ' + response.status);
    const bytes = await response.arrayBuffer();
    await new Promise((resolve,reject) => {
      sourceBuffer.addEventListener('updateend', resolve, {once:true});
      sourceBuffer.addEventListener('error', reject, {once:true});
      sourceBuffer.appendBuffer(bytes);
    });
  }
  mediaSource.endOfStream();
  return new Promise(resolve => {
    const timer=setTimeout(() => resolve({name,ok:false,error:'timeout'}),12000);
    video.onended=()=>{
      clearTimeout(timer);
      const quality=video.getVideoPlaybackQuality?.();
      resolve({
        name,ok:true,duration:video.duration,width:video.videoWidth,height:video.videoHeight,
        total_frames:quality?.totalVideoFrames??null,dropped_frames:quality?.droppedVideoFrames??null,
        audio_decoded_bytes:video.webkitAudioDecodedByteCount??null,
      });
    };
    video.onerror=()=>{clearTimeout(timer);resolve({name,ok:false,error:String(video.error?.code||'media error')});};
    video.play().catch(error=>{clearTimeout(timer);resolve({name,ok:false,error:String(error)});});
  });
}
async function playMse(src, name = 'mse') { return playMseParts([src], name); }
async function playHls(manifestPath) {
  try {
    const response = await fetch(manifestPath, {cache:'no-store'});
    if (!response.ok) throw new Error('HLS manifest HTTP ' + response.status);
    const manifest = await response.text();
    const map = /^#EXT-X-MAP:URI="([^"]+)"$/m.exec(manifest)?.[1] || '';
    const segments = manifest.split(/\\r?\\n/).map(line => line.trim())
      .filter(line => line && !line.startsWith('#'));
    if (!map || segments.length < 1) throw new Error('HLS init or media segments were absent');
    const sources = [map, ...segments].map(reference => new URL(reference, response.url));
    if (sources.some(source => source.origin !== location.origin ||
        !source.pathname.startsWith('/media/hls/') || source.search || source.hash)) {
      throw new Error('HLS media escaped the fixed fixture directory');
    }
    return await playMseParts(sources.map(source => source.href), 'hls');
  } catch (error) {
    return {name:'hls',ok:false,error:String(error)};
  }
}
async function playDash(manifestPath) {
  try {
    const response = await fetch(manifestPath, {cache:'no-store'});
    if (!response.ok) throw new Error('DASH manifest HTTP ' + response.status);
    const documentNode = new DOMParser().parseFromString(await response.text(), 'application/xml');
    if (documentNode.querySelector('parsererror')) throw new Error('DASH manifest XML was invalid');
    const base = documentNode.querySelector('BaseURL')?.textContent?.trim() || '';
    if (!/^[a-zA-Z0-9._-]+$/.test(base)) throw new Error('DASH BaseURL was absent or unsafe');
    const mediaURL = new URL(base, response.url);
    if (mediaURL.origin !== location.origin) throw new Error('DASH media escaped the fixture origin');
    return await playMse(mediaURL.pathname, 'dash');
  } catch (error) {
    return {name:'dash',ok:false,error:String(error)};
  }
}
async function decodingInfo(type, videoContentType, audioContentType) {
  if (!navigator.mediaCapabilities?.decodingInfo) return {supported:false, error:'MediaCapabilities unavailable'};
  try {
    return await navigator.mediaCapabilities.decodingInfo({
      type,
      video:{contentType:videoContentType,width:320,height:180,bitrate:400000,framerate:30},
      audio:{contentType:audioContentType,channels:'1',bitrate:96000,samplerate:48000},
    });
  } catch (error) { return {supported:false,error:String(error)}; }
}
async function widevineSupport() {
  const keySystem = 'com.widevine.alpha';
  if (!navigator.requestMediaKeySystemAccess) {
    return {api_available:false,key_system:keySystem,key_system_available:false,error:'EME API unavailable'};
  }
  try {
    const access = await navigator.requestMediaKeySystemAccess(keySystem, [{
      initDataTypes:['cenc'],
      distinctiveIdentifier:'optional',
      persistentState:'optional',
      sessionTypes:['temporary'],
      videoCapabilities:[{contentType:mp4Mime}],
      audioCapabilities:[{contentType:'audio/mp4; codecs="mp4a.40.2"'}],
    }]);
    return {
      api_available:true,
      key_system:keySystem,
      key_system_available:true,
      configuration:access.getConfiguration(),
    };
  } catch (error) {
    return {api_available:true,key_system:keySystem,key_system_available:false,error:String(error)};
  }
}
(async () => {
  const probeVideo = document.createElement('video');
  results.capabilities = {
    mp4_h264_aac: probeVideo.canPlayType(mp4Mime),
    mp4_h264_high_aac: probeVideo.canPlayType(mp4HighMime),
    webm_vp9_opus: probeVideo.canPlayType(webmMime),
    webm_av1_opus: probeVideo.canPlayType(av1Mime),
    hls: probeVideo.canPlayType(hlsMime),
    mse_mp4_h264_aac: Boolean(window.MediaSource && MediaSource.isTypeSupported(mp4Mime)),
    mse_webm_vp9_opus: Boolean(window.MediaSource && MediaSource.isTypeSupported(webmMime)),
    mse_webm_av1_opus: Boolean(window.MediaSource && MediaSource.isTypeSupported(av1Mime)),
  };
  results.media_capabilities = {
    mp4_file: await decodingInfo('file','video/mp4; codecs="avc1.42E01E"','audio/mp4; codecs="mp4a.40.2"'),
    mp4_high_file: await decodingInfo('file','video/mp4; codecs="avc1.640028"','audio/mp4; codecs="mp4a.40.2"'),
    webm_file: await decodingInfo('file','video/webm; codecs="vp09.00.10.08"','audio/webm; codecs="opus"'),
    av1_file: await decodingInfo('file','video/webm; codecs="av01.0.04M.08"','audio/webm; codecs="opus"'),
    mp4_mse: await decodingInfo('media-source','video/mp4; codecs="avc1.42E01E"','audio/mp4; codecs="mp4a.40.2"'),
  };
  results.drm = {widevine:await widevineSupport()};
  for (const encoding of ['identity','gzip','br']) {
    try { results['fetch_' + encoding] = await stream('/stream/fetch?encoding=' + encoding); }
    catch (error) { results['fetch_' + encoding] = {error:String(error)}; }
    show();
  }
  for (const protocol of ['h2','h3']) {
    const endpoint = new URLSearchParams(location.search).get(protocol);
    if (!endpoint) continue;
    if (protocol === 'h3') {
      try { results.transport_warmup_h3 = await warmTransport(endpoint); }
      catch (error) { results.transport_warmup_h3 = {error:String(error)}; }
      show();
    }
    try { results['fetch_' + protocol] = await stream(endpoint); }
    catch (error) { results['fetch_' + protocol] = {error:String(error)}; }
    show();
  }
  try { results.sse = await sse(); } catch (error) { results.sse = {error:String(error)}; }
  const manifest = await fetch('/manifest.json', {cache:'no-store'}).then(response=>response.json());
  results.media_manifest = manifest;
  results.playback = [];
  if (manifest.files.mp4) results.playback.push(await play('mp4','/media/' + manifest.files.mp4.name));
  if (manifest.files.mp4_high) results.playback.push(await play('mp4_high','/media/' + manifest.files.mp4_high.name));
  if (manifest.files.webm) results.playback.push(await play('webm','/media/' + manifest.files.webm.name));
  if (manifest.files.av1) results.playback.push(await play('av1','/media/' + manifest.files.av1.name));
  if (manifest.files.mse) results.playback.push(await playMse('/media/' + manifest.files.mse.name));
  if (manifest.files.hls_manifest) results.playback.push(await playHls('/media/' + manifest.files.hls_manifest.name));
  if (manifest.files.dash_manifest) results.playback.push(await playDash('/media/' + manifest.files.dash_manifest.name));
  results.lifecycle.events.push(connectionSnapshot('completed'));
  results.finished_at = new Date().toISOString();
  window.__heliumMediaResult = results;
  show();
})().catch(error => { results.fatal = String(error); results.finished_at = new Date().toISOString(); window.__heliumMediaResult = results; show(); });
</script>`;
}

function flushCompression(stream) {
  return new Promise((resolve, reject) => stream.flush(error => error ? reject(error) : resolve()));
}

function send(response, status, type, body) {
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
    "content-type": type,
  });
  response.end(body);
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function isDirectory(candidate) {
  const stat = await fsp.stat(candidate).catch(() => null);
  return Boolean(stat?.isDirectory());
}

function numberOption(value, fallback, minimum, maximum, name) {
  const number = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return number;
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
  const args = parseArgs(process.argv.slice(2));
  const fixture = await createFixtureServer({
    host: args.host,
    port: args.port,
    chunks: args.chunks,
    delayMs: args["delay-ms"],
    mediaDir: args["media-dir"],
  });
  process.stdout.write(`${JSON.stringify({event:"listening", origin:fixture.origin, pid:process.pid})}\n`);
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, async () => {
      await fixture.close();
      process.exit(0);
    });
  }
}
