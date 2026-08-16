import assert from "node:assert/strict";
import crypto from "node:crypto";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {auditLinuxFullGraphEvidence} from "../linux-full-graph-audit.mjs";
import {writeFullGraphFixture} from "./linux-artifact-fixture.mjs";

const SHA256 = Object.freeze({
  artifact: "5".repeat(64),
  baselineBoundary: "6".repeat(64),
  baselineBrowser: "7".repeat(64),
  deploymentReceipt: "7".repeat(64),
  fullGraphReceipt: "8".repeat(64),
  verificationReceipt: "9".repeat(64),
  correctedBrowser: "a".repeat(64),
  before: "35d0a50bcb4f5eeb86a56133d80f8500c49b8691c7e955c9236753e98c5037a9",
  after: "fb547a2df142dbe6ae5838fcfa172e86b966214e869e6cbe4f876f6e4cb399d0",
  patch: "64e81e3a1315b831f1aa1cb4da54b78bf2082bef7da72c894a9f2f7c29249383",
});

function parseEnv(raw) {
  return new Map(raw.trimEnd().split("\n").map(line => {
    const separator = line.indexOf("=");
    return [line.slice(0, separator), line.slice(separator + 1)];
  }));
}

function serializeEnv(values) {
  return `${[...values].map(([key, value]) =>
    `${key}=${value}`).join("\n")}\n`;
}

async function sha256File(file) {
  return crypto.createHash("sha256").update(await fsp.readFile(file)).digest("hex");
}

async function writePrivate(file, contents) {
  await fsp.writeFile(file, contents, {mode: 0o600});
  await fsp.chmod(file, 0o600);
}

async function refreshIntegrity(graph) {
  const boundaryPath = path.join(graph, "boundary-receipt.env");
  const receiptPath = path.join(graph, "receipt.env");
  const receipt = parseEnv(await fsp.readFile(receiptPath, "utf8"));
  receipt.set("boundary_receipt_sha256", await sha256File(boundaryPath));
  await writePrivate(receiptPath, serializeEnv(receipt));

  const inventoryPath = path.join(graph, "SHA256SUMS");
  const names = (await fsp.readdir(graph))
    .filter(name => name !== "SHA256SUMS").sort();
  const inventory = `${(await Promise.all(names.map(async name =>
    `${await sha256File(path.join(graph, name))}  ${name}`))).join("\n")}\n`;
  await writePrivate(inventoryPath, inventory);
}

async function writeCorrectionBoundary(graph, changes = {}) {
  const boundaryPath = path.join(graph, "boundary-receipt.env");
  const boundary = parseEnv(await fsp.readFile(boundaryPath, "utf8"));
  const values = new Map([
    ...boundary,
    ["schema", "helium-retained-password-generation-correction-boundary-v1"],
    ["baseline_artifact_sha256", SHA256.artifact],
    ["baseline_boundary_sha256", SHA256.baselineBoundary],
    ["baseline_browser_sha256", SHA256.baselineBrowser],
    ["baseline_build_job", "baseline-build-job"],
    ["baseline_deployment_receipt_sha256", SHA256.deploymentReceipt],
    ["baseline_full_graph_receipt_sha256", SHA256.fullGraphReceipt],
    ["baseline_return_job", "baseline-return-job"],
    ["baseline_source_commit", "77ecad17303225cbfdf9043a4bab040f411402b7"],
    ["baseline_source_tree", "f434ae597adc7a4bb297a79e985785c39107e80b"],
    ["baseline_verification_receipt_sha256", SHA256.verificationReceipt],
    ["build_completed_at", "2026-07-19T23:59:00Z"],
    ["build_exit_code", "0"],
    ["build_started_at", "2026-07-19T23:58:00Z"],
    ["corrected_browser_sha256", SHA256.correctedBrowser],
    ["corrected_source_commit", "1".repeat(40)],
    ["corrected_source_tree", "d".repeat(40)],
    ["correction_after_sha256", SHA256.after],
    ["correction_before_sha256", SHA256.before],
    ["correction_patch",
      "patches/helium-passwords/enable-password-generation-without-google-sync.patch"],
    ["correction_patch_sha256", SHA256.patch],
    ["correction_target",
      "components/password_manager/core/browser/password_feature_manager_impl.cc"],
    ["correction_validation", "passed"],
    ["reuse_scope", "one-source-file-existing-completed-graph"],
  ]);
  for (const [key, value] of Object.entries(changes)) values.set(key, value);
  await writePrivate(boundaryPath, serializeEnv(values));
  await refreshIntegrity(graph);
}

test("accepts an exact retained password generation correction", async t => {
  const temporary = await fsp.mkdtemp(
    path.join(os.tmpdir(), "helium-full-graph-correction."));
  t.after(async () => fsp.rm(temporary, {recursive: true, force: true}));
  await fsp.chmod(temporary, 0o700);
  const graph = path.join(temporary, "graph");
  await writeFullGraphFixture(graph);
  await writeCorrectionBoundary(graph);

  const audited = await auditLinuxFullGraphEvidence(graph);
  assert.equal(audited.receipt.job, "synthetic-linux-fixture");
});

for (const [name, changes] of [
  ["mismatched corrected source", {corrected_source_commit: "e".repeat(40)}],
  ["unchanged target file", {correction_after_sha256: SHA256.before}],
  ["reused baseline job", {baseline_return_job: "baseline-build-job"}],
  ["wrong patch", {correction_patch: "patches/helium-passwords/wrong.patch"}],
  ["late completion", {build_completed_at: "2026-07-20T00:00:02Z"}],
]) {
  test(`rejects correction provenance with ${name}`, async t => {
    const temporary = await fsp.mkdtemp(
      path.join(os.tmpdir(), "helium-full-graph-correction."));
    t.after(async () => fsp.rm(temporary, {recursive: true, force: true}));
    await fsp.chmod(temporary, 0o700);
    const graph = path.join(temporary, "graph");
    await writeFullGraphFixture(graph);
    await writeCorrectionBoundary(graph, changes);

    await assert.rejects(auditLinuxFullGraphEvidence(graph),
      /retained password generation correction provenance is invalid/);
  });
}
