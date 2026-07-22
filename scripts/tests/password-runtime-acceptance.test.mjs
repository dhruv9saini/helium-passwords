import assert from "node:assert/strict";
import crypto from "node:crypto";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {startNativePasswordFixture} from "../password-runtime/fixture-server.mjs";
import {
  captureStep,
  initializeRun,
  summarizeJournal,
  summarizePasswordState,
  validateAcceptance,
  verifyRun,
} from "../password-runtime/acceptance.mjs";

const STEPS = [
  "settings_entry", "save_prompt", "saved_store", "suggestions",
  "saved_restart_autofill", "generation", "update_prompt", "updated_store",
  "updated_restart_autofill", "delete", "tombstone", "deleted_restart_empty",
];
const STATE_STEPS = new Set([
  "saved_store", "saved_restart_autofill", "updated_store",
  "updated_restart_autofill", "tombstone", "deleted_restart_empty",
]);
const credentialKey = `credential/${"c".repeat(64)}`;
const keyID = "a1b2c3d4e5f60708";

async function postForm(url, values) {
  return fetch(url, {
    method: "POST",
    redirect: "manual",
    headers: {"content-type": "application/x-www-form-urlencoded"},
    body: new URLSearchParams(values),
  });
}

test("native fixture attests restart, update, and deletion without emitting submitted values", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-native-fixture-"));
  const evidence = path.join(root, "fixture-evidence.json");
  const fixture = await startNativePasswordFixture({evidencePath: evidence});
  const username = "synthetic-user-never-emit";
  const initial = "synthetic-initial-never-emit";
  const replacement = "synthetic-generated-replacement-never-emit";
  try {
    assert.equal((await fetch(`${fixture.origin}/login`)).status, 200);
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
    assert.equal(parsed.evidence_contains_submitted_values, false);
    assert.ok(Object.values(parsed.observations).every(value => value === true));
  } finally {
    await fixture.close();
    await fsp.rm(root, {recursive: true, force: true});
  }
});

function state(revision, fingerprint, deleted, sequence = revision) {
  return {
    schema_version: 3,
    verified_sequence: String(sequence),
    credentials: {
      [credentialKey]: {
        fingerprint,
        remote_seq: String(sequence),
        revision: String(revision),
        deleted,
        key_id: keyID,
      },
    },
  };
}

function record(seq, revision, deleted) {
  return JSON.stringify({
    seq: String(seq),
    kind: "passwords",
    key: credentialKey,
    revision: String(revision),
    deleted,
    device_id: "d-test",
    key_id: keyID,
    nonce: `nonce-${seq}`,
    ciphertext: `ciphertext-${seq}`,
  });
}

