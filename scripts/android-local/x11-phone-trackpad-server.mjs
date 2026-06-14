#!/usr/bin/env node
import http from "node:http";
import { spawn } from "node:child_process";

const host = process.env.X11_PHONE_TRACKPAD_HOST || "127.0.0.1";
const port = Number(process.env.X11_PHONE_TRACKPAD_PORT || 8765);
const helperPath = `${process.env.HOME}/.local/bin/x11-pointer-helper`;
const display = process.env.DISPLAY || ":1";
const defaultSensitivity = Number(process.env.X11_PHONE_TRACKPAD_SENSITIVITY || 2.35);
const defaultScrollSensitivity = Number(process.env.X11_PHONE_TRACKPAD_SCROLL_SENSITIVITY || 0.08);
const authToken = process.env.X11_PHONE_TRACKPAD_TOKEN || "";

let helper = spawn(helperPath, {
  env: { ...process.env, DISPLAY: display },
  stdio: ["pipe", "ignore", "inherit"],
});

helper.on("exit", (code, signal) => {
  console.error(`x11-pointer-helper exited: code=${code} signal=${signal}`);
  process.exit(code ?? 1);
});

function writeCommand(line) {
  if (!helper.stdin.destroyed) {
    helper.stdin.write(`${line}\n`);
  }
}

function clampInt(value, min, max) {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(min, Math.min(max, Math.trunc(value)));
}

function handleCommand(command) {
  switch (command.type) {
    case "move": {
      const dx = clampInt(command.dx, -300, 300);
      const dy = clampInt(command.dy, -300, 300);
      if (dx !== 0 || dy !== 0) {
        writeCommand(`move ${dx} ${dy}`);
      }
      break;
    }
    case "scroll": {
      const sx = clampInt(command.sx, -48, 48);
      const sy = clampInt(command.sy, -48, 48);
      if (sx !== 0 || sy !== 0) {
        writeCommand(`scroll ${sx} ${sy}`);
      }
      break;
    }
    case "click": {
      const button = clampInt(command.button, 1, 3);
      writeCommand(`click ${button}`);
      break;
    }
    case "button": {
      const button = clampInt(command.button, 1, 3);
      const action = command.down ? "down" : "up";
      writeCommand(`button ${button} ${action}`);
      break;
    }
    default:
      break;
  }
}

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, viewport-fit=cover">
<title>X11 Trackpad</title>
<style>
html, body {
  margin: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: #050505;
  color: #d8d8d8;
  font: 14px system-ui, sans-serif;
  touch-action: none;
  -webkit-user-select: none;
  user-select: none;
}
#pad {
  position: fixed;
  inset: 0;
  background:
    radial-gradient(circle at 50% 36%, rgba(255,255,255,0.075), transparent 26%),
    #050505;
}
#status {
  position: fixed;
  left: 14px;
  bottom: max(14px, env(safe-area-inset-bottom));
  opacity: 0.45;
  letter-spacing: 0;
}
</style>
</head>
<body>
<main id="pad" aria-label="X11 trackpad"></main>
<div id="status">X11 trackpad</div>
<script>
const sensitivity = Number(new URLSearchParams(location.search).get("sensitivity") || "${defaultSensitivity}");
const scrollSensitivity = Number(new URLSearchParams(location.search).get("scroll") || "${defaultScrollSensitivity}");
const tapDistance = 16;
const tapMs = 280;
const state = {
  active: new Map(),
  lastCenter: null,
  startCenter: null,
  startedAt: 0,
  maxTouches: 0,
  moved: 0,
  moveX: 0,
  moveY: 0,
  scrollX: 0,
  scrollY: 0,
  raf: 0,
};

function post(command) {
  fetch("/cmd", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(command),
    keepalive: true,
  }).catch(() => {});
}

function center(points) {
  let x = 0;
  let y = 0;
  for (const point of points) {
    x += point.x;
    y += point.y;
  }
  return { x: x / points.length, y: y / points.length };
}

