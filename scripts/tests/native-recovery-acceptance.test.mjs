#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  auditDeviceFinal,
  finalizeDevice,
  verifyRestore,
  verifySnapshot,
} from "../native-recovery/acceptance.mjs";

const sha256 = value =>
  crypto.createHash("sha256").update(value).digest("hex");

async function writePrivate(file, value) {
  const raw = typeof value === "string" ? value : `${JSON.stringify(value)}\n`;
  await fs.writeFile(file, raw, {mode: 0o600});
  return Buffer.from(raw);
}

function stateHash(kind, records) {
  let material = "";
  for (const record of records) {
    let value;
    if (kind === "passwords") {
      value = record.payload;
    } else {
      value = {...record.cookie};
      delete value.creation;
      delete value.last_access;
      delete value.last_update;
    }
    material += `${record.key}\0${sha256(JSON.stringify(value))}\n`;
  }
  return sha256(material);
}

function makeSnapshot(kind, records, device = "d") {
  return {
    schema_version: 1,
    kind,
    format: kind === "passwords"
      ? "chromium-password-specifics-neutral-v1"
      : "chromium-cookie-manager-neutral-v1",
    source_device: device,
    captured_at_windows_us: "13397000000000000",
    record_count: records.length,
    records,
    records_sha256: sha256(JSON.stringify(records)),
    state_sha256: stateHash(kind, records),
  };
}

const passwordRecords = [{
  key: `credential/v2/${"1".repeat(64)}`,
  payload: {
    format: "chromium-password-specifics-data-v1",
    password_specifics_data_b64: "c3ludGhldGlj",
  },
}];

const cookieRecords = [{
  key: "2".repeat(64),
  cookie: {
    creation: "13397000000000000",
    domain: "fixture.invalid",
    expiry: "0",
    http_only: true,
    last_access: "13397000000000000",
    last_update: "13397000000000000",
    name: "fixture",
    path: "/",
    priority: 1,
    same_site: 1,
    secure: true,
    source_port: 443,
    source_scheme: 2,
    source_type: 1,
    value: "synthetic",
  },
}];

test("native recovery evidence binds both browser APIs and both destinations",
  async t => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "helium-native-recovery."));
    await fs.chmod(root, 0o700);
    t.after(() => fs.rm(root, {recursive: true, force: true}));
    const generation = "20260808T010203Z-1234567890abcdef";
    const outputEvidence = {};
    const artifactFile = path.join(root, "helium-artifact.bin");
    await writePrivate(artifactFile, "synthetic returned browser artifact\n");

    for (const [kind, records, api] of [
      ["passwords", passwordRecords, "PasswordStoreInterface"],
      ["cookies", cookieRecords, "network::mojom::CookieManager"],
    ]) {
      const snapshotValue = makeSnapshot(kind, records);
      for (const [suffix, destination] of [
        ["nas", "nas-on-lm"], ["peer", "da-copy"],
      ]) {
        const snapshotFile = path.join(root, `${kind}-${suffix}.json`);
        const snapshotRaw = await writePrivate(snapshotFile, snapshotValue);
        const browserFile = path.join(root, `${kind}-${suffix}-browser.json`);
        await writePrivate(browserFile, {
          schema_version: 1,
          result: "passed",
          kind,
          snapshot_sha256: sha256(snapshotRaw),
          records_sha256: snapshotValue.records_sha256,
          restored_state_sha256: snapshotValue.state_sha256,
          restored_count: records.length,
          browser_api: api,
          completed_at_windows_us: "13397000000000100",
        });
        const profileFile = path.join(root, `${kind}-${suffix}-profile.env`);
        await writePrivate(profileFile,
          `schema_version=3\n` +
          `generation=${generation}\n` +
          `source_device=d\n` +
          `profile_id=native-recovery-default\n` +
          `archive_sha256=${"3".repeat(64)}\n` +
          `source_destination=${destination}\n` +
          `restored_at=2026-08-08T01:04:05Z\n`);
        const evidenceFile = path.join(root, `${kind}-${suffix}-evidence.json`);
        const evidence = await verifyRestore({
          kind,
          device: "d",
          destination,
          snapshot: snapshotFile,
          browserReceipt: browserFile,
          profileReceipt: profileFile,
          artifact: artifactFile,
          output: evidenceFile,
        });
        assert.equal(evidence.result, "passed");
        outputEvidence[`${kind}_${suffix}`] = evidenceFile;
      }
    }

    const finalFile = path.join(root, "final.json");
    const final = await finalizeDevice("d", outputEvidence, finalFile);
    assert.equal(final.result, "passed");
    assert.deepEqual(final.destinations, ["nas-on-lm", "da-copy"]);
    assert.equal((await auditDeviceFinal(finalFile, "d")).artifact_sha256,
      sha256("synthetic returned browser artifact\n"));

    const corruptedFile = path.join(root, "corrupted.json");
    const corrupted = makeSnapshot("passwords", passwordRecords);
    corrupted.records_sha256 = "0".repeat(64);
    await writePrivate(corruptedFile, corrupted);
    await assert.rejects(
      verifySnapshot(corruptedFile, "passwords", "d"),
      /records checksum changed/,
    );
  });
