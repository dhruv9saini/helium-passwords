import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createFixtureServer } from "../android-media/fixture-server.mjs";
import {
  atomicWriteJSON,
  createContentFreeChatGPTTiming,
  runProbe,
  validateFixtureBrowserCommandLine,
  validateProbeResult,
} from "../android-media/run-cdp-probe.mjs";

test("private fixture certificate override admits only one exact leaf SPKI", () => {
  const spki = `${"A".repeat(43)}=`;
  assert.equal(validateFixtureBrowserCommandLine([
    "chrome", "--enable-automation", `--ignore-certificate-errors-spki-list=${spki}`,
  ], spki), `--ignore-certificate-errors-spki-list=${spki}`);
  assert.throws(() => validateFixtureBrowserCommandLine([
    "chrome", "--ignore-certificate-errors",
    `--ignore-certificate-errors-spki-list=${spki}`,
  ], spki), /only the admitted/);
  assert.throws(() => validateFixtureBrowserCommandLine([
    "chrome", `--ignore-certificate-errors-spki-list=${"B".repeat(43)}=`,
  ], spki), /only the admitted/);
  assert.throws(() => validateFixtureBrowserCommandLine([], "not-base64"), /fixture SPKI/);
});

test("streams numbered Fetch chunks progressively for identity, gzip, and Brotli", async t => {
  const fixture = await createFixtureServer({ port: 0, chunks: 4, delayMs: 40 });
  t.after(() => fixture.close());

  for (const encoding of ["identity", "gzip", "br"]) {
    const response = await fetch(`${fixture.origin}/stream/fetch?encoding=${encoding}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("access-control-allow-origin"), "*");
    assert.equal(response.headers.get("timing-allow-origin"), "*");
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let body = "";
    let reads = 0;
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      reads += 1;
      body += decoder.decode(item.value, { stream: true });
    }
    body += decoder.decode();
    assert.equal(body, "chunk-01\nchunk-02\nchunk-03\nchunk-04\n");
    assert.ok(reads >= 2, `${encoding} response was buffered into one body read`);
  }
});

test("serves an ordered event stream", async t => {
  const fixture = await createFixtureServer({ port: 0, chunks: 3, delayMs: 20 });
  t.after(() => fixture.close());
  const response = await fetch(`${fixture.origin}/stream/sse`);
  const body = await response.text();
  assert.match(response.headers.get("content-type"), /^text\/event-stream/);
  assert.deepEqual([...body.matchAll(/^data: (chunk-\d+)$/gm)].map(match => match[1]), [
    "chunk-01", "chunk-02", "chunk-03",
  ]);
  assert.match(body, /event: done\ndata: done/);
});

test("serves media only from the fixed fixture names and honors one byte range", async t => {
  const mediaDir = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-media-fixture-"));
  t.after(() => fsp.rm(mediaDir, { recursive: true, force: true }));
  const fixtureNames = [
    "h264-aac.mp4", "h264-high-aac.mp4", "h264-aac-fragmented.mp4",
    "vp9-opus.webm", "av1-opus.webm", "hls/stream.m3u8", "hls/init.mp4",
    "hls/segment-000.m4s", "hls/segment-001.m4s", "dash/stream.mpd",
    "dash/h264-aac-fragmented.mp4",
  ];
  await fsp.mkdir(path.join(mediaDir, "hls"));
  await fsp.mkdir(path.join(mediaDir, "dash"));
  for (const name of fixtureNames) {
    await fsp.writeFile(path.join(mediaDir, name), Buffer.from("0123456789"));
  }
  const fixture = await createFixtureServer({ port: 0, mediaDir });
  t.after(() => fixture.close());

  const response = await fetch(`${fixture.origin}/media/h264-aac.mp4`, {
    headers: { range: "bytes=2-5" },
  });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get("content-range"), "bytes 2-5/10");
  assert.equal(await response.text(), "2345");
  assert.equal((await fetch(`${fixture.origin}/media/../package.json`)).status, 404);

  const manifest = await fetch(`${fixture.origin}/manifest.json`).then(item => item.json());
  assert.equal(manifest.schema_version, 1);
  assert.equal(manifest.files.mp4.bytes, 10);
  assert.equal(manifest.files.mp4.sha256.length, 64);
  assert.deepEqual(Object.values(manifest.files).map(item => item.name).sort(), fixtureNames.sort());
  assert.match(
    (await fetch(`${fixture.origin}/media/hls/stream.m3u8`)).headers.get("content-type"),
    /^application\/vnd\.apple\.mpegurl/,
  );
  assert.match(
    (await fetch(`${fixture.origin}/media/dash/stream.mpd`)).headers.get("content-type"),
    /^application\/dash\+xml/,
  );
  assert.match(
    (await fetch(`${fixture.origin}/media/hls/segment-000.m4s`)).headers.get("content-type"),
    /^video\/iso\.segment/,
  );
});

test("probe page contains the codec and browser-observable streaming gates", async t => {
  const fixture = await createFixtureServer({ port: 0 });
  t.after(() => fixture.close());
  const page = await fetch(`${fixture.origin}/probe`).then(response => response.text());
  assert.match(page, /avc1\.42E01E, mp4a\.40\.2/);
  assert.match(page, /avc1\.640028, mp4a\.40\.2/);
  assert.match(page, /vp09\.00\.10\.08, opus/);
  assert.match(page, /av01\.0\.04M\.08, opus/);
  assert.match(page, /application\/vnd\.apple\.mpegurl/);
  assert.match(page, /MediaSource\.isTypeSupported/);
  assert.match(page, /new DOMParser/);
  assert.match(page, /mediaCapabilities\.decodingInfo/);
  assert.match(page, /requestMediaKeySystemAccess/);
  assert.match(page, /com\.widevine\.alpha/);
  assert.match(page, /getVideoPlaybackQuality/);
  assert.match(page, /audio_decoded_bytes/);
  assert.match(page, /interaction_ticks/);
  assert.match(page, /new EventSource/);
  assert.match(page, /response\.body\.getReader/);
  assert.match(page, /transport_warmup_h3/);
  assert.match(page, /visibilitychange/);
  assert.match(page, /connectionchange/);
  assert.match(page, /__heliumMediaResult/);
  const embeddedScript = page.match(/<script>([\s\S]*)<\/script>/)?.[1];
  assert.ok(embeddedScript);
  assert.doesNotThrow(() => new Function(embeddedScript));
  const runner = await fsp.readFile(new URL("../android-media/run-cdp-probe.mjs", import.meta.url), "utf8");
  assert.match(runner, /Target\.createBrowserContext/);
  assert.match(runner, /Target\.disposeBrowserContext/);
});

test("CDP result validation fails closed on buffered, reordered, or failed playback", () => {
  const stream = {
    text: "chunk-01\nchunk-02\nchunk-03\nchunk-04\n",
    arrivals: [1, 2, 3, 4],
    interaction_ticks: 3,
    chunk_milestones: [
      { count: 1, at_ms: 10 }, { count: 2, at_ms: 20 },
      { count: 3, at_ms: 30 }, { count: 4, at_ms: 40 },
    ],
    headers_ms: 1,
    completed_ms: 45,
  };
  const result = {
    schema_version: 1,
    expected_chunks: 4,
    finished_at: "2026-07-21T00:00:00Z",
    required_transport_protocols: [],
    required_lifecycle: {
      background_foreground: false,
      network_handoff: false,
    },
    fetch_identity: stream,
    fetch_gzip: stream,
    fetch_br: stream,
    sse: {
      values: ["chunk-01", "chunk-02", "chunk-03", "chunk-04"],
      arrivals: [1, 2, 3, 4],
      interaction_ticks: 3,
    },
    capabilities: {
      mp4_h264_aac: "probably",
      mp4_h264_high_aac: "",
      webm_vp9_opus: "probably",
      webm_av1_opus: "",
      hls: "probably",
      mse_mp4_h264_aac: true,
    },
    media_capabilities: {
      mp4_high_file: { supported: false },
      av1_file: { supported: false },
    },
    drm: {
      widevine: {
        api_available: true,
        key_system: "com.widevine.alpha",
        key_system_available: false,
        error: "synthetic expected unavailability",
      },
    },
    runtime: {
      browser_product: "Chrome/148",
      browser_protocol_version: "1.3",
      browser_webkit_version: "537.36 (@synthetic)",
      fixture_origin: "http://127.0.0.1:44721",
    },
    media_manifest: { files: {
      mp4: { name: "h264-aac.mp4", bytes: 10, sha256: "a".repeat(64) },
      mp4_high: { name: "h264-high-aac.mp4", bytes: 10, sha256: "b".repeat(64) },
      webm: { name: "vp9-opus.webm", bytes: 10, sha256: "b".repeat(64) },
      av1: { name: "av1-opus.webm", bytes: 10, sha256: "c".repeat(64) },
      mse: { name: "h264-aac-fragmented.mp4", bytes: 10, sha256: "c".repeat(64) },
      hls_manifest: { name: "hls/stream.m3u8", bytes: 10, sha256: "d".repeat(64) },
      hls_init: { name: "hls/init.mp4", bytes: 10, sha256: "e".repeat(64) },
      hls_segment_0: { name: "hls/segment-000.m4s", bytes: 10, sha256: "f".repeat(64) },
      hls_segment_1: { name: "hls/segment-001.m4s", bytes: 10, sha256: "0".repeat(64) },
      dash_manifest: { name: "dash/stream.mpd", bytes: 10, sha256: "1".repeat(64) },
      dash_media: { name: "dash/h264-aac-fragmented.mp4", bytes: 10, sha256: "2".repeat(64) },
    } },
    playback: [
      { name: "mp4", ok: true, duration: 2, width: 320, height: 180, audio_decoded_bytes: 10, total_frames: 60, dropped_frames: 0 },
      { name: "mp4_high", ok: false, error: "synthetic unsupported" },
      { name: "webm", ok: true, duration: 2, width: 320, height: 180, audio_decoded_bytes: 10, total_frames: 60, dropped_frames: 0 },
      { name: "av1", ok: false, error: "synthetic unsupported" },
      { name: "mse", ok: true, duration: 2, width: 320, height: 180, audio_decoded_bytes: 10, total_frames: 60, dropped_frames: 0 },
      { name: "hls", ok: true, duration: 2, width: 320, height: 180, audio_decoded_bytes: 10, total_frames: 60, dropped_frames: 0 },
      { name: "dash", ok: true, duration: 2, width: 320, height: 180, audio_decoded_bytes: 10, total_frames: 60, dropped_frames: 0 },
    ],
    lifecycle: {
      events: [
        { event: "started", at_ms: 1, visibility: "visible", online: true },
        { event: "completed", at_ms: 1000, visibility: "visible", online: true },
      ],
    },
  };
  assert.equal(validateProbeResult(result), result);
  assert.throws(() => validateProbeResult({
    ...result,
    fetch_gzip: { ...stream, arrivals: [1] },
  }), /did not arrive progressively/);
  assert.throws(() => validateProbeResult({
    ...result,
    drm: {},
  }), /Widevine EME availability was not recorded/);
  assert.throws(() => validateProbeResult({
    ...result,
    playback: [{ name: "mp4", ok: false }],
  }), /did not play/);
  assert.throws(() => validateProbeResult({
    ...result,
    media_manifest: { files: { ...result.media_manifest.files, webm: undefined } },
  }), /webm media fixture was absent/);
  assert.throws(() => validateProbeResult({
    ...result,
    fetch_br: { ...stream, chunk_milestones: [{ count: 4, at_ms: 40 }] },
  }), /three progressive chunk milestones/);
  assert.throws(() => validateProbeResult({
    ...result,
    fetch_br: {
      ...stream,
      chunk_milestones: [
        { count: 1, at_ms: 10 }, { count: 2, at_ms: 50 },
        { count: 3, at_ms: 30 }, { count: 4, at_ms: 40 },
      ],
    },
  }), /milestone timing evidence was invalid/);
  assert.equal(validateProbeResult({
    ...result,
    required_lifecycle: { background_foreground: true, network_handoff: true },
    lifecycle: { events: [
      ...result.lifecycle.events.slice(0, 1),
      { event: "visibilitychange", at_ms: 100, visibility: "hidden", online: true },
      { event: "connectionchange", at_ms: 200, visibility: "hidden", online: true },
      { event: "visibilitychange", at_ms: 300, visibility: "visible", online: true },
      ...result.lifecycle.events.slice(1),
    ] },
  }).required_lifecycle.network_handoff, true);
  assert.throws(() => validateProbeResult({
    ...result,
    required_lifecycle: { background_foreground: true, network_handoff: false },
  }), /background\/foreground lifecycle was not observed/);
  assert.throws(() => validateProbeResult({
    ...result,
    required_lifecycle: { background_foreground: false, network_handoff: true },
  }), /network handoff was not observed/);
  assert.equal(validateProbeResult({
    ...result,
    required_transport_protocols: ["h2"],
    fetch_h2: { ...stream, protocol: "h2" },
  }).fetch_h2.protocol, "h2");
  assert.throws(() => validateProbeResult({
    ...result,
    required_transport_protocols: ["h3"],
    fetch_h3: { ...stream, protocol: "h2" },
  }), /expected h3/);
  assert.equal(validateProbeResult({
    ...result,
    required_transport_protocols: ["h3"],
    transport_warmup_h3: { status: 200, completed_ms: 100, protocol: "h2" },
    fetch_h3: { ...stream, protocol: "h3" },
  }).fetch_h3.protocol, "h3");
  assert.throws(() => validateProbeResult({
    ...result,
    required_transport_protocols: ["h3"],
    fetch_h3: { ...stream, protocol: "h3" },
  }), /Alt-Svc warmup evidence was absent/);
});

test("CDP runner refuses non-loopback origins and existing evidence", async t => {
  const outputDir = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-media-evidence-"));
  t.after(() => fsp.rm(outputDir, { recursive: true, force: true }));
  const output = path.join(outputDir, "result.json");
  await atomicWriteJSON(output, { schema_version: 1 });
  await assert.rejects(() => atomicWriteJSON(output, { schema_version: 2 }), /refusing to overwrite/);
  const racedOutput = path.join(outputDir, "raced.json");
  const raced = await Promise.allSettled([
    atomicWriteJSON(racedOutput, { writer: 1 }),
    atomicWriteJSON(racedOutput, { writer: 2 }),
  ]);
  assert.equal(raced.filter(item => item.status === "fulfilled").length, 1);
  assert.equal(raced.filter(item => item.status === "rejected").length, 1);
  await assert.rejects(() => runProbe({
    cdp: "http://example.com:9222",
    fixture: "http://127.0.0.1:44721/probe",
    output: path.join(outputDir, "bad.json"),
  }), /CDP URL must use loopback HTTP/);
  await assert.rejects(() => runProbe({
    cdp: "http://127.0.0.1:9222",
    fixture: "http://127.0.0.1:44721/probe",
    h2: "https://example.com/private?token=secret",
    output: path.join(outputDir, "bad-h2.json"),
  }), /fixed identity Fetch endpoint/);
});

test("ChatGPT timing evidence is artifact-bound and cannot contain content", () => {
  const options = {
    status: "completed",
    startedAt: "2026-07-22T18:00:00.000Z",
    firstUpdateMs: "850",
    observationMs: "4200",
    visibleUpdateCount: "4",
    package: "computer.helium.sync.test",
    artifactSha256: "a".repeat(64),
    heliumSyncCommit: "b".repeat(40),
    chromiumCommit: "c".repeat(40),
  };
  const timing = createContentFreeChatGPTTiming(options);
  assert.deepEqual(Object.keys(timing).sort(), [
    "artifact_sha256", "chromium_commit", "first_update_ms", "helium_sync_commit",
    "observation_ms", "package", "scenario", "schema_version", "started_at", "status",
    "visible_update_count_lower_bound",
  ]);
  assert.throws(() => createContentFreeChatGPTTiming({
    status: "completed",
    startedAt: "2026-07-22T18:00:00.000Z",
    firstUpdateMs: 850,
    observationMs: 4200,
    visibleUpdateCount: 4,
    package: "computer.helium.sync.test",
    artifactSha256: "a".repeat(64),
    heliumSyncCommit: "b".repeat(40),
    chromiumCommit: "c".repeat(40),
    content: "must never be accepted",
  }), /rejects unexpected fields: content/);
  assert.throws(() => createContentFreeChatGPTTiming({
    ...options,
    visibleUpdateCount: 2,
  }), /at least three visible updates/);
});
