import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { auditOriginState } from "../session-state/origin-state-audit.mjs";

function evidence(scope = "synthetic") {
  return {
    schema_version: 1,
    audit_id: "fixture-audit-v1",
    evidence_scope: scope,
    artifact_sha256: "a".repeat(64),
    target_device: "oneplus",
    origins: [{
      origin: "https://fixture.invalid",
      cookie: {
        apply_result: "verified",
        auth_result: "authenticated",
        device_bound_session: "not-observed",
        evidence_ref: "fixture-login-v1",
      },
      state: [{
        kind: "local-storage",
        need: "required",
        adapter: "none",
        result: "not-tested",
        evidence_ref: "fixture-local-storage-v1",
      }],
    }],
  };
}

test("synthetic evidence never creates a concrete portability claim", () => {
  const result = auditOriginState(evidence());
  assert.equal(result.proof_level, "synthetic");
  assert.equal(result.origins[0].cookie_classification, "synthetic-success-case");
  assert.equal(result.origins[0].state[0].classification, "synthetic-required-case");
});

test("disposable evidence scopes success to the exact artifact and destination", () => {
  const input = evidence("disposable-browser");
  const result = auditOriginState(input);
  assert.equal(result.target_device, "oneplus");
  assert.equal(result.artifact_sha256, "a".repeat(64));
  assert.equal(result.origins[0].cookie_classification, "destination-verified");
  assert.equal(result.origins[0].state[0].classification, "required-unsupported");
});

test("device-bound and rejected sessions require observed evidence", () => {
  const input = evidence("disposable-browser");
  input.origins[0].cookie.device_bound_session = "observed";
  assert.equal(auditOriginState(input).origins[0].cookie_classification,
    "device-bound-observed");

  input.origins[0].cookie.device_bound_session = "not-observed";
  input.origins[0].cookie.apply_result = "rejected";
  input.origins[0].cookie.auth_result = "reauth-required";
  assert.equal(auditOriginState(input).origins[0].cookie_classification,
    "reauth-required-observed");

  input.origins[0].cookie.evidence_ref = "";
  assert.throws(() => auditOriginState(input), /evidence_ref/);
});

test("audit accepts origins only and rejects unmodeled secret-bearing fields", () => {
  const input = evidence();
  input.origins[0].origin = "https://fixture.invalid/login?token=secret";
  assert.throws(() => auditOriginState(input), /exact HTTPS origin/);

  const unknown = evidence();
  unknown.origins[0].cookie.cookie_value = "must never be accepted";
  assert.throws(() => auditOriginState(unknown), /unknown or missing field/);

  const inconsistent = evidence();
  inconsistent.origins[0].cookie.apply_result = "not-tested";
  assert.throws(() => auditOriginState(inconsistent), /inconsistent cookie evidence/);
});

test("CLI emits metadata-only classifications from a regular evidence file", t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "helium-origin-audit-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const evidencePath = path.join(directory, "evidence.json");
  const artifactPath = path.join(directory, "artifact.txt");
  fs.writeFileSync(artifactPath, "synthetic disposable artifact\n", { mode: 0o600 });
  const input = evidence();
  input.artifact_sha256 = crypto.createHash("sha256")
    .update(fs.readFileSync(artifactPath)).digest("hex");
  fs.writeFileSync(evidencePath, JSON.stringify(input), { mode: 0o600 });

  const script = fileURLToPath(new URL("../session-state/origin-state-audit.mjs",
    import.meta.url));
  const completed = spawnSync(process.execPath, [script, evidencePath, artifactPath], {
    encoding: "utf8",
  });
  assert.equal(completed.status, 0, completed.stderr);
  assert.deepEqual(JSON.parse(completed.stdout), auditOriginState(input));
  assert.doesNotMatch(completed.stdout, /cookie_value|token|password/i);

  input.artifact_sha256 = "b".repeat(64);
  fs.writeFileSync(evidencePath, JSON.stringify(input), { mode: 0o600 });
  const mismatched = spawnSync(process.execPath, [script, evidencePath, artifactPath], {
    encoding: "utf8",
  });
  assert.notEqual(mismatched.status, 0);
  assert.match(mismatched.stderr, /artifact SHA-256 does not match/);
});
