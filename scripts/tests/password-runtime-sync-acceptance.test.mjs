import assert from "node:assert/strict";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  captureStep,
  initializeRun,
  NATIVE_PASSWORD_STEPS,
  verifyRun,
} from "../password-runtime/acceptance.mjs";
import {
  captureSyncStep,
  summarizeJournal,
  summarizePasswordState,
  SYNC_PASSWORD_STEPS,
  validateSyncAcceptance,
  verifySyncRun,
} from "../password-runtime/sync-acceptance.mjs";
import {writeLinuxArtifactReceipt} from "./linux-artifact-fixture.mjs";

const credentialKey = `credential/v2/${"c".repeat(64)}`;
const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);

function state(revision, fingerprint, deleted, sequence = revision) {
  return {
    schema_version: 6,
    identity_schema: "password-form-unique-key-v2",
    verified_sequence: String(sequence),
    credentials: {
      [credentialKey]: {
        fingerprint,
        remote_seq: String(sequence),
        revision: String(revision),
        deleted,
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
    payload: deleted ? {} : {
      format: "chromium-password-specifics-v1",
      password_specifics_data_b64: `synthetic-${seq}`,
    },
  });
}

function fixtureEvidence(runNonce) {
  return {
    schema_version: 2,
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
    run_nonce: runNonce,
  };
}

test("private receipt binds public UI evidence to exact revisions, tombstone, and no-op restarts", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-sync-run-"));
  try {
    const artifact = path.join(
      root, "helium-passwords-linux-x86_64", "runtime", "helium-wrapper");
    const screenshot = path.join(root, "screen.png");
    const runRoot = path.join(root, "acceptance");
    const statePath = path.join(root, "password-state.json");
    const journalPath = path.join(root, "records.jsonl");
    const evidencePath = path.join(root, "fixture-evidence.json");
    await fsp.mkdir(path.dirname(artifact), {recursive: true});
    await fsp.writeFile(artifact, "synthetic browser artifact", {mode: 0o700});
    await fsp.writeFile(screenshot, PNG, {mode: 0o600});
    const artifactReceipt = await writeLinuxArtifactReceipt(root, artifact);
    const publicRun = await initializeRun({
      artifact, artifactReceipt, output: runRoot, platform: "linux",
    });
    const snapshots = {
      saved_store: {state: state(1, "1".repeat(64), false), journal: `${record(1, 1, false)}\n`},
      saved_restart_autofill: {state: state(1, "1".repeat(64), false), journal: `${record(1, 1, false)}\n`},
      updated_store: {
        state: state(2, "2".repeat(64), false, 2),
        journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n`,
      },
      updated_restart_autofill: {
        state: state(2, "2".repeat(64), false, 2),
        journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n`,
      },
      deleted_store: {
        state: state(3, "", true, 3),
        journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n${record(3, 3, true)}\n`,
      },
      deleted_restart_empty: {
        state: state(3, "", true, 3),
        journal: `${record(1, 1, false)}\n${record(2, 2, false)}\n${record(3, 3, true)}\n`,
      },
    };
    for (const step of NATIVE_PASSWORD_STEPS) {
      await captureStep({runRoot, step, screenshot});
      const snapshot = snapshots[step];
      if (snapshot) {
        await fsp.writeFile(statePath, `${JSON.stringify(snapshot.state)}\n`, {mode: 0o600});
        await fsp.writeFile(journalPath, snapshot.journal, {mode: 0o600});
        await captureSyncStep({
          runRoot,
          step,
          passwordState: statePath,
          journal: journalPath,
        });
      }
    }
    await fsp.writeFile(
      evidencePath,
      `${JSON.stringify(fixtureEvidence(publicRun.run_nonce))}\n`,
      {mode: 0o600},
    );
    await verifyRun({runRoot, fixtureEvidence: evidencePath});
    const publicReceiptPath = path.join(runRoot, "receipt.json");
    const publicReceipt = JSON.parse(await fsp.readFile(publicReceiptPath, "utf8"));
    assert.equal(publicReceipt.schema_version, 2);
    assert.equal(publicReceipt.run_nonce, publicRun.run_nonce);
    await fsp.writeFile(publicReceiptPath, `${JSON.stringify({
      ...publicReceipt,
      run_nonce: "f".repeat(64),
    })}\n`, {mode: 0o600});
    await assert.rejects(
      verifySyncRun({runRoot, fixtureEvidence: evidencePath}),
      /public acceptance receipt does not match|acceptance nonce/,
    );
    await fsp.writeFile(publicReceiptPath, `${JSON.stringify(publicReceipt)}\n`, {mode: 0o600});
    const receipt = await verifySyncRun({runRoot, fixtureEvidence: evidencePath});
    assert.equal(receipt.result, "passed");
    assert.equal(receipt.schema_version, 3);
    assert.equal(receipt.run_nonce, publicRun.run_nonce);
    assert.equal(receipt.saved_revision, "1");
    assert.equal(receipt.updated_revision, "2");
    assert.equal(receipt.tombstone_revision, "3");
    assert.equal((await fsp.stat(path.join(runRoot, "sync-receipt.json"))).mode & 0o777, 0o600);

    const persistedPublicRun = JSON.parse(await fsp.readFile(path.join(runRoot, "run.json"), "utf8"));
    const syncRun = JSON.parse(await fsp.readFile(path.join(runRoot, "sync-run.json"), "utf8"));
    assert.equal(syncRun.schema_version, 3);
    assert.equal(syncRun.run_nonce, persistedPublicRun.run_nonce);
    assert.deepEqual(syncRun.captures.map(capture => capture.step), SYNC_PASSWORD_STEPS);
    const corrupted = structuredClone(syncRun);
    corrupted.captures.find(item => item.step === "saved_restart_autofill").journal.sha256 = "f".repeat(64);
    assert.throws(() => validateSyncAcceptance(corrupted, persistedPublicRun),
      /summaries do not derive|unchanged restart/);
    assert.throws(() => validateSyncAcceptance({
      ...syncRun,
      run_nonce: "e".repeat(64),
    }, persistedPublicRun), /different public acceptance nonce/);
  } finally {
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("Sync metadata must be captured at its matching public UI step", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "helium-password-sync-binding-"));
  try {
    const artifact = path.join(
      root, "helium-passwords-linux-x86_64", "runtime", "helium-wrapper");
    const screenshot = path.join(root, "screen.png");
    const runRoot = path.join(root, "acceptance");
    const statePath = path.join(root, "password-state.json");
    const journalPath = path.join(root, "records.jsonl");
    await fsp.mkdir(path.dirname(artifact), {recursive: true});
    await fsp.writeFile(artifact, "synthetic browser artifact", {mode: 0o700});
    await fsp.writeFile(screenshot, PNG, {mode: 0o600});
    await fsp.writeFile(statePath, `${JSON.stringify(state(1, "1".repeat(64), false))}\n`, {mode: 0o600});
    await fsp.writeFile(journalPath, `${record(1, 1, false)}\n`, {mode: 0o600});
    const artifactReceipt = await writeLinuxArtifactReceipt(root, artifact);
    await initializeRun({
      artifact, artifactReceipt, output: runRoot, platform: "linux",
    });
    for (const step of ["settings_entry", "save_prompt", "saved_store", "suggestions"]) {
      await captureStep({runRoot, step, screenshot});
    }
    await assert.rejects(captureSyncStep({
      runRoot,
      step: "saved_store",
      passwordState: statePath,
      journal: journalPath,
    }), /immediately after its public UI capture/);
  } finally {
    await fsp.rm(root, {recursive: true, force: true});
  }
});

test("private metadata parsers reject plaintext-shaped or unexpected fields", async () => {
  assert.throws(() => summarizePasswordState({
    schema_version: 6,
    identity_schema: "password-form-unique-key-v2",
    verified_sequence: "1",
    credentials: {"https://secret.example/user": {}},
  }), /invalid credential key|field inventory/);
  assert.throws(() => summarizeJournal(`${JSON.stringify({
    seq: "1",
    kind: "passwords",
    key: credentialKey,
    revision: "1",
    deleted: false,
    device_id: "d",
    payload: {
      format: "chromium-password-specifics-v1",
      password_specifics_data_b64: "synthetic",
    },
    password: "forbidden",
  })}\n`), /unexpected field inventory/);
  const source = await fsp.readFile(new URL("../password-runtime/sync-acceptance.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(source, /passwordsPrivate|AddLogin|UpdateLogin|load-extension|cdp-password-sync/);
});
