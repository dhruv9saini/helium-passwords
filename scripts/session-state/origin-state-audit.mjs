#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const ORIGIN_STATE_KINDS = new Set([
  "local-storage",
  "indexed-db",
  "service-worker",
  "cache-storage",
  "other-origin-state",
]);
const OBSERVATIONS = new Set(["not-tested", "observed", "not-observed"]);
const APPLY_RESULTS = new Set(["not-tested", "verified", "rejected"]);
const AUTH_RESULTS = new Set(["not-tested", "authenticated", "reauth-required"]);
const STATE_NEEDS = new Set(["not-tested", "required", "not-required"]);

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} has an unknown or missing field`);
  }
}

function validSlug(value) {
  return typeof value === "string" && /^[a-z0-9][a-z0-9._-]{0,127}$/.test(value);
}

function validateOrigin(value) {
  if (typeof value !== "string") throw new Error("origin must be a string");
  const parsed = new URL(value);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password ||
      parsed.origin !== value || parsed.pathname !== "/" || parsed.search || parsed.hash) {
    throw new Error("origin must be one exact HTTPS origin without credentials or a path");
  }
  return parsed.origin;
}

function classifyCookie(cookie, proofLevel) {
  const concrete = proofLevel === "disposable-browser";
  if (cookie.device_bound_session === "observed") {
    return concrete ? "device-bound-observed" : "synthetic-device-bound-case";
  }
  if (cookie.apply_result === "rejected" || cookie.auth_result === "reauth-required") {
    return concrete ? "reauth-required-observed" : "synthetic-rejection-case";
  }
  if (cookie.apply_result === "verified" && cookie.auth_result === "authenticated") {
    return concrete ? "destination-verified" : "synthetic-success-case";
  }
  if (cookie.apply_result === "verified") return "cookie-only-insufficient";
  return "unknown";
}

function classifyOriginState(state, proofLevel) {
  const concrete = proofLevel === "disposable-browser";
  if (state.need === "not-required") {
    return concrete ? "not-required-observed" : "synthetic-not-required-case";
  }
  if (state.need === "required" && state.adapter === "none") {
    return concrete ? "required-unsupported" : "synthetic-required-case";
  }
  if (state.need === "required" && state.result === "verified") {
    return concrete ? "destination-verified" : "synthetic-success-case";
  }
  if (state.need === "required" && state.result === "rejected") {
    return concrete ? "adapter-rejected-observed" : "synthetic-rejection-case";
  }
  return "unknown";
}

function requireEvidenceReference(value, fields, label) {
  const observed = fields.some(field => field !== "not-tested");
  if (observed !== Boolean(value.evidence_ref)) {
    throw new Error(`${label} evidence_ref must exist exactly when a result was observed`);
  }
  if (value.evidence_ref && !validSlug(value.evidence_ref)) {
    throw new Error(`${label} evidence_ref must be an opaque slug`);
  }
}

export function auditOriginState(input) {
  exactKeys(input, [
    "schema_version", "audit_id", "evidence_scope", "artifact_sha256",
    "target_device", "origins",
  ], "audit");
  if (input.schema_version !== 1 || !validSlug(input.audit_id) ||
      !["synthetic", "disposable-browser"].includes(input.evidence_scope) ||
      !/^[a-f0-9]{64}$/.test(input.artifact_sha256) ||
      !["d", "da", "oneplus"].includes(input.target_device) ||
      !Array.isArray(input.origins) || input.origins.length === 0 || input.origins.length > 100) {
    throw new Error("invalid origin-state audit metadata");
  }

  const seenOrigins = new Set();
  const origins = input.origins.map((item, originIndex) => {
    exactKeys(item, ["origin", "cookie", "state"], `origin ${originIndex}`);
    const origin = validateOrigin(item.origin);
    if (seenOrigins.has(origin)) throw new Error(`duplicate origin: ${origin}`);
    seenOrigins.add(origin);

    exactKeys(item.cookie, [
      "apply_result", "auth_result", "device_bound_session", "evidence_ref",
    ], `cookie ${origin}`);
    if (!APPLY_RESULTS.has(item.cookie.apply_result) ||
        !AUTH_RESULTS.has(item.cookie.auth_result) ||
        !OBSERVATIONS.has(item.cookie.device_bound_session)) {
      throw new Error(`invalid cookie evidence for ${origin}`);
    }
    if ((item.cookie.apply_result === "not-tested" &&
         item.cookie.auth_result !== "not-tested") ||
        (item.cookie.auth_result === "authenticated" &&
         item.cookie.apply_result !== "verified")) {
      throw new Error(`inconsistent cookie evidence for ${origin}`);
    }
    requireEvidenceReference(item.cookie, [
      item.cookie.apply_result,
      item.cookie.auth_result,
      item.cookie.device_bound_session,
    ], `cookie ${origin}`);

    if (!Array.isArray(item.state)) throw new Error(`state ${origin} must be an array`);
    const seenKinds = new Set();
    const state = item.state.map((entry, stateIndex) => {
      exactKeys(entry, ["kind", "need", "adapter", "result", "evidence_ref"],
        `state ${origin} ${stateIndex}`);
      if (!ORIGIN_STATE_KINDS.has(entry.kind) || seenKinds.has(entry.kind) ||
          !STATE_NEEDS.has(entry.need) || !APPLY_RESULTS.has(entry.result) ||
          !(entry.adapter === "none" || validSlug(entry.adapter))) {
        throw new Error(`invalid origin-state evidence for ${origin}`);
      }
      seenKinds.add(entry.kind);
      if (entry.adapter === "none" && entry.result !== "not-tested") {
        throw new Error(`origin state cannot have a result without an adapter: ${origin}`);
      }
      if (entry.need !== "required" &&
          (entry.adapter !== "none" || entry.result !== "not-tested")) {
        throw new Error(`origin state cannot apply an adapter unless required: ${origin}`);
      }
      requireEvidenceReference(entry, [entry.need, entry.result], `state ${origin} ${entry.kind}`);
      return {
        kind: entry.kind,
        classification: classifyOriginState(entry, input.evidence_scope),
        evidence_ref: entry.evidence_ref,
      };
    });
    return {
      origin,
      cookie_classification: classifyCookie(item.cookie, input.evidence_scope),
      cookie_evidence_ref: item.cookie.evidence_ref,
      state,
    };
  });

  return {
    schema_version: 1,
    audit_id: input.audit_id,
    proof_level: input.evidence_scope,
    artifact_sha256: input.artifact_sha256,
    target_device: input.target_device,
    origins,
  };
}

function main() {
  if (process.argv.length !== 4) {
    throw new Error("usage: origin-state-audit.mjs EVIDENCE.json ARTIFACT");
  }
  const [inputPath, artifactPath] = process.argv.slice(2);
  const inputInfo = fs.lstatSync(inputPath);
  if (!inputInfo.isFile() || inputInfo.isSymbolicLink() || inputInfo.size <= 0 ||
      inputInfo.size > 1024 * 1024) {
    throw new Error("evidence must be a nonempty regular file no larger than 1 MiB");
  }
  const artifactInfo = fs.lstatSync(artifactPath);
  if (!artifactInfo.isFile() || artifactInfo.isSymbolicLink() || artifactInfo.size <= 0 ||
      artifactInfo.size > 64 * 1024 * 1024) {
    throw new Error("artifact must be a nonempty regular file no larger than 64 MiB");
  }
  const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
  const actualArtifactHash = crypto.createHash("sha256")
    .update(fs.readFileSync(artifactPath)).digest("hex");
  if (input.artifact_sha256 !== actualArtifactHash) {
    throw new Error("artifact SHA-256 does not match evidence");
  }
  const result = auditOriginState(input);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`origin-state-audit: ${error.message}\n`);
    process.exitCode = 1;
  }
}
