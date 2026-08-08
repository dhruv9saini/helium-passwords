#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";

const HASH = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const JOB = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const TIMESTAMP = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

const FILES = Object.freeze([
  "SHA256SUMS",
  "build-operator.sh",
  "build.ninja",
  "build_ai_skills.mjs",
  "capture-tool.sh",
  "chromium-commit.txt",
  "deployment-receipt-tool.sh",
  "finalizer-tool.sh",
  "full-graph-audit-tool.mjs",
  "full-targets-query.txt",
  "generate_css.gni",
  "generate_css_js_files.js",
  "boundary-receipt.env",
  "ninja-query.txt",
  "ninja-binary",
  "ninja-shim",
  "ninja-version.txt",
  "packaging-tool.sh",
  "platform-commit.txt",
  "platform-shared.sh",
  "product-commit.txt",
  "receipt.env",
  "repair-tool.sh",
  "toolchain.ninja",
]);

const RECEIPT_FIELDS = Object.freeze([
  "ai_skill_action_present",
  "arch",
  "build_ai_skills_sha256",
  "build_ninja_sha256",
  "build_operator_sha256",
  "capture_tool_sha256",
  "captured_at",
  "chromium_commit",
  "css_action_edges",
  "css_action_edges_without_tsconfig",
  "full_targets",
  "full_targets_query_sha256",
  "full_graph_audit_tool_sha256",
  "generate_css_gni_sha256",
  "generate_css_js_sha256",
  "graph_validation",
  "helium_core_commit",
  "helium_passwords_commit",
  "helium_sync_commit",
  "job",
  "boundary_receipt_sha256",
  "deployment_receipt_tool_sha256",
  "finalizer_tool_sha256",
  "ninja_query_sha256",
  "ninja_binary_sha256",
  "ninja_shim_sha256",
  "ninja_version_sha256",
  "node_version",
  "packaging_tool_sha256",
  "platform_commit",
  "platform_shared_sha256",
  "product",
  "repair_tool_sha256",
  "schema",
  "target",
  "toolchain_ninja_sha256",
  "ui_css_outputs_materialized_before_full_build",
  "ui_css_phony_orders_all_outputs",
  "ui_downstream_orders_css_phony",
]);

const FRESH_BOUNDARY_FIELDS = Object.freeze([
  "ai_skill_action_present",
  "boundary_epoch",
  "build_ai_skills_sha256",
  "build_ninja_sha256",
  "css_action_edges",
  "css_action_edges_without_tsconfig",
  "full_targets",
  "generate_css_gni_sha256",
  "generate_css_js_sha256",
  "graph_validation",
  "job",
  "ninja_query_sha256",
  "node_version",
  "schema",
  "source_root",
  "toolchain_ninja_sha256",
  "ui_css_outputs_materialized_before_full_build",
  "ui_css_phony_orders_all_outputs",
  "ui_downstream_orders_css_phony",
  "validated_at",
]);

const REPAIR_BOUNDARY_FIELDS = Object.freeze([
  ...FRESH_BOUNDARY_FIELDS,
  "build_completed_at",
  "build_exit_code",
  "build_started_at",
  "failure_artifact_published",
  "failure_broad_css_rule_edges",
  "failure_broad_css_rule_edges_without_tsconfig",
  "failure_build_ninja_sha256",
  "failure_devtools_generate_css_edges",
  "failure_devtools_generate_css_edges_without_tsconfig",
  "failure_duration_seconds",
  "failure_exit_code",
  "failure_finished_at",
  "failure_ninja_shim_sha256",
  "failure_operator_sha256",
  "failure_receipt_sha256",
  "failure_result",
  "failure_root_cause",
  "failure_source_commit",
  "failure_toolchain_ninja_sha256",
  "failure_workspace_preserved",
  "recovery_mode",
  "repair_preflight_sha256",
  "repair_tool_sha256",
]);

