#!/usr/bin/env node

import crypto from "node:crypto";
import fsp from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import {pathToFileURL} from "node:url";

const LOOPBACK = "127.0.0.1";
const MAX_BODY_BYTES = 8192;

const page = (title, body) => `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>
</head>
<body>
  <main>
    <h1>${title}</h1>
    ${body}
  </main>
</body>
</html>`;

const loginPage = page("Helium synthetic password acceptance", `
<form method="post" action="/session">
  <label>Username <input id="username" name="username" autocomplete="username" required></label>
  <label>Password <input id="password" name="password" type="password" autocomplete="current-password" required></label>
  <button type="submit">Sign in</button>
</form>
<button id="confirm-empty" type="button">Confirm empty after native deletion</button>
<output id="empty-result"></output>
<script>
document.querySelector('#confirm-empty').addEventListener('click', async () => {
  const username = document.querySelector('#username');
  const password = document.querySelector('#password');
  const response = await fetch('/deleted-empty', {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({username_empty: username.value === '', password_empty: password.value === ''}),
  });
  document.querySelector('#empty-result').textContent = response.ok ? 'empty recorded' : 'empty check rejected';
});
</script>`);

const accountPage = page("Synthetic fixture account", `
<p>The synthetic login completed.</p>
<a href="/change-password">Change password</a>`);

const changePasswordPage = page("Change synthetic fixture password", `
<form method="post" action="/password">
  <label>Username <input name="username" autocomplete="username" required></label>
  <label>Current password <input name="current_password" type="password" autocomplete="current-password" required></label>
  <label>New password <input name="new_password" type="password" autocomplete="new-password" minlength="12" required></label>
  <label>Confirm new password <input name="confirm_password" type="password" autocomplete="new-password" minlength="12" required></label>
  <button type="submit">Update password</button>
</form>`);

const updatedPage = page("Synthetic fixture password updated", `
<p>The synthetic password update completed.</p>
<a href="/login">Return to login</a>`);

function digest(value) {
  return crypto.createHash("sha256").update(value, "utf8").digest();
}

function equalDigest(left, right) {
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function send(response, status, contentType, body, headers = {}) {
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": contentType,
    "x-content-type-options": "nosniff",
    ...headers,
  });
  response.end(body);
}

function redirect(response, location) {
  send(response, 303, "text/plain; charset=utf-8", "", {location});
}

async function readBody(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > MAX_BODY_BYTES) throw new Error("request body is too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function writeJSONExclusive(filePath, value) {
  const resolved = path.resolve(filePath);
  await fsp.mkdir(path.dirname(resolved), {recursive: true, mode: 0o700});
  const temporary = `${resolved}.tmp-${process.pid}-${crypto.randomUUID()}`;
  try {
    await fsp.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {mode: 0o600, flag: "wx"});
    await fsp.link(temporary, resolved);
    await fsp.unlink(temporary);
  } catch (error) {
    await fsp.rm(temporary, {force: true});
    throw error;
  }
}

