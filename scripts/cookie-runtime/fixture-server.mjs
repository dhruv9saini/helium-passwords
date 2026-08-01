#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const RUN_NONCE = /^[0-9a-f]{64}$/;
const COOKIE_NAME = "helium_sync_desktop_fixture";

function fail(message) {
  throw new Error(message);
}

function parseOptions(argv) {
  const options = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined || options.has(key)) {
      fail("invalid fixture arguments");
    }
    options.set(key, value);
  }
  const allowed = new Set(["--port", "--run-nonce", "--evidence"]);
  for (const key of options.keys()) {
    if (!allowed.has(key)) fail("unknown fixture argument");
  }
  const port = Number(options.get("--port"));
  const runNonce = options.get("--run-nonce");
  const evidence = options.get("--evidence");
  if (!Number.isSafeInteger(port) || port < 0 || port > 65535) {
    fail("port must be an integer from 0 through 65535");
  }
  if (!RUN_NONCE.test(runNonce || "")) {
    fail("run nonce must be exactly 64 lowercase hexadecimal characters");
  }
  if (!evidence || !path.isAbsolute(evidence)) {
    fail("evidence must be an absolute path");
  }
  return {port, runNonce, evidence};
}

function digest(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function equalDigest(left, right) {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function targetCookie(header) {
  if (header === undefined) return undefined;
  if (Array.isArray(header)) fail("multiple Cookie headers are not accepted");
  const matches = [];
  for (const item of header.split(";")) {
    const separator = item.indexOf("=");
    if (separator < 1) continue;
    const name = item.slice(0, separator).trim();
    if (name === COOKIE_NAME) matches.push(item.slice(separator + 1).trim());
  }
  if (matches.length > 1) fail("duplicate fixture cookie");
  return matches[0];
}

function page(title, detail, passed) {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="referrer" content="no-referrer">
<title>${title}</title>
<style>
  :root { color-scheme: light dark; font: 20px system-ui, sans-serif; }
  main { max-width: 48rem; margin: 6rem auto; padding: 2rem; }
  h1 { color: ${passed ? "#16803c" : "#a02828"}; }
  code { font-size: 0.9em; }
</style>
<main><h1>${title}</h1><p>${detail}</p>
<p>Disposable native CookieManager desktop acceptance.</p></main>`;
}

function send(response, status, title, detail, passed = status === 200,
              cookie) {
  const body = page(title, detail, passed);
  const headers = {
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'",
    "content-type": "text/html; charset=utf-8",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
  };
  if (cookie) headers["set-cookie"] = cookie;
  response.writeHead(status, headers);
  response.end(body);
}

async function writeEvidence(file, value) {
  await fsp.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
  const handle = await fsp.open(file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`);
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function main() {
  const {port, runNonce, evidence} = parseOptions(process.argv.slice(2));
  await fsp.lstat(evidence).then(
    () => fail("refusing to replace existing evidence"),
    error => { if (error.code !== "ENOENT") throw error; },
  );

  const initial = crypto.randomBytes(32).toString("base64url");
  const updated = crypto.randomBytes(32).toString("base64url");
  const initialDigest = digest(initial);
  const updatedDigest = digest(updated);
  let stage = "initial-empty";
  let origin = "";
  const observations = {
    d_initial_empty_before_set: false,
    da_received_initial_http_only_cookie: false,
    da_updated_received_cookie: false,
    d_received_updated_http_only_cookie: false,
    d_deleted_received_cookie: false,
    da_received_deletion: false,
  };

  const server = http.createServer((request, response) => {
    void (async () => {
      if (request.method !== "GET") {
        send(response, 405, "Method rejected", "Only controlled GET steps are accepted.", false);
        return;
      }
      const url = new URL(request.url || "/", "http://fixture.invalid");
      const cookie = targetCookie(request.headers.cookie);
      const cookieDigest = cookie === undefined ? undefined : digest(cookie);

      if (url.pathname === "/healthz") {
        send(response, 200, "Fixture healthy", "No lifecycle state was changed.");
        return;
      }
      if (url.pathname === "/d/set-initial" && stage === "initial-empty" &&
          cookie === undefined) {
        observations.d_initial_empty_before_set = true;
        stage = "initial-set";
        send(response, 200, "Initial cookie stored on d",
          "The controlled HttpOnly cookie was created in the d disposable profile.",
          true, `${COOKIE_NAME}=${initial}; Path=/; HttpOnly; SameSite=Lax`);
        return;
      }
      if (url.pathname === "/da/observe-initial" && stage === "initial-set" &&
          cookieDigest && equalDigest(cookieDigest, initialDigest)) {
        observations.da_received_initial_http_only_cookie = true;
        stage = "initial-observed";
        send(response, 200, "Initial cookie converged to da",
          "da sent the exact cookie created by d through the native browser store.");
        return;
      }
      if (url.pathname === "/da/set-updated" && stage === "initial-observed" &&
          cookieDigest && equalDigest(cookieDigest, initialDigest)) {
        observations.da_updated_received_cookie = true;
        stage = "updated-set";
        send(response, 200, "Cookie updated on da",
          "The da disposable browser replaced the received cookie.", true,
          `${COOKIE_NAME}=${updated}; Path=/; HttpOnly; SameSite=Lax`);
        return;
      }
      if (url.pathname === "/d/observe-updated" && stage === "updated-set" &&
          cookieDigest && equalDigest(cookieDigest, updatedDigest)) {
        observations.d_received_updated_http_only_cookie = true;
        stage = "updated-observed";
        send(response, 200, "Updated cookie converged to d",
          "d sent the exact replacement created by da through the native browser store.");
        return;
      }
      if (url.pathname === "/d/delete" && stage === "updated-observed" &&
          cookieDigest && equalDigest(cookieDigest, updatedDigest)) {
        observations.d_deleted_received_cookie = true;
        stage = "deleted";
        send(response, 200, "Cookie deleted on d",
          "The controlled cookie was deleted from the d disposable browser.", true,
          `${COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`);
        return;
      }
      if (url.pathname === "/da/observe-deleted" && stage === "deleted" &&
          cookie === undefined) {
        observations.da_received_deletion = true;
        stage = "complete";
        await writeEvidence(evidence, {
          schema_version: 1,
          evidence_type: "helium-desktop-native-cookie-e2e-v1",
          run_nonce: runNonce,
          completed_at: new Date().toISOString(),
          fixture_origin: origin,
          cookie_contract: {
            name: COOKIE_NAME,
            path: "/",
            http_only: true,
            same_site: "Lax",
            secure: false,
            host_only: true,
          },
          value_fingerprints: {
            initial_sha256: initialDigest,
            updated_sha256: updatedDigest,
          },
          evidence_contains_cookie_values: false,
          observations,
        });
        send(response, 200, "Cookie tombstone converged to da",
          "The controlled cookie is absent after the native deletion round trip.");
        return;
      }

      send(response, 409, "Cookie lifecycle step rejected",
        "The browser cookie or ordered client step did not match the acceptance contract.",
        false);
    })().catch(error => {
      process.stderr.write(`cookie fixture: ${error.message}\n`);
      if (!response.headersSent) {
        send(response, 500, "Fixture failure",
          "The controlled acceptance fixture rejected this request.", false);
      } else {
        response.destroy();
      }
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  const address = server.address();
  origin = `http://127.0.0.1:${address.port}`;
  process.stdout.write(`${origin}\n`);

  const stop = () => server.close(() => process.exit(0));
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
}

main().catch(error => {
  process.stderr.write(`cookie fixture: ${error.message}\n`);
  process.exitCode = 1;
});