test("artifact-bound runtime receipt requires native screenshots, exact revisions, tombstone, and no-op restarts", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-native-run-"));
  const artifact = path.join(root, "helium");
  const screenshot = path.join(root, "screen.png");
  const runRoot = path.join(root, "acceptance");
  const statePath = path.join(root, "password-state.json");
  const journalPath = path.join(root, "records.jsonl");
  const fixtureEvidence = path.join(root, "fixture-evidence.json");
  await fsp.writeFile(artifact, "synthetic browser artifact", {mode: 0o700});
  await fsp.writeFile(screenshot, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    Buffer.from("synthetic screenshot bytes"),
  ]), {mode: 0o600});
  const run = await initializeRun({artifact, output: runRoot, platform: "linux"});
  assert.equal(run.profile_path, path.join(runRoot, "profile"));

  const snapshots = {
    saved_store: {state: state(1, "1".repeat(64), false), journal: `${record(1, 1, false)}\n`},
    saved_restart_autofill: {state: state(1, "1".repeat(64), false), journal: `${record(1, 1, false)}\n`},
    updated_store: {state: state(2, "2".repeat(64), false, 2), journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n`},
    updated_restart_autofill: {state: state(2, "2".repeat(64), false, 2), journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n`},
    tombstone: {state: state(3, "", true, 3), journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n${record(3, 3, true)}\n`},
    deleted_restart_empty: {state: state(3, "", true, 3), journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n${record(3, 3, true)}\n`},
  };
  for (const step of STEPS) {
    const snapshot = snapshots[step];
    if (snapshot) {
      await fsp.writeFile(statePath, `${JSON.stringify(snapshot.state)}\n`, {mode: 0o600});
      await fsp.writeFile(journalPath, snapshot.journal, {mode: 0o600});
    }
    await captureStep({
      runRoot,
      step,
      screenshot,
      passwordState: STATE_STEPS.has(step) ? statePath : undefined,
      journal: STATE_STEPS.has(step) ? journalPath : undefined,
    });
  }
  await fsp.writeFile(fixtureEvidence, `${JSON.stringify({
    schema_version: 1,
    completed_at: new Date().toISOString(),
    fixture_origin: "http://127.0.0.1:44722",
    observations: {
      initial_login_accepted: true,
      saved_restart_matches: true,
      update_current_matches: true,
      update_changes_password: true,
      generated_candidate_minimum_length: true,
      updated_restart_matches: true,
      deleted_restart_empty: true,
    },
    evidence_contains_submitted_values: false,
  })}\n`, {mode: 0o600});
  const receipt = await verifyRun({runRoot, fixtureEvidence});
  assert.equal(receipt.result, "passed");
  assert.equal(receipt.saved_revision, "1");
  assert.equal(receipt.updated_revision, "2");
  assert.equal(receipt.tombstone_revision, "3");
  assert.equal((await fsp.stat(path.join(runRoot, "receipt.json"))).mode & 0o777, 0o600);

  const loadedRun = JSON.parse(await fsp.readFile(path.join(runRoot, "run.json"), "utf8"));
  const loadedFixture = JSON.parse(await fsp.readFile(fixtureEvidence, "utf8"));
  const corrupted = structuredClone(loadedRun);
  corrupted.captures.find(item => item.step === "saved_restart_autofill").journal.sha256 = "f".repeat(64);
  assert.throws(() => validateAcceptance(corrupted, loadedFixture), /unchanged restart/);
  await assert.rejects(initializeRun({
    artifact,
    output: path.join(root, "android-wrong-package"),
    platform: "android",
    packageName: "computer.helium.sync",
  }), /computer\.helium\.sync\.test/);
  const prepared = path.join(root, "prepared-android");
  const apk = path.join(prepared, "Browser-test.apk");
  await fsp.mkdir(prepared);
  await fsp.writeFile(apk, "synthetic test apk", {mode: 0o600});
  const apkHash = crypto.createHash("sha256").update("synthetic test apk").digest("hex");
  await fsp.writeFile(path.join(prepared, "acceptance.env"), [
    "schema_version=1",
    "package=computer.helium.sync.test",
    `apk_sha256=${apkHash}`,
    "prepared_at=fixture",
    "",
  ].join("\n"), {mode: 0o600});
  await fsp.writeFile(path.join(prepared, "PACKAGE_SHA256SUMS"),
    `${apkHash}  ./Browser-test.apk\n`, {mode: 0o600});
  const androidRun = await initializeRun({
    artifact: apk,
    output: path.join(root, "android-admitted"),
    platform: "android",
    packageName: "computer.helium.sync.test",
  });
  assert.equal(androidRun.artifact_sha256, apkHash);
  assert.equal(androidRun.profile_path, null);
  await fsp.rm(root, {recursive: true, force: true});
});

test("runtime metadata parsers reject plaintext-shaped or malformed inputs", () => {
  assert.throws(() => summarizePasswordState({schema_version: 3, verified_sequence: "1", credentials: {
    "https://secret.example/user": {},
  }}), /invalid credential key|field inventory/);
  assert.throws(() => summarizeJournal(`${JSON.stringify({
    seq: "1", kind: "passwords", key: credentialKey, revision: "1", deleted: false,
    device_id: "d", key_id: keyID, nonce: "nonce", ciphertext: "ciphertext", password: "forbidden",
  })}\n`), /unexpected field inventory/);
});

test("runtime harness has no password-store writer or extension path", async () => {
  const source = await fsp.readFile(new URL("../password-runtime/acceptance.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(source, /passwordsPrivate|AddLogin|UpdateLogin|chrome\.extension|load-extension|cdp-password-sync/);
});
