#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const HASH = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const PACKAGES = Object.freeze({
  sync: Object.freeze({
    package: "computer.helium.sync.test",
    socket: "helium_sync_test_devtools_remote",
    cookie: true,
  }),
  control: Object.freeze({
    package: "computer.helium.control.test",
    socket: "helium_control_test_devtools_remote",
    cookie: false,
  }),
});

function fail(message) {
  throw new Error(message);
}

function equal(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function sha256(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map(key =>
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function validatePhysicalDeviceIdentity(value) {
  const expected = [
    "schema_version", "identity_schema", "adb_serial", "adb_transport",
    "adb_transport_id", "adb_usb_path_sha256", "android_model",
    "android_device", "android_product", "android_manufacturer",
    "build_fingerprint_sha256", "physical_identity_sha256", "captured_at",
  ];
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !equal(Object.keys(value).sort(), expected.sort())) {
    fail("physical OnePlus identity has an unexpected field inventory");
  }
  const canonical = [
    "helium-physical-oneplus-v1", value.adb_serial, value.android_model,
    value.android_device, value.android_product, value.android_manufacturer,
    value.build_fingerprint_sha256,
  ].join("\n") + "\n";
  if (value.schema_version !== 1 ||
      value.identity_schema !== "helium-physical-oneplus-v1" ||
      value.adb_transport !== "physical-usb" ||
      !/^[A-Za-z0-9._-]+$/.test(value.adb_serial || "") ||
      value.adb_serial.startsWith("emulator-") ||
      !/^[1-9][0-9]*$/.test(value.adb_transport_id || "") ||
      !HASH.test(value.adb_usb_path_sha256 || "") ||
      value.android_model !== "CPH2655" || value.android_device !== "dodge" ||
      !/^[A-Za-z0-9._-]+$/.test(value.android_product || "") ||
      value.android_manufacturer !== "OnePlus" ||
      !HASH.test(value.build_fingerprint_sha256 || "") ||
      value.physical_identity_sha256 !== sha256(Buffer.from(canonical)) ||
      !Number.isFinite(Date.parse(value.captured_at))) {
    fail("physical OnePlus identity is invalid");
  }
  return value;
}

async function regularFile(file, label, maximum = 32 * 1024 * 1024) {
  const resolved = path.resolve(file);
  const stat = await fsp.lstat(resolved);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 ||
      stat.size > maximum) {
    fail(`${label} must be a nonempty regular file within its size limit`);
  }
  return {resolved, stat};
}

async function realDirectory(directory, label) {
  const resolved = path.resolve(directory);
  const stat = await fsp.lstat(resolved);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      await fsp.realpath(resolved) !== resolved) {
    fail(`${label} must be a canonical real directory`);
  }
  return resolved;
}

async function readEnv(file, label) {
  const admitted = await regularFile(file, label, 1024 * 1024);
  const raw = await fsp.readFile(admitted.resolved, "utf8");
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (separator < 1 || !value || values.has(key) || /[\r\n\0]/.test(value)) {
      fail(`${label} is malformed`);
    }
    values.set(key, value);
  }
  return {file: admitted.resolved, raw, values};
}

async function readJSON(file, label) {
  const admitted = await regularFile(file, label, 16 * 1024 * 1024);
  const raw = await fsp.readFile(admitted.resolved, "utf8");
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    fail(`${label} is not valid JSON`);
  }
  return {file: admitted.resolved, raw, value};
}

async function walkFiles(root, relative = "") {
  const result = [];
  for (const entry of await fsp.readdir(path.join(root, relative),
    {withFileTypes: true})) {
    const child = relative ? path.posix.join(relative, entry.name) : entry.name;
    if (entry.isDirectory()) result.push(...await walkFiles(root, child));
    else if (entry.isFile() && !entry.isSymbolicLink()) result.push(child);
    else fail(`unsafe evidence entry: ${child}`);
  }
  return result.sort();
}