export async function startNativePasswordFixture({port = 0, evidencePath} = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new TypeError("port must be an integer from 0 through 65535");
  }
  if (!evidencePath || !path.isAbsolute(evidencePath)) {
    throw new Error("evidencePath must be an absolute, nonexistent file");
  }
  await fsp.lstat(evidencePath).then(
    () => { throw new Error(`refusing existing fixture evidence: ${evidencePath}`); },
    error => { if (error.code !== "ENOENT") throw error; },
  );

  let stage = "save";
  let usernameDigest;
  let passwordDigest;
  const observations = {
    initial_login_accepted: false,
    saved_restart_matches: false,
    update_current_matches: false,
    update_changes_password: false,
    generated_candidate_minimum_length: false,
    updated_restart_matches: false,
    deleted_restart_empty: false,
  };
  let origin = "";

  const handler = async (request, response) => {
    const url = new URL(request.url || "/", "http://fixture.invalid");
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/login")) {
      send(response, 200, "text/html; charset=utf-8", loginPage);
      return;
    }
    if (request.method === "POST" && url.pathname === "/session") {
      const form = new URLSearchParams(await readBody(request));
      const username = form.get("username") || "";
      const password = form.get("password") || "";
      if (!username || !password) {
        send(response, 422, "text/plain; charset=utf-8", "synthetic credentials are required\n");
        return;
      }
      const submittedUsername = digest(username);
      const submittedPassword = digest(password);
      if (stage === "save") {
        usernameDigest = submittedUsername;
        passwordDigest = submittedPassword;
        observations.initial_login_accepted = true;
        stage = "saved_restart";
      } else if (stage === "saved_restart" &&
                 equalDigest(usernameDigest, submittedUsername) &&
                 equalDigest(passwordDigest, submittedPassword)) {
        observations.saved_restart_matches = true;
        stage = "update";
      } else if (stage === "updated_restart" &&
                 equalDigest(usernameDigest, submittedUsername) &&
                 equalDigest(passwordDigest, submittedPassword)) {
        observations.updated_restart_matches = true;
        stage = "deleted_restart";
      } else {
        send(response, 409, "text/plain; charset=utf-8", "credential did not match the expected native lifecycle stage\n");
        return;
      }
      redirect(response, "/account");
      return;
    }
    if (request.method === "GET" && url.pathname === "/account") {
      send(response, 200, "text/html; charset=utf-8", accountPage);
      return;
    }
    if (request.method === "GET" && url.pathname === "/change-password") {
      if (stage !== "update") {
        send(response, 409, "text/plain; charset=utf-8", "password update is out of order\n");
        return;
      }
      send(response, 200, "text/html; charset=utf-8", changePasswordPage);
      return;
    }
    if (request.method === "POST" && url.pathname === "/password") {
      if (stage !== "update") {
        send(response, 409, "text/plain; charset=utf-8", "password update is out of order\n");
        return;
      }
      const form = new URLSearchParams(await readBody(request));
      const username = form.get("username") || "";
      const current = form.get("current_password") || "";
      const replacement = form.get("new_password") || "";
      const confirmation = form.get("confirm_password") || "";
      const usernameMatches = equalDigest(usernameDigest, digest(username));
      const currentMatches = equalDigest(passwordDigest, digest(current));
      const changesPassword = replacement !== current;
      const validCandidate = replacement.length >= 12 && replacement === confirmation;
      if (!usernameMatches || !currentMatches || !changesPassword || !validCandidate) {
        send(response, 422, "text/plain; charset=utf-8", "synthetic password update did not match the lifecycle contract\n");
        return;
      }
      observations.update_current_matches = true;
      observations.update_changes_password = true;
      observations.generated_candidate_minimum_length = true;
      passwordDigest = digest(replacement);
      stage = "updated_restart";
      redirect(response, "/updated");
      return;
    }
    if (request.method === "GET" && url.pathname === "/updated") {
      send(response, 200, "text/html; charset=utf-8", updatedPage);
      return;
    }
    if (request.method === "POST" && url.pathname === "/deleted-empty") {
      if (stage !== "deleted_restart" || request.headers["content-type"] !== "application/json") {
        send(response, 409, "text/plain; charset=utf-8", "native deletion check is out of order\n");
        return;
      }
      const body = JSON.parse(await readBody(request));
      if (body?.username_empty !== true || body?.password_empty !== true || Object.keys(body).length !== 2) {
        send(response, 422, "text/plain; charset=utf-8", "login fields are not empty\n");
        return;
      }
      observations.deleted_restart_empty = true;
      stage = "complete";
      await writeJSONExclusive(evidencePath, {
        schema_version: 1,
        completed_at: new Date().toISOString(),
        fixture_origin: origin,
        observations,
        evidence_contains_submitted_values: false,
      });
      send(response, 204, "text/plain; charset=utf-8", "");
      return;
    }
    if (request.method === "GET" && url.pathname === "/healthz") {
      send(response, 200, "application/json", `${JSON.stringify({ok: true, stage})}\n`);
      return;
    }
    send(response, 404, "text/plain; charset=utf-8", "not found\n");
  };

  const server = http.createServer((request, response) => {
    handler(request, response).catch(error => {
      send(response, 400, "text/plain; charset=utf-8", `fixture request rejected: ${error.message}\n`);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, LOOPBACK, resolve);
  });
  server.removeAllListeners("error");
  const address = server.address();
  origin = `http://${LOOPBACK}:${address.port}`;
  return {
    origin,
    close: () => new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    }),
  };
}

function parseArgs(argv) {
  const result = {port: 0};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) throw new Error(`invalid argument: ${key}`);
    result[key.slice(2)] = argv[++index];
  }
  result.port = Number(result.port);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = parseArgs(process.argv.slice(2));
    const fixture = await startNativePasswordFixture({port: args.port, evidencePath: args.evidence});
    process.stdout.write(`${JSON.stringify({event: "listening", origin: fixture.origin, pid: process.pid})}\n`);
    const stop = async () => {
      process.removeListener("SIGINT", stop);
      process.removeListener("SIGTERM", stop);
      await fixture.close();
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  } catch (error) {
    process.stderr.write(`Native password fixture failed: ${error.message}\n`);
    process.exit(1);
  }
}