function distance(a, b) {
  if (!a || !b) {
    return 0;
  }
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function flush() {
  state.raf = 0;
  const dx = Math.round(state.moveX);
  const dy = Math.round(state.moveY);
  state.moveX -= dx;
  state.moveY -= dy;
  if (dx || dy) {
    post({ type: "move", dx, dy });
  }

  const sx = Math.trunc(state.scrollX);
  const sy = Math.trunc(state.scrollY);
  state.scrollX -= sx;
  state.scrollY -= sy;
  if (sx || sy) {
    post({ type: "scroll", sx, sy });
  }

  if (Math.abs(state.moveX) >= 0.5 || Math.abs(state.moveY) >= 0.5 ||
      Math.abs(state.scrollX) >= 1 || Math.abs(state.scrollY) >= 1) {
    scheduleFlush();
  }
}

function scheduleFlush() {
  if (!state.raf) {
    state.raf = requestAnimationFrame(flush);
  }
}

function resetGesture(now) {
  const points = [...state.active.values()];
  state.lastCenter = points.length ? center(points) : null;
  state.startCenter = state.lastCenter;
  state.startedAt = now;
  state.maxTouches = points.length;
  state.moved = 0;
}

function updateTouches(touchList) {
  for (const touch of touchList) {
    state.active.set(touch.identifier, { x: touch.clientX, y: touch.clientY });
  }
}

function removeTouches(touchList) {
  for (const touch of touchList) {
    state.active.delete(touch.identifier);
  }
}

function onStart(event) {
  event.preventDefault();
  updateTouches(event.changedTouches);
  resetGesture(performance.now());
}

function onMove(event) {
  event.preventDefault();
  updateTouches(event.changedTouches);
  const points = [...state.active.values()];
  if (!points.length) {
    return;
  }

  const nowCenter = center(points);
  const lastCenter = state.lastCenter || nowCenter;
  const dx = nowCenter.x - lastCenter.x;
  const dy = nowCenter.y - lastCenter.y;
  state.lastCenter = nowCenter;
  state.maxTouches = Math.max(state.maxTouches, points.length);
  state.moved = Math.max(state.moved, distance(nowCenter, state.startCenter));

  if (points.length === 1) {
    state.moveX += dx * sensitivity;
    state.moveY += dy * sensitivity;
  } else if (points.length === 2) {
    state.scrollX -= dx * scrollSensitivity;
    state.scrollY -= dy * scrollSensitivity;
  }
  scheduleFlush();
}

function onEnd(event) {
  event.preventDefault();
  const now = performance.now();
  removeTouches(event.changedTouches);
  const endedGesture = state.active.size === 0;

  if (endedGesture) {
    const wasTap = state.moved <= tapDistance && now - state.startedAt <= tapMs;
    if (wasTap) {
      const button = state.maxTouches === 2 ? 3 : state.maxTouches >= 3 ? 2 : 1;
      post({ type: "click", button });
    }
    resetGesture(now);
    return;
  }

  state.lastCenter = center([...state.active.values()]);
}

document.addEventListener("touchstart", onStart, { passive: false });
document.addEventListener("touchmove", onMove, { passive: false });
document.addEventListener("touchend", onEnd, { passive: false });
document.addEventListener("touchcancel", onEnd, { passive: false });
</script>
</body>
</html>`;

const server = http.createServer((request, response) => {
  if (request.method === "GET" && request.url.startsWith("/")) {
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
    response.end(html);
    return;
  }

  if (request.method === "POST" && request.url === "/cmd") {
    if (authToken && request.headers["x-arch-desktop-token"] !== authToken) {
      response.writeHead(403);
      response.end();
      return;
    }
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 2048) {
        request.destroy();
      }
    });
    request.on("end", () => {
      try {
        handleCommand(JSON.parse(body));
        response.writeHead(204);
        response.end();
      } catch {
        response.writeHead(400);
        response.end();
      }
    });
    return;
  }

  response.writeHead(404);
  response.end();
});

server.listen(port, host, () => {
  console.log(`x11-phone-trackpad listening on http://${host}:${port}`);
});
