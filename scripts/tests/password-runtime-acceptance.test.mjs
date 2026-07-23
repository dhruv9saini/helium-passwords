import assert from "node:assert/strict";
import crypto from "node:crypto";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {startNativePasswordFixture} from "../password-runtime/fixture-server.mjs";
import {
  auditRun,
  captureStep,
  initializeRun,
  NATIVE_PASSWORD_STEPS,
  verifyRun,
} from "../password-runtime/acceptance.mjs";

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const FIXTURE_NONCE = "a".repeat(64);

async function writeLinuxArtifactReceipt(root, artifact) {
  const artifactHash = crypto.createHash("sha256")
    .update(await fsp.readFile(artifact)).digest("hex");
  const bundle = path.join(root, "helium-passwords-linux-x86_64");
  const runtime = path.join(bundle, "runtime");
  const provenance = path.join(bundle, "provenance");
  const browser = path.join(runtime, "helium");
  await fsp.mkdir(runtime, {recursive: true});
  await fsp.mkdir(provenance, {recursive: true});
  await fsp.writeFile(browser, "synthetic browser binary", {mode: 0o700});
  const inventory = path.join(provenance, "runtime.sha256");
  const entries = [artifact, browser].sort();
  const inventoryRaw = (await Promise.all(entries.map(async file => {
    const digest = crypto.createHash("sha256")
      .update(await fsp.readFile(file)).digest("hex");
    return `${digest}  ${path.relative(bundle, file)}`;
  }))).join("\n") + "\n";
  await fsp.writeFile(inventory, inventoryRaw, {mode: 0o600});
  const receipt = path.join(root, "artifact-receipt.env");
  await fsp.writeFile(receipt, [
    "schema_version=2",
    "product=helium-passwords",
    "platform=linux",
    "arch=x86_64",
    `source_commit=${"1".repeat(40)}`,
    `helium_core_commit=${"2".repeat(40)}`,
    "chromium_version=150.0.7871.181",
    `chromium_commit=${"3".repeat(40)}`,
    `platform_commit=${"4".repeat(40)}`,
    `bundle=${path.join(root, "bundle.tar.xz")}`,
    `bundle_sha256=${"5".repeat(64)}`,
    `provenance_manifest_sha256=${"6".repeat(64)}`,
    `browser_executable=${path.relative(root, artifact)}`,
    `browser_sha256=${artifactHash}`,
    `runtime_inventory=${path.relative(root, inventory)}`,
    `runtime_inventory_sha256=${crypto.createHash("sha256").update(inventoryRaw).digest("hex")}`,
    "verified_at=synthetic-fixture",
    "",
  ].join("\n"), {mode: 0o600});
  return receipt;
}

async function postForm(url, values) {
  return fetch(url, {
    method: "POST",
    redirect: "manual",
    headers: {"content-type": "application/x-www-form-urlencoded"},
    body: new URLSearchParams(values),
  });
}

async function completeFixture(fixture, evidence) {
  const username = "synthetic-user-never-emit";
  const initial = "synthetic-initial-never-emit";
  const replacement = "synthetic-generated-replacement-never-emit";
  assert.equal((await postForm(`${fixture.origin}/session`, {username, password: initial})).status, 303);
  assert.equal((await postForm(`${fixture.origin}/session`, {username, password: initial})).status, 303);
  assert.equal((await postForm(`${fixture.origin}/password`, {
    username,
    current_password: initial,
    new_password: replacement,
    confirm_password: replacement,
  })).status, 303);
  assert.equal((await postForm(`${fixture.origin}/session`, {username, password: replacement})).status, 303);
  assert.equal((await fetch(`${fixture.origin}/deleted-empty`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({username_empty: true, password_empty: true}),
  })).status, 204);
  return {username, initial, replacement, raw: await fsp.readFile(evidence, "utf8")};
}