async function auditChecksums(root, inventoryName, label, recursive) {
  const inventory = await regularFile(path.join(root, inventoryName),
    `${label} checksum inventory`, 16 * 1024 * 1024);
  const raw = await fsp.readFile(inventory.resolved, "utf8");
  const recorded = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const match = recursive
      ? /^([0-9a-f]{64})  \.\/(.+)$/.exec(line)
      : /^([0-9a-f]{64})  (?:\.\/)?([A-Za-z0-9._-]+)$/.exec(line);
    const relative = match?.[2];
    if (!match || !relative || relative.startsWith("/") ||
        relative.includes("\\") || relative.split("/").some(part =>
          !part || part === "." || part === "..") || recorded.has(relative) ||
        relative === inventoryName) {
      fail(`${label} checksum inventory is malformed`);
    }
    recorded.set(relative, match[1]);
  }
  const actual = (recursive ? await walkFiles(root) :
    (await fsp.readdir(root, {withFileTypes: true})).map(entry => {
      if (!entry.isFile() || entry.isSymbolicLink()) {
        fail(`${label} contains a non-file entry`);
      }
      return entry.name;
    })).filter(name => name !== inventoryName).sort();
  if (!equal([...recorded.keys()].sort(), actual)) {
    fail(`${label} checksum inventory is incomplete or unexpected`);
  }
  for (const relative of actual) {
    if (await sha256File(path.join(root, relative)) !== recorded.get(relative)) {
      fail(`${label} file changed after capture: ${relative}`);
    }
  }
  return {raw, sha256: sha256(Buffer.from(raw))};
}

function actionsPhysicalIdentity(actions) {
  const get = name => actions.values.get(name);
  return validatePhysicalDeviceIdentity({
    schema_version: 1,
    identity_schema: get("identity_schema"),
    adb_serial: get("adb_serial"),
    adb_transport: get("adb_transport"),
    adb_transport_id: get("adb_transport_id"),
    adb_usb_path_sha256: get("adb_usb_path_sha256"),
    android_model: get("android_model"),
    android_device: get("android_device"),
    android_product: get("android_product"),
    android_manufacturer: get("android_manufacturer"),
    build_fingerprint_sha256: get("build_fingerprint_sha256"),
    physical_identity_sha256: get("physical_identity_sha256"),
    captured_at: get("physical_identity_captured_at"),
  });
}

function auditCookieManager(value) {
  const coverage = value?.import?.attribute_coverage;
  if (value?.schema_version !== 1 ||
      value?.fixture !== "helium-cookie-manager-disposable-v1" ||
      value?.synthetic_only !== true || value?.status !== "passed" ||
      value?.reason !== "" ||
      value?.cookie_api !== "network::mojom::CookieManager" ||
      value?.destination_snapshot?.complete_profile_cookie_count !== 1 ||
      value?.destination_snapshot?.snapshot_persisted_before_apply !== true ||
      !HASH.test(value?.destination_snapshot?.fingerprint || "") ||
      value?.import?.record_count !== 3 ||
      value?.import?.apply_result !== "accepted" ||
      value?.import?.readback_result !== "exact" ||
      !HASH.test(value?.import?.fingerprint || "") ||
      value?.import?.canonical_record_keys_unique !== true ||
      value?.import?.partitioned_and_unpartitioned_identity_distinct !== true ||
      !coverage || Object.values(coverage).some(item => item !== true) ||
      value?.destination_rejection?.set_result !== "rejected" ||
      value?.destination_rejection?.rollback_result !== "exact" ||
      value?.origin_state?.cookie_names_guessed !== false ||
      value?.origin_state?.cookie_manager_supported !== true ||
      value?.origin_state?.registered_adapter_count !== 0 ||
      value?.origin_state?.non_cookie_transfer_result !== "not-tested" ||
      value?.cleanup?.complete_profile_cookie_store !== "empty") {
    fail("browser-native CookieManager acceptance evidence is invalid");
  }
}

function auditProbeResult(result, diagnostics, metadata, spec) {
  const get = name => metadata.values.get(name);
  if (result?.runtime?.android_package !== spec.package ||
      result?.runtime?.artifact_sha256 !== get("apk_sha256") ||
      result?.runtime?.chromium_commit !== get("chromium_commit") ||
      result?.runtime?.helium_sync_commit !== get("helium_sync_commit") ||
      result?.runtime?.device_socket !== spec.socket ||
      !equal(result?.required_transport_protocols, ["h2", "h3"]) ||
      !equal(result?.required_lifecycle,
        {background_foreground: true, network_handoff: true}) ||
      result?.service_worker?.supported !== true ||
      result?.service_worker?.controlled !== true ||
      result?.service_worker?.script_url !== "/service-worker.js" ||
      result?.media_diagnostics?.source !== "CDP Media domain" ||
      result?.media_diagnostics?.enabled !== true ||
      !Number.isSafeInteger(result?.media_diagnostics?.event_count) ||
      result.media_diagnostics.event_count < 1 ||
      !Number.isSafeInteger(result?.media_diagnostics?.player_count) ||
      result.media_diagnostics.player_count < 1 ||
      typeof result?.drm?.widevine?.api_available !== "boolean" ||
      typeof result?.drm?.widevine?.key_system_available !== "boolean" ||
      result?.drm?.widevine?.key_system !== "com.widevine.alpha") {
    fail(`${spec.package} probe result is not source-bound full Android evidence`);
  }
  if (diagnostics?.schema_version !== 1 ||
      diagnostics?.synthetic_fixture_only !== true ||
      diagnostics?.source !== "CDP Media domain" || diagnostics?.enabled !== true ||
      !Array.isArray(diagnostics?.events) ||
      diagnostics.events.length !== diagnostics.event_count ||
      diagnostics.event_count !== result.media_diagnostics.event_count ||
      diagnostics.player_count !== result.media_diagnostics.player_count ||
      !equal(diagnostics.method_counts, result.media_diagnostics.method_counts)) {
    fail(`${spec.package} CDP Media diagnostics are incomplete or result-mismatched`);
  }
}

