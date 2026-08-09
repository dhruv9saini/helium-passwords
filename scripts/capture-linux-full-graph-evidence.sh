#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "usage: $0 PRODUCT ARCH TARGET BUILD-JOB-ID PLATFORM-CHECKOUT GRAPH-BOUNDARY-RECEIPT NEW-EVIDENCE-DIR" >&2
  exit 64
fi

product=$1
arch=$2
target=$3
job=$4
checkout=$(realpath -e "$5")
boundary=$(realpath -e "$6")
output=$(realpath -m "$7")
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
product_root=$(realpath -e "${HELIUM_PRODUCT_SOURCE_ROOT:-$tool_root}")
source_root="$checkout/build/src"
out="$source_root/out/Default"

[[ "$product" == helium-sync &&
    (("$arch" == x86_64 && "$target" == linux-x86_64) ||
     ("$arch" == arm64 && "$target" == linux-arm64-chroot)) &&
    "$job" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  echo "full-graph capture requires a supported Helium Sync Linux target" >&2
  exit 64
}
[[ -f "$boundary" && ! -L "$boundary" && ! -e "$output" ]] || {
  echo "boundary receipt is unsafe or evidence destination already exists" >&2
  exit 1
}
for tool in awk date find git install mktemp ninja realpath sha256sum sort stat xargs; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
for file in \
  "$out/build.ninja" "$out/toolchain.ninja" \
  "$source_root/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni" \
  "$source_root/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js" \
  "$source_root/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs" \
  "$checkout/scripts/shared.sh"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "missing concrete graph input: $file" >&2; exit 1; }
done
[[ -x "${HELIUM_BUILD_OPERATOR:?missing HELIUM_BUILD_OPERATOR}" &&
    -x "${HELIUM_NINJA_SHIM:?missing HELIUM_NINJA_SHIM}" ]] || {
  echo "full-graph capture requires its exact operator and Ninja shim" >&2
  exit 1
}
real_ninja=$(realpath -e "${HELIUM_REAL_NINJA:-$(command -v ninja)}")
[[ -x "$real_ninja" && "$real_ninja" != "$(realpath -e "$HELIUM_NINJA_SHIM")" ]] || {
  echo "full-graph capture resolved the immutable shim instead of real Ninja" >&2
  exit 1
}

boundary_value() {
  awk -F= -v key="$1" '
    $1 == key {count++; value=substr($0,length(key)+2)}
    END {if (count == 1 && value != "") print value; else exit 1}
  ' "$boundary"
}
boundary_schema=$(boundary_value schema)
[[ "$boundary_schema" == helium-fresh-full-graph-boundary-v1 ||
    "$boundary_schema" == helium-retained-full-graph-repair-boundary-v1 ||
    "$boundary_schema" == helium-retained-full-graph-node-repair-boundary-v1 ]] || {
  echo "unsupported graph boundary receipt" >&2
  exit 1
}
[[ "$(boundary_value job)" == "$job" &&
    "$(boundary_value source_root)" == "$source_root" &&
    "$(boundary_value node_version)" == v22.14.0 &&
    "$(boundary_value full_targets)" == chrome,chromedriver &&
    "$(boundary_value graph_validation)" == passed ]] || {
  echo "graph receipt is not the exact completed full-graph boundary" >&2
  exit 1
}
[[ "$(sha256sum "$out/build.ninja" | awk '{print $1}')" == \
      "$(boundary_value build_ninja_sha256)" &&
    "$(sha256sum "$out/toolchain.ninja" | awk '{print $1}')" == \
      "$(boundary_value toolchain_ninja_sha256)" &&
    "$(sha256sum "$source_root/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni" | awk '{print $1}')" == \
      "$(boundary_value generate_css_gni_sha256)" &&
    "$(sha256sum "$source_root/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js" | awk '{print $1}')" == \
      "$(boundary_value generate_css_js_sha256)" &&
    "$(sha256sum "$source_root/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs" | awk '{print $1}')" == \
      "$(boundary_value build_ai_skills_sha256)" ]] || {
  echo "completed build graph changed after its boundary validation" >&2
  exit 1
}
if [[ "$boundary_schema" == helium-retained-full-graph-node-repair-boundary-v1 ]]; then
  node_repair_output=
  if [[ "$(boundary_value node_repair_action_output)" == \
      gen/components/helium_onboarding/helium_onboarding_localized_strings.h ]]; then
    node_repair_output="$out/$(boundary_value node_repair_action_output)"
  fi
  [[ -n "$node_repair_output" && -f "$node_repair_output" &&
      ! -L "$node_repair_output" &&
      "$(sha256sum "$node_repair_output" | awk '{print $1}')" == \
        "$(boundary_value node_repair_action_output_sha256)" ]] || {
    echo "completed Node repair output changed after boundary validation" >&2
    exit 1
  }
