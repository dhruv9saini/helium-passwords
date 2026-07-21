#!/usr/bin/env node

import http from "node:http";
import {pathToFileURL} from "node:url";

const LOOPBACK = "127.0.0.1";

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
</html>
`;

const loginPage = page("Password lifecycle login", `
<form method="post" action="/session">
  <label>Username <input name="username" autocomplete="username" required></label>
  <label>Password <input name="password" type="password" autocomplete="current-password" required></label>
  <button type="submit">Sign in</button>
</form>`);

const accountPage = page("Fixture account", `
<p>The synthetic login completed.</p>
<a href="/change-password">Change password</a>`);

const changePasswordPage = page("Change fixture password", `
<form method="post" action="/password">
  <label>Username <input name="username" autocomplete="username" required></label>
  <label>Current password <input name="current_password" type="password" autocomplete="current-password" required></label>
  <label>New password <input name="new_password" type="password" autocomplete="new-password" required></label>
  <label>Confirm new password <input name="confirm_password" type="password" autocomplete="new-password" required></label>
  <button type="submit">Update password</button>
</form>`);

const updatedPage = page("Fixture password updated", `
<p>The synthetic password update completed.</p>
<a href="/login">Return to login</a>`);

function send(response, status, contentType, body, headers = {}) {
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": contentType,
    "x-content-type-options": "nosniff",
    ...headers,
  });
  response.end(body);
}

function redirectAfterDiscardingBody(request, response, location, headers = {}) {
  request.on("error", () => response.destroy());
  request.on("end", () => send(response, 303, "text/plain; charset=utf-8", "", {
    location,
    ...headers,
  }));
  request.resume();
}

function handleRequest(request, response) {
  const url = new URL(request.url, "http://fixture.invalid");
  if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/login")) {
    send(response, 200, "text/html; charset=utf-8", loginPage);
    return;
  }
  if (request.method === "POST" && url.pathname === "/session") {
    redirectAfterDiscardingBody(request, response, "/account", {
      "set-cookie": "fixture_session=1; HttpOnly; SameSite=Lax; Path=/",
    });
    return;
  }
  if (request.method === "GET" && url.pathname === "/account") {
    send(response, 200, "text/html; charset=utf-8", accountPage);
    return;
  }
  if (request.method === "GET" && url.pathname === "/change-password") {
    send(response, 200, "text/html; charset=utf-8", changePasswordPage);
    return;
  }
  if (request.method === "POST" && url.pathname === "/password") {
    redirectAfterDiscardingBody(request, response, "/updated");
    return;
  }
  if (request.method === "GET" && url.pathname === "/updated") {
    send(response, 200, "text/html; charset=utf-8", updatedPage);
    return;
  }
  if (request.method === "GET" && url.pathname === "/healthz") {
    send(response, 200, "text/plain; charset=utf-8", "ok\n");
    return;
  }
  send(response, 404, "text/plain; charset=utf-8", "not found\n");
}

export async function startPasswordLifecycleFixture({port = 0} = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new TypeError("port must be an integer from 0 through 65535");
  }

  const server = http.createServer(handleRequest);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, LOOPBACK, resolve);
  });
  server.removeAllListeners("error");

  const address = server.address();
  const origin = `http://${LOOPBACK}:${address.port}`;
  return {
    origin,
    close: () => new Promise((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
    }),
  };
}

function parsePort(args) {
  if (args.length === 0) return 0;
  if (args.length === 1 && args[0] === "--help") return null;
  if (args.length !== 2 || args[0] !== "--port") {
    throw new Error("usage: password-lifecycle-fixture.mjs [--port PORT]");
  }
  const port = Number(args[1]);
  if (!Number.isInteger(port)) throw new Error("PORT must be an integer");
  return port;
}

async function main() {
  const port = parsePort(process.argv.slice(2));
  if (port === null) {
    process.stdout.write("usage: password-lifecycle-fixture.mjs [--port PORT]\n");
    return;
  }

  const fixture = await startPasswordLifecycleFixture({port});
  process.stdout.write(`${fixture.origin}\n`);
  const stop = async () => {
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    await fixture.close();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
