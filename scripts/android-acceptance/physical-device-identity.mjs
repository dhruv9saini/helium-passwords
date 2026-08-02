#!/usr/bin/env node

import crypto from "node:crypto";
import {spawnSync} from "node:child_process";
import {pathToFileURL} from "node:url";

const SERIAL = /^[A-Za-z0-9._-]+$/;
const HASH = /^[0-9a-f]{64}$/;
const TOKEN = /^[A-Za-z0-9._-]+$/;
const ONEPLUS_MODEL = "CPH2655";
const ONEPLUS_DEVICE = "dodge";

function fail(message) {
  throw new Error(message);
}

function sha256(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

function run(command, args, label) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 || result.signal !== null) {
    fail(`${label} failed: ${result.stderr.trim()}`);
  }
  return result.stdout.replace(/\r/g, "").trim();
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
    "helium-physical-oneplus-v1",
    value.adb_serial,
    value.android_model,
    value.android_device,
    value.android_product,
    value.android_manufacturer,
    value.build_fingerprint_sha256,
  ].join("\n") + "\n";
}

export function validatePhysicalDeviceIdentity(value) {
  exactKeys(value, [
    "schema_version", "identity_schema", "adb_serial", "adb_transport",
    "adb_transport_id", "adb_usb_path_sha256", "android_model",
    "android_device", "android_product", "android_manufacturer",
    "build_fingerprint_sha256", "physical_identity_sha256", "captured_at",
  ], "physical OnePlus identity");
  if (value.schema_version !== 1 ||
      value.identity_schema !== "helium-physical-oneplus-v1" ||
      value.adb_transport !== "physical-usb" ||
      !SERIAL.test(value.adb_serial) || value.adb_serial.includes(":") ||
      value.adb_serial.startsWith("emulator-") ||
      !/^[1-9][0-9]*$/.test(value.adb_transport_id) ||
      !HASH.test(value.adb_usb_path_sha256) ||
      value.android_model !== ONEPLUS_MODEL ||
      value.android_device !== ONEPLUS_DEVICE ||
      !TOKEN.test(value.android_product) ||
      value.android_manufacturer !== "OnePlus" ||
      !HASH.test(value.build_fingerprint_sha256) ||
      !HASH.test(value.physical_identity_sha256) ||
      value.physical_identity_sha256 !==
        sha256(Buffer.from(canonicalIdentity(value))) ||
      !Number.isFinite(Date.parse(value.captured_at))) {
    fail("physical OnePlus identity is invalid");
  }
  return value;
}

export function capturePhysicalDeviceIdentity(serial) {
  if (!SERIAL.test(serial || "") || serial.includes(":") ||
      serial.startsWith("emulator-")) {
    fail("physical OnePlus capture requires a non-network, non-emulator serial");
  }
  if (run("adb", ["-s", serial, "get-state"], "ADB device state") !== "device") {
    fail("ADB target is not in device state");
  }
  const lines = run("adb", ["devices", "-l"], "ADB inventory")
    .split("\n").filter(line => line.startsWith(`${serial}\tdevice `));
  if (lines.length !== 1 || !/(?:^|\s)usb:[^\s]+/.test(lines[0])) {
    fail("ADB target is not one unambiguous physical USB device");
  }
  const line = lines[0];
  const field = name => {
    const match = new RegExp(`(?:^|\\s)${name}:([^\\s]+)`).exec(line);
    if (!match) fail(`ADB inventory is missing ${name}`);
    return match[1];
  };
  const adbModel = field("model");
  const adbDevice = field("device");
  const adbProduct = field("product");
  const transportID = field("transport_id");
  const usbPath = field("usb");
  const getprop = name => run(
    "adb", ["-s", serial, "shell", "getprop", name], `Android ${name}`);
  const model = getprop("ro.product.model");
  const device = getprop("ro.product.device");
  const product = getprop("ro.product.name");
  const manufacturer = getprop("ro.product.manufacturer");
  const fingerprint = getprop("ro.build.fingerprint");
  if (adbModel !== model || adbDevice !== device || adbProduct !== product ||
      !fingerprint || /[\r\n\0]/.test(fingerprint)) {
    fail("ADB transport and Android build identity disagree");
  }
  const value = {
    schema_version: 1,
    identity_schema: "helium-physical-oneplus-v1",
    adb_serial: serial,
    adb_transport: "physical-usb",
    adb_transport_id: transportID,
    adb_usb_path_sha256: sha256(Buffer.from(`${usbPath}\n`)),
    android_model: model,
    android_device: device,
    android_product: product,
    android_manufacturer: manufacturer,
    build_fingerprint_sha256: sha256(Buffer.from(`${fingerprint}\n`)),
    physical_identity_sha256: "",
    captured_at: new Date().toISOString(),
  };
  value.physical_identity_sha256 = sha256(Buffer.from(canonicalIdentity(value)));
  return validatePhysicalDeviceIdentity(value);
}

export function physicalIdentityEnv(value) {
  validatePhysicalDeviceIdentity(value);
  return `${Object.entries(value).map(([key, item]) => `${key}=${item}`).join("\n")}\n`;
}

export function parsePhysicalDeviceIdentityEnv(raw) {
  const value = {};
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const item = line.slice(separator + 1);
    if (separator < 1 || !item || Object.hasOwn(value, key) ||
        /[\r\n\0]/.test(item)) {
      fail("physical OnePlus identity receipt is malformed");
    }
    value[key] = key === "schema_version" ? Number(item) : item;
  }
  return validatePhysicalDeviceIdentity(value);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, option, serial] = process.argv.slice(2);
    if (command !== "capture" || option !== "--adb-serial" || !serial ||
        process.argv.length !== 5) {
      fail("usage: physical-device-identity.mjs capture --adb-serial SERIAL");
    }
    process.stdout.write(physicalIdentityEnv(
      capturePhysicalDeviceIdentity(serial)));
  } catch (error) {
    process.stderr.write(`physical device identity: ${error.message}\n`);
    process.exitCode = 1;
  }
}