fi

parent=$(dirname "$output")
[[ -d "$parent" && ! -L "$parent" ]] || { echo "evidence parent is invalid" >&2; exit 1; }
temporary=$(mktemp -d "$parent/.full-graph-evidence.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT
chmod 700 "$temporary"

install_file() { install -m 600 "$1" "$temporary/$2"; }
install_file "$boundary" boundary-receipt.env
install_file "$out/build.ninja" build.ninja
install_file "$out/toolchain.ninja" toolchain.ninja
install_file "$source_root/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni" generate_css.gni
install_file "$source_root/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js" generate_css_js_files.js
install_file "$source_root/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs" build_ai_skills.mjs
install_file "$checkout/scripts/shared.sh" platform-shared.sh
install_file "$HELIUM_BUILD_OPERATOR" build-operator.sh
install_file "$HELIUM_NINJA_SHIM" ninja-shim
install_file "$real_ninja" ninja-binary
install_file "$tool_root/scripts/capture-linux-full-graph-evidence.sh" capture-tool.sh
install_file "$tool_root/scripts/package-linux-runtime.sh" packaging-tool.sh
install_file "$tool_root/scripts/write-deployment-artifact-receipt.sh" deployment-receipt-tool.sh
install_file "$tool_root/scripts/finalize-retained-linux-full-graph.sh" finalizer-tool.sh
install_file "$tool_root/scripts/linux-full-graph-audit.mjs" full-graph-audit-tool.mjs
repair_tool=${HELIUM_REPAIR_TOOL:-"$tool_root/scripts/continue-retained-linux-full-graph-failure.sh"}
[[ -x "$repair_tool" && ! -L "$repair_tool" ]] || {
  echo "full-graph repair tool is unsafe" >&2
  exit 1
}
install_file "$repair_tool" repair-tool.sh
"$real_ninja" --version >"$temporary/ninja-version.txt"
chmod 600 "$temporary/ninja-version.txt"
"$real_ninja" -C "$out" -t query \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json \
  >"$temporary/ninja-query.txt"
chmod 600 "$temporary/ninja-query.txt"
[[ "$(sha256sum "$temporary/ninja-query.txt" | awk '{print $1}')" == \
    "$(boundary_value ninja_query_sha256)" ]] || {
  echo "completed Ninja validation query changed after graph validation" >&2
  exit 1
}
"$real_ninja" -C "$out" -t query chrome chromedriver >"$temporary/full-targets-query.txt"
chmod 600 "$temporary/full-targets-query.txt"
printf '%s\n' "$(git -C "$product_root" rev-parse HEAD)" >"$temporary/product-commit.txt"
printf '%s\n' "$(git -C "$source_root" rev-parse HEAD)" >"$temporary/chromium-commit.txt"
printf '%s\n' "$(git -C "$checkout" rev-parse HEAD)" >"$temporary/platform-commit.txt"
chmod 600 "$temporary/"{product-commit,chromium-commit,platform-commit}.txt

source_info=$(HELIUM_PRODUCT_SOURCE_ROOT="$product_root" \
  "$product_root/scripts/linux-product-provenance.sh" "$product" "$arch" "$target")
source_value() {
  awk -F= -v key="$1" '$1 == key {print substr($0,length(key)+2); exit}' \
    <<<"$source_info"
}
[[ "$(source_value source_commit)" == "$(git -C "$product_root" rev-parse HEAD)" &&
    "$(source_value chromium_commit)" == "$(git -C "$source_root" rev-parse HEAD)" &&
    "$(git -C "$checkout" rev-parse HEAD)" == "$(<"$temporary/platform-commit.txt")" ]] || {
  echo "full-graph checkout identities changed during capture" >&2
  exit 1
}
cat >"$temporary/receipt.env" <<EOF
schema=helium-linux-full-graph-evidence-v3
job=$job
product=$product
arch=$arch
target=$target
helium_sync_commit=$(source_value helium_sync_commit)
helium_passwords_commit=$(source_value helium_passwords_commit)
helium_core_commit=$(source_value helium_core_commit)
chromium_commit=$(source_value chromium_commit)
platform_commit=$(git -C "$checkout" rev-parse HEAD)
node_version=$(boundary_value node_version)
full_targets=$(boundary_value full_targets)
build_ninja_sha256=$(sha256sum "$temporary/build.ninja" | awk '{print $1}')
toolchain_ninja_sha256=$(sha256sum "$temporary/toolchain.ninja" | awk '{print $1}')
generate_css_gni_sha256=$(sha256sum "$temporary/generate_css.gni" | awk '{print $1}')
generate_css_js_sha256=$(sha256sum "$temporary/generate_css_js_files.js" | awk '{print $1}')
build_ai_skills_sha256=$(sha256sum "$temporary/build_ai_skills.mjs" | awk '{print $1}')
platform_shared_sha256=$(sha256sum "$temporary/platform-shared.sh" | awk '{print $1}')
build_operator_sha256=$(sha256sum "$temporary/build-operator.sh" | awk '{print $1}')
ninja_shim_sha256=$(sha256sum "$temporary/ninja-shim" | awk '{print $1}')
ninja_binary_sha256=$(sha256sum "$temporary/ninja-binary" | awk '{print $1}')
ninja_version_sha256=$(sha256sum "$temporary/ninja-version.txt" | awk '{print $1}')
ninja_query_sha256=$(sha256sum "$temporary/ninja-query.txt" | awk '{print $1}')
full_targets_query_sha256=$(sha256sum "$temporary/full-targets-query.txt" | awk '{print $1}')
boundary_receipt_sha256=$(sha256sum "$temporary/boundary-receipt.env" | awk '{print $1}')
capture_tool_sha256=$(sha256sum "$temporary/capture-tool.sh" | awk '{print $1}')
packaging_tool_sha256=$(sha256sum "$temporary/packaging-tool.sh" | awk '{print $1}')
deployment_receipt_tool_sha256=$(sha256sum "$temporary/deployment-receipt-tool.sh" | awk '{print $1}')
finalizer_tool_sha256=$(sha256sum "$temporary/finalizer-tool.sh" | awk '{print $1}')
full_graph_audit_tool_sha256=$(sha256sum "$temporary/full-graph-audit-tool.mjs" | awk '{print $1}')
repair_tool_sha256=$(sha256sum "$temporary/repair-tool.sh" | awk '{print $1}')
css_action_edges=$(boundary_value css_action_edges)
css_action_edges_without_tsconfig=$(boundary_value css_action_edges_without_tsconfig)
ui_css_outputs_materialized_before_full_build=$(boundary_value ui_css_outputs_materialized_before_full_build)
ui_css_phony_orders_all_outputs=$(boundary_value ui_css_phony_orders_all_outputs)
ui_downstream_orders_css_phony=$(boundary_value ui_downstream_orders_css_phony)
ai_skill_action_present=$(boundary_value ai_skill_action_present)
graph_validation=passed
captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "$temporary/receipt.env"
(
  cd "$temporary"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' |
    sort -z | xargs -0 sha256sum >SHA256SUMS
)
chmod 600 "$temporary/SHA256SUMS"
node "$tool_root/scripts/linux-full-graph-audit.mjs" "$temporary" >/dev/null
mv "$temporary" "$output"
trap - EXIT
printf 'full_graph_evidence=%s\nreceipt=%s\ninventory_sha256=%s\n' \
  "$output" "$output/receipt.env" \
  "$(sha256sum "$output/SHA256SUMS" | awk '{print $1}')"