test("native fixture attests restart, update, and deletion without emitting submitted values", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-native-fixture-"));
  const evidence = path.join(root, "fixture-evidence.json");
  await assert.rejects(startNativePasswordFixture({evidencePath: evidence}), /runNonce/);
  const fixture = await startNativePasswordFixture({
    evidencePath: evidence,
    runNonce: FIXTURE_NONCE,
  });
  const username = "synthetic-user-never-emit";
  const initial = "synthetic-initial-never-emit";
  const replacement = "synthetic-generated-replacement-never-emit";
  try {
    assert.equal((await fetch(`${fixture.origin}/login`)).status, 200);
    assert.equal((await postForm(`${fixture.origin}/session`, {
      username,
      password: initial,
      unexpected: "synthetic-extra-field",
    })).status, 400);
    assert.equal((await postForm(`${fixture.origin}/session`, {username, password: initial})).status, 303);
    assert.equal((await postForm(`${fixture.origin}/session`, {username, password: "wrong-synthetic-password"})).status, 409);
    await assert.rejects(fsp.stat(evidence), error => error.code === "ENOENT");
    assert.equal((await postForm(`${fixture.origin}/session`, {username, password: initial})).status, 303);
    assert.equal((await fetch(`${fixture.origin}/change-password`)).status, 200);
    assert.equal((await postForm(`${fixture.origin}/password`, {
      username,
      current_password: "wrong-current-password",
      new_password: replacement,
      confirm_password: replacement,
    })).status, 422);
    assert.equal((await postForm(`${fixture.origin}/password`, {
      username,
      current_password: initial,
      new_password: replacement,
      confirm_password: replacement,
    })).status, 303);
    assert.equal((await postForm(`${fixture.origin}/session`, {username, password: replacement})).status, 303);
    assert.equal((await fetch(`${fixture.origin}/deleted-empty`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({username_empty: true, password_empty: false}),
    })).status, 422);
    await assert.rejects(fsp.stat(evidence), error => error.code === "ENOENT");
    assert.equal((await fetch(`${fixture.origin}/deleted-empty`, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({username_empty: true, password_empty: true}),
    })).status, 204);
    const raw = await fsp.readFile(evidence, "utf8");
    for (const secret of [username, initial, replacement]) assert.doesNotMatch(raw, new RegExp(secret));
    const parsed = JSON.parse(raw);
    assert.equal(parsed.schema_version, 2);
    assert.equal(parsed.run_nonce, FIXTURE_NONCE);
    assert.equal(parsed.evidence_contains_submitted_values, false);
    assert.ok(Object.values(parsed.observations).every(value => value === true));
  } finally {
    await fixture.close();
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("artifact-bound receipt requires the complete ordered native UI lifecycle", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-native-run-"));
  const artifact = path.join(
    root, "helium-passwords-linux-x86_64", "runtime", "helium-wrapper");
  const screenshot = path.join(root, "screen.png");
  const invalidScreenshot = path.join(root, "invalid-screen.png");
  const runRoot = path.join(root, "acceptance");
  const evidence = path.join(root, "fixture-evidence.json");
  let fixture;
  try {
    await fsp.mkdir(path.dirname(artifact), {recursive: true});
    await fsp.writeFile(artifact, "synthetic browser artifact", {mode: 0o700});
    await fsp.writeFile(screenshot, PNG, {mode: 0o600});
    await fsp.writeFile(invalidScreenshot, Buffer.concat([
      PNG.subarray(0, 8),
      Buffer.from("not a complete PNG"),
    ]), {mode: 0o600});
    await assert.rejects(initializeRun({
      artifact, output: path.join(root, "missing-receipt"), platform: "linux",
    }), /requires a verified artifact receipt/);
    const artifactReceipt = await writeLinuxArtifactReceipt(root, artifact);
    const run = await initializeRun({
      artifact, artifactReceipt, output: runRoot, platform: "linux",
    });
    assert.equal(run.profile_path, path.join(runRoot, "profile"));
    assert.match(run.run_nonce, /^[0-9a-f]{64}$/);
    assert.match(run.artifact_receipt_sha256, /^[0-9a-f]{64}$/);
    await assert.rejects(captureStep({
      runRoot,
      step: "settings_entry",
      screenshot: invalidScreenshot,
    }), /PNG/);
    await assert.rejects(captureStep({
      runRoot,
      step: "save_prompt",
      screenshot,
    }), /expected acceptance step settings_entry/);
    for (const step of NATIVE_PASSWORD_STEPS) {
      await captureStep({runRoot, step, screenshot});
    }
    fixture = await startNativePasswordFixture({
      evidencePath: evidence,
      runNonce: run.run_nonce,
    });
    const secrets = await completeFixture(fixture, evidence);
    for (const secret of [secrets.username, secrets.initial, secrets.replacement]) {
      assert.doesNotMatch(secrets.raw, new RegExp(secret));
    }
    const wrongEvidence = path.join(root, "wrong-fixture-evidence.json");
    const wrongFixture = JSON.parse(secrets.raw);
    wrongFixture.run_nonce = "b".repeat(64);
    await fsp.writeFile(wrongEvidence, `${JSON.stringify(wrongFixture)}\n`, {mode: 0o600});
    await assert.rejects(auditRun({
      runRoot,
      fixtureEvidence: wrongEvidence,
    }), /different acceptance run/);
    const browser = path.join(
      root, "helium-passwords-linux-x86_64", "runtime", "helium");
    await fsp.appendFile(browser, "tampered");
    await assert.rejects(auditRun({
      runRoot,
      fixtureEvidence: evidence,
    }), /runtime file changed/);
    await fsp.writeFile(browser, "synthetic browser binary", {mode: 0o700});
    const receipt = await verifyRun({runRoot, fixtureEvidence: evidence});
    assert.equal(receipt.result, "passed");
    assert.equal(receipt.schema_version, 2);
    assert.equal(receipt.run_nonce, run.run_nonce);
    assert.equal(receipt.artifact_receipt_sha256, run.artifact_receipt_sha256);
    assert.equal(receipt.screenshots.length, NATIVE_PASSWORD_STEPS.length);
    assert.equal((await fsp.stat(path.join(runRoot, "receipt.json"))).mode & 0o777, 0o600);
    const firstScreenshot = path.join(runRoot, "screenshots", `01-${NATIVE_PASSWORD_STEPS[0]}.png`);
    await fsp.appendFile(firstScreenshot, "tampered");
    await assert.rejects(auditRun({runRoot, fixtureEvidence: evidence}), /PNG|screenshot changed/);
  } finally {
    if (fixture) await fixture.close();
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("Android admission requires a prepared artifact and matching non-production test package", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-android-admission-"));
  try {
    const prepared = path.join(root, "prepared");
    const apk = path.join(prepared, "Browser-test.apk");
    await fsp.mkdir(prepared);
    await fsp.writeFile(apk, "synthetic test apk", {mode: 0o600});
    const apkHash = crypto.createHash("sha256").update("synthetic test apk").digest("hex");
    await fsp.writeFile(path.join(prepared, "acceptance.env"), [
      "schema_version=1",
      "package=computer.helium.passwords.test",
      `apk_sha256=${apkHash}`,
      "prepared_at=fixture",
      "",
    ].join("\n"), {mode: 0o600});
    await fsp.writeFile(path.join(prepared, "PACKAGE_SHA256SUMS"),
      `${apkHash}  ./Browser-test.apk\n`, {mode: 0o600});
    await assert.rejects(initializeRun({
      artifact: apk,
      output: path.join(root, "production-package"),
      platform: "android",
      packageName: "computer.helium.passwords",
    }), /ending in \.test/);
    await assert.rejects(initializeRun({
      artifact: apk,
      output: path.join(root, "wrong-test-package"),
      platform: "android",
      packageName: "computer.helium.other.test",
    }), /does not admit/);
    const run = await initializeRun({
      artifact: apk,
      output: path.join(root, "admitted"),
      platform: "android",
      packageName: "computer.helium.passwords.test",
    });
    assert.equal(run.artifact_sha256, apkHash);
    assert.equal(run.profile_path, null);
  } finally {
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("public runtime harness has no password-store writer, extension, or Sync journal path", async () => {
  const source = await fsp.readFile(new URL("../password-runtime/acceptance.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(source, /passwordsPrivate|AddLogin|UpdateLogin|chrome\.extension|load-extension|cdp-password-sync/);
  assert.doesNotMatch(source, /password-state|journal|tombstone|computer\.helium\.sync/);
});
