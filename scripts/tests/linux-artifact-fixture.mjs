import crypto from "node:crypto";
import fsp from "node:fs/promises";
import path from "node:path";

const COMMIT = Object.freeze({
  source: "1".repeat(40),
  core: "2".repeat(40),
  chromium: "3".repeat(40),
  platform: "4".repeat(40),
  passwords: "5".repeat(40),
});

const GRAPH_FILES = Object.freeze([
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

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

async function sha256File(file) {
  return sha256(await fsp.readFile(file));
}

async function writePrivate(file, data) {
  await fsp.writeFile(file, data, {mode: 0o600});
  await fsp.chmod(file, 0o600);
}

export async function writeFullGraphFixture(graph) {
  await fsp.mkdir(graph, {recursive: true, mode: 0o700});
  await fsp.chmod(graph, 0o700);
  const prefix = "gen/third_party/devtools-frontend/src/front_end/ui/kit";
  const phony = "phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files";
  const toolchain = [
    `build ${prefix}/css_files-tsconfig.json ${prefix}/cards/card.css.js ${prefix}/icons/icon.css.js ${prefix}/link/link.css.js: _css_files___build_toolchain_linux_clang_x64__rule`,
    `build ${phony}: phony ${prefix}/css_files-tsconfig.json ${prefix}/cards/card.css.js ${prefix}/icons/icon.css.js ${prefix}/link/link.css.js`,
    `build ${prefix}/devtools_entrypoint-bundle-tsconfig-tsconfig.json : synthetic ${phony}`,
    "build gen/third_party/devtools-frontend/src/front_end/models/ai_assistance/skills/styling.skill.js: synthetic",
    "",
  ].join("\n");
  const query = [
    `${prefix}/css_files-tsconfig.json:`,
    `  outputs: ${prefix}/css_files-tsconfig.json`,
    `${prefix}/devtools_entrypoint-bundle-tsconfig-tsconfig.json:`,
    `  input: ${phony}`,
    "",
  ].join("\n");
  const initial = new Map(GRAPH_FILES.map(name => [name, "synthetic fixture\n"]));
  initial.set("toolchain.ninja", toolchain);
  initial.set("ninja-query.txt", query);
  initial.set("full-targets-query.txt", "chrome:\n  outputs: chrome\nchromedriver:\n  outputs: chromedriver\n");
  initial.set("ninja-version.txt", "1.12.1\n");
  initial.set("product-commit.txt", `${COMMIT.source}\n`);
  initial.set("chromium-commit.txt", `${COMMIT.chromium}\n`);
  initial.set("platform-commit.txt", `${COMMIT.platform}\n`);
  for (const [name, contents] of initial) {
    if (name !== "boundary-receipt.env" && name !== "receipt.env") {
      await writePrivate(path.join(graph, name), contents);
    }
  }

  const hash = async name => sha256File(path.join(graph, name));
  const graphValues = {
    build_ninja_sha256: await hash("build.ninja"),
    toolchain_ninja_sha256: await hash("toolchain.ninja"),
    generate_css_gni_sha256: await hash("generate_css.gni"),
    generate_css_js_sha256: await hash("generate_css_js_files.js"),
    build_ai_skills_sha256: await hash("build_ai_skills.mjs"),
    ninja_query_sha256: await hash("ninja-query.txt"),
  };
  const semantics = {
    node_version: "v22.14.0",
    full_targets: "chrome,chromedriver",
    css_action_edges: "1",
    css_action_edges_without_tsconfig: "0",
    ui_css_outputs_materialized_before_full_build: "false",
    ui_css_phony_orders_all_outputs: "true",
    ui_downstream_orders_css_phony: "true",
    ai_skill_action_present: "true",
    graph_validation: "passed",
  };
  const boundary = {
    schema: "helium-fresh-full-graph-boundary-v1",
    job: "synthetic-linux-fixture",
    source_root: "/synthetic/helium/linux-build/src",
    boundary_epoch: "1",
    validated_at: "2026-07-20T00:00:00Z",
    ...graphValues,
    ...semantics,
  };
  await writePrivate(path.join(graph, "boundary-receipt.env"),
    `${Object.entries(boundary).map(([key, value]) => `${key}=${value}`).join("\n")}\n`);

  const hashBindings = {
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
  };
  const receipt = {
    schema: "helium-linux-full-graph-evidence-v3",
    product: "helium-sync",
    arch: "x86_64",
    target: "linux-x86_64",
    job: "synthetic-linux-fixture",
    captured_at: "2026-07-20T00:00:01Z",
    helium_sync_commit: COMMIT.source,
    helium_passwords_commit: COMMIT.passwords,
    helium_core_commit: COMMIT.core,
    chromium_commit: COMMIT.chromium,
    platform_commit: COMMIT.platform,
    ...semantics,
  };
  for (const [field, name] of Object.entries(hashBindings)) {
    receipt[field] = await hash(name);
  }
  await writePrivate(path.join(graph, "receipt.env"),
    `${Object.entries(receipt).map(([key, value]) => `${key}=${value}`).join("\n")}\n`);

  const inventory = `${(await Promise.all([...GRAPH_FILES].sort().map(async name =>
    `${await hash(name)}  ${name}`))).join("\n")}\n`;
  await writePrivate(path.join(graph, "SHA256SUMS"), inventory);
  return {
    receiptSha256: await hash("receipt.env"),
    inventorySha256: sha256(inventory),
    packagingToolSha256: receipt.packaging_tool_sha256,
  };
}

export async function writeLinuxArtifactReceipt(root, artifact) {
  const artifactHash = await sha256File(artifact);
  const bundle = path.join(root, "helium-passwords-linux-x86_64");
  const runtime = path.join(bundle, "runtime");
  const provenance = path.join(bundle, "provenance");
  const browser = path.join(runtime, "helium");
  await fsp.mkdir(runtime, {recursive: true});
  await fsp.mkdir(provenance, {recursive: true});
  await fsp.writeFile(browser, "synthetic browser binary", {mode: 0o700});
  const inventory = path.join(provenance, "runtime.sha256");
  const entries = [artifact, browser].sort();
  const inventoryRaw = `${(await Promise.all(entries.map(async file =>
    `${await sha256File(file)}  ${path.relative(bundle, file)}`))).join("\n")}\n`;
  await writePrivate(inventory, inventoryRaw);
  const graph = await writeFullGraphFixture(path.join(provenance, "full-graph"));
  const receipt = path.join(root, "artifact-receipt.env");
  const graphRelative = "helium-passwords-linux-x86_64/provenance/full-graph";
  await writePrivate(receipt, [
    "schema_version=3",
    "product=helium-sync",
    "platform=linux",
    "arch=x86_64",
    `source_commit=${COMMIT.source}`,
    `helium_core_commit=${COMMIT.core}`,
    "chromium_version=150.0.7871.181",
    `chromium_commit=${COMMIT.chromium}`,
    `platform_commit=${COMMIT.platform}`,
    `bundle=${path.join(root, "bundle.tar.xz")}`,
    `bundle_sha256=${"6".repeat(64)}`,
    `provenance_manifest_sha256=${"7".repeat(64)}`,
    `browser_executable=${path.relative(root, artifact)}`,
    `browser_sha256=${artifactHash}`,
    `runtime_inventory=${path.relative(root, inventory)}`,
    `runtime_inventory_sha256=${sha256(inventoryRaw)}`,
    `full_graph_receipt=${graphRelative}/receipt.env`,
    `full_graph_receipt_sha256=${graph.receiptSha256}`,
    `full_graph_inventory=${graphRelative}/SHA256SUMS`,
    `full_graph_inventory_sha256=${graph.inventorySha256}`,
    "verified_at=synthetic-fixture",
    "",
  ].join("\n"));
  return receipt;
}