export async function auditProbeGeneration(acceptanceDirectory,
  evidenceDirectory, role) {
  const spec = PACKAGES[role];
  if (!spec) fail("probe generation role must be sync or control");
  const acceptance = await realDirectory(acceptanceDirectory,
    `${role} prepared acceptance`);
  const evidence = await realDirectory(evidenceDirectory, `${role} device evidence`);
  const acceptanceInventory = await auditChecksums(acceptance,
    "PACKAGE_SHA256SUMS", `${role} prepared acceptance`, true);
  const evidenceInventory = await auditChecksums(evidence,
    "EVIDENCE_SHA256SUMS", `${role} device evidence`, false);
  const metadata = await readEnv(path.join(acceptance, "acceptance.env"),
    `${role} acceptance metadata`);
  const copiedMetadata = await regularFile(path.join(evidence, "acceptance.env"),
    `${role} copied acceptance metadata`);
  if (await fsp.readFile(copiedMetadata.resolved, "utf8") !== metadata.raw) {
    fail(`${role} device evidence is not bound to its acceptance generation`);
  }
  const get = name => metadata.values.get(name);
  const metadataKeys = [
    "schema_version", "package", "helium_sync_commit", "chromium_commit",
    "version_code", "version_name", "source_archive_sha256", "apk_sha256",
    "runtime_kit_sha256", "prepared_at",
  ];
  if (!equal([...metadata.values.keys()].sort(), metadataKeys.sort()) ||
      get("schema_version") !== "2" || get("package") !== spec.package ||
      !COMMIT.test(get("helium_sync_commit") || "") ||
      !COMMIT.test(get("chromium_commit") || "") ||
      !HASH.test(get("source_archive_sha256") || "") ||
      !HASH.test(get("apk_sha256") || "") ||
      !HASH.test(get("runtime_kit_sha256") || "") ||
      !/^[1-9][0-9]*$/.test(get("version_code") || "") ||
      !/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/.test(get("version_name") || "")) {
    fail(`${role} acceptance generation has an invalid source identity`);
  }
  const runtimeInventory = path.join(acceptance, "runtime-acceptance", "SHA256SUMS");
  if (await sha256File(runtimeInventory) !== get("runtime_kit_sha256")) {
    fail(`${role} acceptance metadata does not identify its runtime kit`);
  }
  const actions = await readEnv(path.join(evidence, "actions.env"),
    `${role} device actions`);
  const action = name => actions.values.get(name);
  const actionKeys = [
    "schema_version", "package", "identity_schema", "adb_serial",
    "adb_transport", "adb_transport_id", "adb_usb_path_sha256",
    "android_model", "android_device", "android_product",
    "android_manufacturer", "build_fingerprint_sha256",
    "physical_identity_sha256", "physical_identity_captured_at",
    "background_foreground", "network_handoff", "version_code",
    "version_name", "installed_apk_sha256", "package_uid", "logcat_scope",
    "cookie_acceptance", "device_socket", "fixture_spki_sha256_base64",
    "fixture_cert_sha256", "fixture_receipt_sha256", "started_at",
    "completed_at",
  ];
  if (!equal([...actions.values.keys()].sort(), actionKeys.sort())) {
    fail(`${role} actions have an unexpected field inventory`);
  }
  const physicalIdentity = actionsPhysicalIdentity(actions);
  if (action("schema_version") !== "2" || action("package") !== spec.package ||
      action("installed_apk_sha256") !== get("apk_sha256") ||
      action("device_socket") !== spec.socket ||
      action("version_code") !== get("version_code") ||
      action("version_name") !== get("version_name") ||
      !/^[1-9][0-9]*$/.test(action("package_uid") || "") ||
      action("logcat_scope") !== "package-uid" ||
      action("background_foreground") !== "true" ||
      action("network_handoff") !== "wifi-to-cellular" ||
      action("cookie_acceptance") !== String(spec.cookie) ||
      !Number.isFinite(Date.parse(action("started_at") || "")) ||
      !Number.isFinite(Date.parse(action("completed_at") || "")) ||
      Date.parse(action("started_at")) > Date.parse(action("completed_at"))) {
    fail(`${role} actions do not prove the complete admitted device lifecycle`);
  }
  const result = await readJSON(path.join(evidence, "result.json"),
    `${role} probe result`);
  const probeValidator = path.join(
    acceptance, "runtime-acceptance", "run-cdp-probe.mjs");
  const validatorSourceSHA256 = await sha256File(probeValidator);
  const validator = await import(
    `${pathToFileURL(probeValidator).href}?sha256=${validatorSourceSHA256}`);
  if (typeof validator.validateProbeResult !== "function") {
    fail(`${role} runtime kit does not export the complete probe validator`);
  }
  validator.validateProbeResult(result.value);
  const diagnostics = await readJSON(path.join(evidence, "media-diagnostics.json"),
    `${role} CDP Media diagnostics`);
  auditProbeResult(result.value, diagnostics.value, metadata, spec);
  for (const name of [
    "package-logcat.txt", "probe-runner.log", "fixture-server.log",
  ]) {
    const log = await fsp.readFile(path.join(evidence, name), "utf8");
    if (/authorization\s*:\s*bearer|bearer\s+[A-Za-z0-9+/=_-]{16,}|password\s*[=:]\s*\S+/i.test(log)) {
      fail(`${role} ${name} contains a bearer token or password value`);
    }
  }
  const fixture = await regularFile(path.join(evidence, "fixture-provenance.json"),
    `${role} fixture receipt`);
  const fixtureSHA256 = await sha256File(fixture.resolved);
  const fixtureReceipt = JSON.parse(await fsp.readFile(fixture.resolved, "utf8"));
  if (!fixtureReceipt || typeof fixtureReceipt !== "object" ||
      Array.isArray(fixtureReceipt) || !equal(Object.keys(fixtureReceipt).sort(), [
        "schema_version", "disposable_only", "tls_mode", "hostname",
        "h2_port", "h3_port", "leaf_spki_sha256_base64",
        "leaf_cert_sha256", "required_chromium_switch",
      ].sort()) || fixtureReceipt.schema_version !== 1 ||
      fixtureReceipt.disposable_only !== true ||
      fixtureReceipt.tls_mode !== "private-ca-spki" ||
      fixtureReceipt.hostname !== "lm.tail0168aa.ts.net" ||
      fixtureReceipt.h2_port !== 44723 || fixtureReceipt.h3_port !== 44724 ||
      !/^[A-Za-z0-9+/]{43}=$/.test(
        fixtureReceipt.leaf_spki_sha256_base64 || "") ||
      !HASH.test(fixtureReceipt.leaf_cert_sha256 || "") ||
      fixtureReceipt.required_chromium_switch !==
        `--ignore-certificate-errors-spki-list=${fixtureReceipt.leaf_spki_sha256_base64}` ||
      action("fixture_receipt_sha256") !== fixtureSHA256 ||
      action("fixture_spki_sha256_base64") !==
        fixtureReceipt.leaf_spki_sha256_base64 ||
      action("fixture_cert_sha256") !== fixtureReceipt.leaf_cert_sha256 ||
      result.value.runtime.fixture_spki_sha256_base64 !==
        fixtureReceipt.leaf_spki_sha256_base64) {
    fail(`${role} fixture receipt is not bound to the device actions`);
  }
  const cookiePath = path.join(evidence, "cookie-native-acceptance.json");
  if (spec.cookie) {
    const cookie = await readJSON(cookiePath, "Sync CookieManager acceptance");
    auditCookieManager(cookie.value);
  } else {
    try {
      await fsp.lstat(cookiePath);
      fail("control evidence contains Sync CookieManager evidence");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  return {
    acceptance,
    evidence,
    acceptance_inventory_sha256: acceptanceInventory.sha256,
    evidence_inventory_sha256: evidenceInventory.sha256,
    metadata,
    actions,
    physical_identity: physicalIdentity,
    result,
    fixture_sha256: fixtureSHA256,
    media_manifest_canonical: canonicalJSON(result.value.media_manifest),
  };
}

export async function auditProbePair({
  syncAcceptance, syncEvidence, controlAcceptance, controlEvidence,
}) {
  const sync = await auditProbeGeneration(syncAcceptance, syncEvidence, "sync");
  const control = await auditProbeGeneration(controlAcceptance, controlEvidence,
    "control");
  const s = name => sync.metadata.values.get(name);
  const c = name => control.metadata.values.get(name);
  for (const field of [
    "helium_sync_commit", "chromium_commit", "version_code", "version_name",
  ]) {
    if (s(field) !== c(field)) fail(`Sync and control do not share ${field}`);
  }
  const syncFlags = path.join(sync.acceptance, "build-provenance", "flags.gn");
  const controlFlags = path.join(control.acceptance, "build-provenance", "flags.gn");
  const syncLocked = path.join(sync.acceptance, "build-provenance",
    "locked-gn-args-resolved.txt");
  const controlLocked = path.join(control.acceptance, "build-provenance",
    "locked-gn-args-resolved.txt");
  const sharedFlags = await sha256File(syncFlags);
  const sharedLocked = await sha256File(syncLocked);
  if (sharedFlags !== await sha256File(controlFlags)) {
    fail("Sync and control were not built from byte-identical flags.gn");
  }
  if (sharedLocked !== await sha256File(controlLocked)) {
    fail("Sync and control do not have byte-identical effective locked GN values");
  }
  for (const name of [
    "fixture-server.mjs", "generate-fixtures.sh", "run-cdp-probe.mjs",
    "disposable-browser.sh", "prepare-cookie-acceptance-profile.sh",
    "run-device-probe.sh", "audit-probe-pair.mjs", "verify-probe-pair.sh",
  ]) {
    if (await sha256File(path.join(sync.acceptance, "runtime-acceptance", name)) !==
        await sha256File(path.join(control.acceptance, "runtime-acceptance", name))) {
      fail(`Sync and control used different acceptance code: ${name}`);
    }
  }
  if (sync.fixture_sha256 !== control.fixture_sha256) {
    fail("Sync and control did not use one protocol fixture generation");
  }
  if (sync.media_manifest_canonical !== control.media_manifest_canonical) {
    fail("Sync and control did not exercise byte-identical media fixtures");
  }
  if (sync.physical_identity.physical_identity_sha256 !==
      control.physical_identity.physical_identity_sha256) {
    fail("Sync and control did not run on the same physical OnePlus");
  }
  return {
    sync,
    control,
    helium_sync_commit: s("helium_sync_commit"),
    chromium_commit: s("chromium_commit"),
    sync_archive_sha256: s("source_archive_sha256"),
    sync_apk_sha256: s("apk_sha256"),
    sync_result_sha256: sha256(Buffer.from(sync.result.raw)),
    control_archive_sha256: c("source_archive_sha256"),
    control_apk_sha256: c("apk_sha256"),
    control_result_sha256: sha256(Buffer.from(control.result.raw)),
    shared_flags_gn_sha256: sharedFlags,
    shared_locked_gn_args_sha256: sharedLocked,
    fixture_receipt_sha256: sync.fixture_sha256,
    media_manifest_sha256: sha256(Buffer.from(sync.media_manifest_canonical)),
    physical_identity_sha256: sync.physical_identity.physical_identity_sha256,
    offline_auditor_sha256: await sha256File(fileURLToPath(import.meta.url)),
  };
}

function parseOptions(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined || values.has(key)) {
      fail("options must be unique --name value pairs");
    }
    values.set(key, value);
  }
  return values;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [command, ...args] = process.argv.slice(2);
    if (command !== "verify") fail("usage: audit-probe-pair.mjs verify --sync-acceptance DIR --sync-evidence DIR --control-acceptance DIR --control-evidence DIR");
    const options = parseOptions(args);
    const expected = [
      "--sync-acceptance", "--sync-evidence", "--control-acceptance",
      "--control-evidence",
    ].sort();
    if (!equal([...options.keys()].sort(), expected)) fail("media pair options are incomplete");
    const result = await auditProbePair({
      syncAcceptance: options.get("--sync-acceptance"),
      syncEvidence: options.get("--sync-evidence"),
      controlAcceptance: options.get("--control-acceptance"),
      controlEvidence: options.get("--control-evidence"),
    });
    const fields = [
      "helium_sync_commit", "chromium_commit", "sync_archive_sha256",
      "sync_apk_sha256", "sync_result_sha256", "control_archive_sha256",
      "control_apk_sha256", "control_result_sha256", "shared_flags_gn_sha256",
      "shared_locked_gn_args_sha256", "fixture_receipt_sha256",
      "media_manifest_sha256", "physical_identity_sha256",
      "offline_auditor_sha256",
    ];
    process.stdout.write(`${fields.map(field => `${field}=${result[field]}`).join("\n")}\n`);
  } catch (error) {
    process.stderr.write(`Android offline media audit: ${error.message}\n`);
    process.exitCode = 1;
  }
}