const NODE_REPAIR_BOUNDARY_FIELDS = Object.freeze([
  ...REPAIR_BOUNDARY_FIELDS,
  "first_repair_preflight_sha256",
  "first_repair_failure_sha256",
  "first_repair_build_started_at",
  "first_repair_build_completed_at",
  "first_repair_build_exit_code",
  "node_failure_log_sha256",
  "first_continuation_log_sha256",
  "previous_node_repair_action_output_sha256",
  "node_failure_root_cause",
  "node_repair_action",
  "node_repair_action_output",
  "node_repair_action_output_sha256",
  "node_repair_python_wrapper_sha256",
  "node_repair_ninja_log_before_sha256",
  "node_repair_ninja_log_after_sha256",
  "node_repair_started_at",
  "node_repair_completed_at",
]);

const HASH_BINDINGS = Object.freeze({
  build_ninja_sha256: "build.ninja",
  toolchain_ninja_sha256: "toolchain.ninja",
  generate_css_gni_sha256: "generate_css.gni",
  generate_css_js_sha256: "generate_css_js_files.js",
  build_ai_skills_sha256: "build_ai_skills.mjs",
  platform_shared_sha256: "platform-shared.sh",
  build_operator_sha256: "build-operator.sh",
  ninja_shim_sha256: "ninja-shim",
  ninja_binary_sha256: "ninja-binary",
  ninja_version_sha256: "ninja-version.txt",
  ninja_query_sha256: "ninja-query.txt",
  full_targets_query_sha256: "full-targets-query.txt",
  boundary_receipt_sha256: "boundary-receipt.env",
  capture_tool_sha256: "capture-tool.sh",
  packaging_tool_sha256: "packaging-tool.sh",
  deployment_receipt_tool_sha256: "deployment-receipt-tool.sh",
  finalizer_tool_sha256: "finalizer-tool.sh",
  full_graph_audit_tool_sha256: "full-graph-audit-tool.mjs",
  repair_tool_sha256: "repair-tool.sh",
});

function exactKeys(value, expected, label) {
  const actual = [...value.keys()].sort();
  if (JSON.stringify(actual) !== JSON.stringify([...expected].sort())) {
    throw new Error(`${label} has an unexpected field inventory`);
  }
}

function parseEnv(raw, expected, label) {
  const values = new Map();
  for (const line of raw.split("\n")) {
    if (!line) continue;
    const separator = line.indexOf("=");
    const key = line.slice(0, separator);
    const value = line.slice(separator + 1);
    if (separator < 1 || !value || values.has(key) || /[\r\n\0]/.test(value)) {
      throw new Error(`${label} is malformed`);
    }
    values.set(key, value);
  }
  exactKeys(values, expected, label);
  return values;
}

