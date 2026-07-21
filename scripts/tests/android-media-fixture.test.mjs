import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createFixtureServer } from "../android-media/fixture-server.mjs";
import { validateProbeResult } from "../android-media/run-cdp-probe.mjs";

test("streams numbered Fetch chunks progressively for identity, gzip, and Brotli", async t => {
  const fixture = await createFixtureServer({ port: 0, chunks: 4, delayMs: 40 });
  t.after(() => fixture.close());

  for (const encoding of ["identity", "gzip", "br"]) {
    const response = await fetch(`${fixture.origin}/stream/fetch?encoding=${encoding}`);
    assert.equal(response.status, 200);
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
  await fsp.writeFile(path.join(mediaDir, "h264-aac.mp4"), Buffer.from("0123456789"));
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
});

test("probe page contains the codec and browser-observable streaming gates", async t => {
  const fixture = await createFixtureServer({ port: 0 });
  t.after(() => fixture.close());
  const page = await fetch(`${fixture.origin}/probe`).then(response => response.text());
  assert.match(page, /avc1\.42E01E, mp4a\.40\.2/);
  assert.match(page, /vp09\.00\.10\.08, opus/);
  assert.match(page, /MediaSource\.isTypeSupported/);
  assert.match(page, /mediaCapabilities\.decodingInfo/);
  assert.match(page, /getVideoPlaybackQuality/);
  assert.match(page, /audio_decoded_bytes/);
  assert.match(page, /interaction_ticks/);
  assert.match(page, /new EventSource/);
  assert.match(page, /response\.body\.getReader/);
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
  };
  const result = {
    schema_version: 1,
    expected_chunks: 4,
    finished_at: "2026-07-21T00:00:00Z",
    fetch_identity: stream,
    fetch_gzip: stream,
    fetch_br: stream,
    sse: {
      values: ["chunk-01", "chunk-02", "chunk-03", "chunk-04"],
      arrivals: [1, 2, 3, 4],
      interaction_ticks: 3,
    },
    media_manifest: { files: { mp4: { sha256: "a".repeat(64) } } },
    playback: [{ name: "mp4", ok: true }],
  };
  assert.equal(validateProbeResult(result), result);
  assert.throws(() => validateProbeResult({
    ...result,
    fetch_gzip: { ...stream, arrivals: [1] },
  }), /did not arrive progressively/);
  assert.throws(() => validateProbeResult({
    ...result,
    playback: [{ name: "mp4", ok: false }],
  }), /did not play/);
});
