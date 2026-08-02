#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import {pathToFileURL} from "node:url";

const HASH = /^[0-9a-f]{64}$/;
const HOSTS = new Set(["d", "da"]);

function fail(message) {
  throw new Error(message);
}

function sha256(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      JSON.stringify(Object.keys(value).sort()) !==
        JSON.stringify([...expected].sort())) {
    fail(`${label} has an unexpected field inventory`);
  }
}

function canonicalIdentity(value) {
  return [
    "helium-linux-host-v1",
    value.host,
    value.hostname,
    value.machine_id_sha256,
    value.kernel_arch,
  ].join("\n") + "\n";
}

export function validateLinuxHostIdentity(value, expectedHost) {
  exactKeys(value, [
    "schema_version", "identity_schema", "host", "hostname",
    "machine_id_sha256", "kernel_arch", "host_identity_sha256",
    "captured_at",
  ], "Linux host identity");
  if (value.schema_version !== 1 ||
      value.identity_schema !== "helium-linux-host-v1" ||
      !HOSTS.has(value.host) || value.host !== expectedHost ||
      value.hostname !== expectedHost || !HASH.test(value.machine_id_sha256) ||
      value.kernel_arch !== "x64" || !HASH.test(value.host_identity_sha256) ||
      value.host_identity_sha256 !== sha256(Buffer.from(canonicalIdentity(value))) ||
      !Number.isFinite(Date.parse(value.captured_at))) {
    fail(`${expectedHost} Linux host identity is invalid`);
  }
  return value;
}

export function captureLinuxHostIdentity(expectedHost) {
  if (!HOSTS.has(expectedHost)) fail("Linux host identity is limited to d and da");
  const hostname = os.hostname().split(".")[0];
  if (hostname !== expectedHost) {
    fail(`host identity capture expected ${expectedHost}, running on ${hostname}`);
  }
  if (os.arch() !== "x64") fail("Linux host identity requires x86_64");
  const machineID = fs.readFileSync("/etc/machine-id", "utf8");
  if (!/^[0-9a-f]{32}\n?$/.test(machineID)) {
    fail("Linux machine-id is unavailable or malformed");
  }
  const value = {
    schema_version: 1,
    identity_schema: "helium-linux-host-v1",
    host: expectedHost,
    hostname,
    machine_id_sha256: sha256(Buffer.from(`${machineID.trim()}\n`)),
    kernel_arch: os.arch(),
    host_identity_sha256: "",
    captured_at: new Date().toISOString(),
  };
  value.host_identity_sha256 = sha256(Buffer.from(canonicalIdentity(value)));
  return validateLinuxHostIdentity(value, expectedHost);
}

export function linuxHostIdentityEnv(value) {
  validateLinuxHostIdentity(value, value.host);
  return `${Object.entries(value).map(([key, item]) => `${key}=${item}`).join("\n")}\n`;
}

export function parseLinuxHostIdentityEnv(raw, expectedHost) {
  const value = {};
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const item = line.slice(separator + 1);
    if (separator < 1 || !item || Object.hasOwn(value, key) ||
        /[\r\n\0]/.test(item)) {
      fail("Linux host identity receipt is malformed");
    }
    value[key] = key === "schema_version" ? Number(item) : item;
  }
  return validateLinuxHostIdentity(value, expectedHost);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, option, host] = process.argv.slice(2);
    if (command !== "capture" || option !== "--expected-host" || !host ||
        process.argv.length !== 5) {
      fail("usage: execution-identity.mjs capture --expected-host d|da");
    }
    process.stdout.write(linuxHostIdentityEnv(captureLinuxHostIdentity(host)));
  } catch (error) {
    process.stderr.write(`execution identity: ${error.message}\n`);
    process.exitCode = 1;
  }
}