async function sha256File(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function regularFile(file, label, maximum = 1024 * 1024 * 1024) {
  const resolved = path.resolve(file);
  const info = await fsp.lstat(resolved);
  if (!info.isFile() || info.isSymbolicLink() || info.size < 1 ||
      info.size > maximum || (info.mode & 0o077) !== 0) {
    throw new Error(`${label} must be a private nonempty regular file`);
  }
  return {resolved, info};
}

function requireCommit(value, label) {
  if (!COMMIT.test(value || "")) throw new Error(`${label} is not a full commit`);
  return value;
}

function requireHash(value, label) {
  if (!HASH.test(value || "")) throw new Error(`${label} is not a SHA-256 value`);
  return value;
}

function sameGraphSemantics(values, label) {
  if (values.get("node_version") !== "v22.14.0" ||
      values.get("full_targets") !== "chrome,chromedriver" ||
      !/^[1-9][0-9]*$/.test(values.get("css_action_edges") || "") ||
      values.get("css_action_edges_without_tsconfig") !== "0" ||
      values.get("ui_css_outputs_materialized_before_full_build") !== "false" ||
      values.get("ui_css_phony_orders_all_outputs") !== "true" ||
      values.get("ui_downstream_orders_css_phony") !== "true" ||
      values.get("ai_skill_action_present") !== "true" ||
      values.get("graph_validation") !== "passed") {
    throw new Error(`${label} does not prove the complete Node 22 graph boundary`);
  }
}

function oneBuildLine(lines, prefix, label) {
  const matches = lines.filter(line => line.startsWith(prefix));
  if (matches.length !== 1) {
    throw new Error(`generated Linux graph has ${matches.length} ${label} edges`);
  }
  return matches[0];
}

function outputsBeforeRule(line, label) {
  const separator = line.indexOf(": ");
  if (!line.startsWith("build ") || separator < 7) {
    throw new Error(`generated Linux graph has a malformed ${label} edge`);
  }
  return new Set(line.slice(6, separator).split(/ +/).filter(Boolean));
}

export async function auditGeneratedLinuxGraph({
  toolchainPath,
  queryPath,
  outDir,
  requireUnmaterialized = false,
}) {
  const toolchain = await fsp.readFile(path.resolve(toolchainPath), "utf8");
  const lines = toolchain.split(/\r?\n/);
  const devtoolsPrefix = "build gen/third_party/devtools-frontend/src/";
  const cssRule = "_css_files___build_toolchain_linux_clang_x64__rule";
  const cssEdges = lines.filter(line =>
    line.startsWith(devtoolsPrefix) && line.includes(cssRule));
  if (cssEdges.length < 1) {
    throw new Error("generated Linux graph has no scoped DevTools CSS actions");
  }
  const cssEdgesWithoutTsconfig = cssEdges.filter(line => {
    const separator = line.indexOf(": ");
    return separator < 7 || !line.slice(6, separator).split(/ +/)
      .some(output => output.endsWith("-tsconfig.json"));
  });
  if (cssEdgesWithoutTsconfig.length !== 0) {
    throw new Error("generated Linux graph has a scoped DevTools CSS action without tsconfig output");
  }

  const uiPrefix = "gen/third_party/devtools-frontend/src/front_end/ui/kit";
  const uiPhony = "phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files";
  const expectedOutputs = [
    `${uiPrefix}/css_files-tsconfig.json`,
    `${uiPrefix}/cards/card.css.js`,
    `${uiPrefix}/icons/icon.css.js`,
    `${uiPrefix}/link/link.css.js`,
  ];
  const uiCssLine = oneBuildLine(lines,
    `build ${uiPrefix}/css_files-tsconfig.json `, "ui/kit CSS");
  const uiCssOutputs = outputsBeforeRule(uiCssLine, "ui/kit CSS");
  const uiPhonyLine = oneBuildLine(lines,
    `build ${uiPhony}: phony `, "ui/kit CSS phony");
  const downstreamLine = oneBuildLine(lines,
    `build ${uiPrefix}/devtools_entrypoint-bundle-tsconfig-tsconfig.json `,
    "ui/kit downstream");
  for (const output of expectedOutputs) {
    if (!uiCssOutputs.has(output) || !uiPhonyLine.split(/ +/).includes(output)) {
      throw new Error(`generated Linux graph does not bind ui/kit output ${output}`);
    }
  }
  if (!downstreamLine.split(/ +/).includes(uiPhony)) {
    throw new Error("generated Linux graph does not order ui/kit downstream work after CSS");
  }
  const aiOutput = "gen/third_party/devtools-frontend/src/front_end/models/ai_assistance/skills/styling.skill.js";
  oneBuildLine(lines, `build ${aiOutput}: `, "AI skill");

  const query = await fsp.readFile(path.resolve(queryPath), "utf8");
  if (!query.includes(`${uiPrefix}/css_files-tsconfig.json`) ||
      !query.includes(`${uiPrefix}/devtools_entrypoint-bundle-tsconfig-tsconfig.json`) ||
      !query.includes(uiPhony) || !query.includes("outputs:")) {
    throw new Error("generated Linux graph query lost its ui/kit dependency proof");
  }
  if (requireUnmaterialized) {
    if (!outDir) throw new Error("pre-build generated graph audit requires an output directory");
    for (const output of expectedOutputs) {
      try {
        await fsp.lstat(path.join(path.resolve(outDir), output));
        throw new Error(`generated CSS output predates retained repair: ${output}`);
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
    }
  }
  return {
    cssActionEdges: cssEdges.length,
    cssActionEdgesWithoutTsconfig: cssEdgesWithoutTsconfig.length,
    uiCssOutputsMaterializedBeforeFullBuild: false,
    uiCssPhonyOrdersAllOutputs: true,
    uiDownstreamOrdersCssPhony: true,
    aiSkillActionPresent: true,
  };
}

export async function auditLinuxFullGraphEvidence(directory, expected = {}) {
  const root = path.resolve(directory);
  const rootInfo = await fsp.lstat(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink() ||
      await fsp.realpath(root) !== root || (rootInfo.mode & 0o077) !== 0) {
    throw new Error("Linux full-graph evidence must be a private canonical directory");
  }
  const entries = await fsp.readdir(root, {withFileTypes: true});
  if (entries.some(entry => !entry.isFile() || entry.isSymbolicLink()) ||
      JSON.stringify(entries.map(entry => entry.name).sort()) !==
        JSON.stringify([...FILES].sort())) {
    throw new Error("Linux full-graph evidence has an invalid file inventory");
  }
  for (const name of FILES) {
    await regularFile(path.join(root, name), `Linux full-graph ${name}`);
  }

  const inventoryPath = path.join(root, "SHA256SUMS");
  const inventoryRaw = await fsp.readFile(inventoryPath, "utf8");
  const inventory = new Map();
  for (const line of inventoryRaw.split("\n")) {
    if (!line) continue;
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$/.exec(line);
    if (!match || match[2] === "SHA256SUMS" || inventory.has(match[2])) {
      throw new Error("Linux full-graph checksum inventory is malformed");
    }
    inventory.set(match[2], match[1]);
  }
  const payload = FILES.filter(name => name !== "SHA256SUMS").sort();
  if (JSON.stringify([...inventory.keys()].sort()) !== JSON.stringify(payload)) {
    throw new Error("Linux full-graph checksum inventory is incomplete");
  }
  const fileSha256 = {};
  for (const name of payload) {
    fileSha256[name] = await sha256File(path.join(root, name));
    if (fileSha256[name] !== inventory.get(name)) {
      throw new Error(`Linux full-graph file changed after capture: ${name}`);
    }
  }

  const receiptRaw = await fsp.readFile(path.join(root, "receipt.env"), "utf8");
  const receipt = parseEnv(receiptRaw, RECEIPT_FIELDS,
    "Linux full-graph receipt");
  if (receipt.get("schema") !== "helium-linux-full-graph-evidence-v3" ||
      receipt.get("product") !== "helium-sync" ||
      receipt.get("arch") !== "x86_64" ||
      receipt.get("target") !== "linux-x86_64" ||
      !JOB.test(receipt.get("job") || "") ||
      !TIMESTAMP.test(receipt.get("captured_at") || "") ||
      !Number.isFinite(Date.parse(receipt.get("captured_at")))) {
    throw new Error("Linux full-graph receipt identity is invalid");
  }
  sameGraphSemantics(receipt, "Linux full-graph receipt");
  const generated = await auditGeneratedLinuxGraph({
    toolchainPath: path.join(root, "toolchain.ninja"),
    queryPath: path.join(root, "ninja-query.txt"),
  });
  if (String(generated.cssActionEdges) !== receipt.get("css_action_edges") ||
      String(generated.cssActionEdgesWithoutTsconfig) !==
        receipt.get("css_action_edges_without_tsconfig")) {
    throw new Error("Linux full-graph receipt does not match the scoped DevTools graph audit");
  }
  for (const field of [
    "helium_sync_commit", "helium_passwords_commit", "helium_core_commit",
    "chromium_commit", "platform_commit",
  ]) requireCommit(receipt.get(field), `Linux full-graph ${field}`);
  for (const [field, name] of Object.entries(HASH_BINDINGS)) {
    if (requireHash(receipt.get(field), `Linux full-graph ${field}`) !==
        fileSha256[name]) {
      throw new Error(`Linux full-graph receipt does not bind ${name}`);
    }
  }

  const boundaryRaw = await fsp.readFile(
    path.join(root, "boundary-receipt.env"), "utf8");
  const boundarySchemaLines = boundaryRaw.split("\n")
    .filter(line => line.startsWith("schema="));
  if (boundarySchemaLines.length !== 1) {
    throw new Error("Linux full-graph boundary schema is malformed");
  }
  const boundarySchema = boundarySchemaLines[0].slice("schema=".length);
  const boundaryFields = boundarySchema === "helium-fresh-full-graph-boundary-v1"
    ? FRESH_BOUNDARY_FIELDS
    : boundarySchema === "helium-retained-full-graph-repair-boundary-v1"
      ? REPAIR_BOUNDARY_FIELDS
      : boundarySchema === "helium-retained-full-graph-node-repair-boundary-v1"
        ? NODE_REPAIR_BOUNDARY_FIELDS
      : null;
  if (!boundaryFields) throw new Error("Linux full-graph boundary schema is unsupported");
  const boundary = parseEnv(boundaryRaw, boundaryFields,
    "Linux full-graph boundary receipt");
  if (boundary.get("job") !== receipt.get("job") ||
      !path.isAbsolute(boundary.get("source_root") || "") ||
      !/^[1-9][0-9]*$/.test(boundary.get("boundary_epoch") || "") ||
      !Number.isFinite(Date.parse(boundary.get("validated_at"))) ||
      Date.parse(boundary.get("validated_at")) > Date.parse(receipt.get("captured_at"))) {
    throw new Error("Linux full-graph boundary identity is invalid");
  }
  sameGraphSemantics(boundary, "Linux full-graph boundary receipt");
  for (const field of [
    "build_ninja_sha256", "toolchain_ninja_sha256",
    "generate_css_gni_sha256", "generate_css_js_sha256",
    "build_ai_skills_sha256", "ninja_query_sha256",
  ]) {
    requireHash(boundary.get(field), `Linux full-graph boundary ${field}`);
    if (boundary.get(field) !== receipt.get(field)) {
      throw new Error(`boundary and captured Linux full-graph receipts disagree on ${field}`);
    }
  }
  if (boundarySchema === "helium-retained-full-graph-repair-boundary-v1" ||
      boundarySchema ===
        "helium-retained-full-graph-node-repair-boundary-v1") {
    for (const field of [
      "failure_receipt_sha256", "failure_operator_sha256",
      "failure_ninja_shim_sha256", "failure_build_ninja_sha256",
      "failure_toolchain_ninja_sha256", "repair_preflight_sha256",
      "repair_tool_sha256",
    ]) requireHash(boundary.get(field), `retained repair ${field}`);
    for (const field of ["failure_source_commit"]) {
      requireCommit(boundary.get(field), `retained repair ${field}`);
    }
    if (boundary.get("failure_source_commit") !== receipt.get("helium_sync_commit") ||
        boundary.get("failure_operator_sha256") !== receipt.get("build_operator_sha256") ||
        boundary.get("failure_ninja_shim_sha256") !== receipt.get("ninja_shim_sha256") ||
        boundary.get("failure_build_ninja_sha256") !== receipt.get("build_ninja_sha256") ||
        boundary.get("failure_toolchain_ninja_sha256") !== receipt.get("toolchain_ninja_sha256") ||
        boundary.get("repair_tool_sha256") !== receipt.get("repair_tool_sha256") ||
        boundary.get("failure_devtools_generate_css_edges") !==
          receipt.get("css_action_edges") ||
        boundary.get("failure_devtools_generate_css_edges_without_tsconfig") !== "0" ||
        !/^[1-9][0-9]*$/.test(boundary.get("failure_broad_css_rule_edges") || "") ||
        !/^[1-9][0-9]*$/.test(
          boundary.get("failure_broad_css_rule_edges_without_tsconfig") || "") ||
        Number(boundary.get("failure_broad_css_rule_edges")) <=
          Number(boundary.get("failure_devtools_generate_css_edges")) ||
        boundary.get("failure_root_cause") !==
          "graph_gate_counted_unrelated_preprocess_html_css_rules_as_devtools_generate_css_actions" ||
        boundary.get("failure_workspace_preserved") !== "true" ||
        boundary.get("failure_artifact_published") !== "false" ||
        boundary.get("failure_result") !== "failure" ||
        boundary.get("failure_exit_code") !== "1" ||
        !["retained-workspace-after-pre-ninja-graph-gate-failure",
          "retained-workspace-after-node22-mts-terminal-failure"]
          .includes(boundary.get("recovery_mode")) ||
        boundary.get("build_exit_code") !== "0" ||
        !/^[1-9][0-9]*$/.test(boundary.get("failure_duration_seconds") || "") ||
        !Number.isFinite(Date.parse(boundary.get("failure_finished_at"))) ||
        !TIMESTAMP.test(boundary.get("build_started_at") || "") ||
        !TIMESTAMP.test(boundary.get("build_completed_at") || "") ||
        Date.parse(boundary.get("build_started_at")) >=
          Date.parse(boundary.get("build_completed_at"))) {
      throw new Error("retained Linux graph repair provenance is invalid");
    }
    if (boundarySchema ===
        "helium-retained-full-graph-node-repair-boundary-v1") {
      for (const field of [
        "first_repair_preflight_sha256", "first_repair_failure_sha256",
        "node_failure_log_sha256", "first_continuation_log_sha256",
        "previous_node_repair_action_output_sha256",
        "node_repair_action_output_sha256",
        "node_repair_python_wrapper_sha256",
        "node_repair_ninja_log_before_sha256",
        "node_repair_ninja_log_after_sha256",
      ]) requireHash(boundary.get(field), `retained Node repair ${field}`);
      if (boundary.get("first_repair_build_exit_code") !== "1" ||
          boundary.get("node_failure_root_cause") !==
            "node22_unknown_mts_extension_in_helium_onboarding_localized_strings" ||
          boundary.get("node_repair_action") !==
            "unchanged_ninja_action_with_scoped_python_injection" ||
          boundary.get("node_repair_action_output") !==
            "gen/components/helium_onboarding/helium_onboarding_localized_strings.h" ||
          boundary.get("recovery_mode") !==
            "retained-workspace-after-node22-mts-terminal-failure" ||
          boundary.get("node_repair_ninja_log_before_sha256") ===
            boundary.get("node_repair_ninja_log_after_sha256") ||
          !TIMESTAMP.test(boundary.get("first_repair_build_started_at") || "") ||
          !TIMESTAMP.test(boundary.get("first_repair_build_completed_at") || "") ||
          !TIMESTAMP.test(boundary.get("node_repair_started_at") || "") ||
          !TIMESTAMP.test(boundary.get("node_repair_completed_at") || "") ||
          Date.parse(boundary.get("first_repair_build_started_at")) >=
            Date.parse(boundary.get("first_repair_build_completed_at")) ||
          Date.parse(boundary.get("node_repair_started_at")) >
            Date.parse(boundary.get("node_repair_completed_at")) ||
          Date.parse(boundary.get("node_repair_completed_at")) >
            Date.parse(boundary.get("build_started_at"))) {
        throw new Error("retained Linux Node repair provenance is invalid");
      }
    }
  }
  const query = await fsp.readFile(path.join(root, "ninja-query.txt"), "utf8");
  if (!query.includes("ui/kit/css_files-tsconfig.json") ||
      !query.includes("ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json") ||
      !query.includes("phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files") ||
      !query.includes("outputs:")) {
    throw new Error("Linux full-graph validation query lost its CSS dependency proof");
  }
  const fullTargetsQuery = await fsp.readFile(
    path.join(root, "full-targets-query.txt"), "utf8");
  if (!/^chrome:\r?$/m.test(fullTargetsQuery) ||
      !/^chromedriver:\r?$/m.test(fullTargetsQuery)) {
    throw new Error("Linux full-graph query does not contain both complete targets");
  }
  const ninjaVersion = await fsp.readFile(
    path.join(root, "ninja-version.txt"), "utf8");
  if (!/^[A-Za-z0-9._+-]+\n$/.test(ninjaVersion)) {
    throw new Error("Linux full-graph Ninja version evidence is invalid");
  }

  const concreteCommits = {
    sourceCommit: (await fsp.readFile(path.join(root, "product-commit.txt"), "utf8")).trim(),
    chromiumCommit: (await fsp.readFile(path.join(root, "chromium-commit.txt"), "utf8")).trim(),
    platformCommit: (await fsp.readFile(path.join(root, "platform-commit.txt"), "utf8")).trim(),
  };
  requireCommit(concreteCommits.sourceCommit, "full-graph product commit");
  requireCommit(concreteCommits.chromiumCommit, "full-graph Chromium commit");
  requireCommit(concreteCommits.platformCommit, "full-graph platform commit");
  if (concreteCommits.sourceCommit !== receipt.get("helium_sync_commit") ||
      concreteCommits.chromiumCommit !== receipt.get("chromium_commit") ||
      concreteCommits.platformCommit !== receipt.get("platform_commit")) {
    throw new Error("Linux full-graph concrete checkout commits disagree with its receipt");
  }

  const expectedFields = {
    job: "job",
    sourceCommit: "helium_sync_commit",
    passwordsCommit: "helium_passwords_commit",
    coreCommit: "helium_core_commit",
    chromiumCommit: "chromium_commit",
    platformCommit: "platform_commit",
  };
  for (const [input, field] of Object.entries(expectedFields)) {
    if (expected[input] !== undefined && expected[input] !== receipt.get(field)) {
      throw new Error(`Linux full-graph ${field} does not match the admitted build`);
    }
  }
  return {
    root,
    receipt: Object.fromEntries(receipt),
    receiptRaw,
    receiptSha256: fileSha256["receipt.env"],
    inventoryRaw,
    inventorySha256: crypto.createHash("sha256").update(inventoryRaw).digest("hex"),
    fileSha256,
  };
}

async function main(argv) {
  if (argv[2] === "generated-prebuild") {
    if (argv.length !== 6) {
      throw new Error("usage: linux-full-graph-audit.mjs generated-prebuild TOOLCHAIN.NINJA NINJA-QUERY OUTPUT-DIRECTORY");
    }
    const generated = await auditGeneratedLinuxGraph({
      toolchainPath: argv[3],
      queryPath: argv[4],
      outDir: argv[5],
      requireUnmaterialized: true,
    });
    process.stdout.write([
      `css_action_edges=${generated.cssActionEdges}`,
      `css_action_edges_without_tsconfig=${generated.cssActionEdgesWithoutTsconfig}`,
      `ui_css_outputs_materialized_before_full_build=${generated.uiCssOutputsMaterializedBeforeFullBuild}`,
      `ui_css_phony_orders_all_outputs=${generated.uiCssPhonyOrdersAllOutputs}`,
      `ui_downstream_orders_css_phony=${generated.uiDownstreamOrdersCssPhony}`,
      `ai_skill_action_present=${generated.aiSkillActionPresent}`,
      "graph_validation=passed",
      "",
    ].join("\n"));
    return;
  }
  if (argv.length !== 3) {
    throw new Error("usage: linux-full-graph-audit.mjs EVIDENCE-DIRECTORY");
  }
  const audited = await auditLinuxFullGraphEvidence(argv[2]);
  process.stdout.write(`${JSON.stringify({
    result: "passed",
    receipt_sha256: audited.receiptSha256,
    inventory_sha256: audited.inventorySha256,
    job: audited.receipt.job,
  })}\n`);
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  main(process.argv).catch(error => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
