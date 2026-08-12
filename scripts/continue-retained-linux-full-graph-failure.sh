#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 10 ]]; then
  echo "usage: $0 PRODUCT ARCH TARGET BUILD-JOB-ID PRODUCT-SOURCE PLATFORM-CHECKOUT GRAPH-GATE-FAILURE EXPECTED-FAILURE-SHA256 OUTPUT.tar.xz OUTPUT.receipt.env" >&2
  exit 64
fi

product=$1
arch=$2
target=$3
job=$4
product_root=$(realpath -e "$5")
checkout=$(realpath -e "$6")
failure=$(realpath -e "$7")
expected_failure_sha=$8
artifact=$(realpath -m "$9")
receipt=$(realpath -m "${10}")
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root="$checkout/build/src"
out="$source_root/out/Default"
output_parent=$(dirname "$artifact")
preflight="$output_parent/${job}.retained-graph-repair-preflight.env"
boundary="$output_parent/${job}.retained-graph-repair-boundary.env"
repair_failure="$output_parent/${job}.retained-graph-repair-failure.env"

[[ ("$product" == helium-passwords || "$product" == helium-sync) &&
    "$arch" == x86_64 &&
    "$target" == linux-x86_64 &&
    "$job" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ &&
    "$expected_failure_sha" =~ ^[0-9a-f]{64}$ ]] || {
  echo "retained graph repair requires an explicit Linux x86_64 Helium job and failure hash" >&2
  exit 64
}
[[ -d "$output_parent" && ! -L "$output_parent" &&
    ! -e "$artifact" && ! -e "$receipt" &&
    ! -e "$preflight" && ! -e "$boundary" && ! -e "$repair_failure" ]] || {
  echo "retained graph repair requires an existing parent and entirely new durable outputs" >&2
  exit 1
}
[[ -f "$failure" && ! -L "$failure" &&
    "$(stat -c %a "$failure")" == 400 &&
    "$(basename "$failure")" == graph-gate-failure.env &&
    ! -e "$(dirname "$failure")/full-graph-boundary.env" ]] || {
  echo "retained graph repair requires the immutable local pre-Ninja failure receipt" >&2
  exit 1
}
[[ "$(sha256sum "$failure" | awk '{print $1}')" == "$expected_failure_sha" ]] || {
  echo "retained graph repair failure receipt does not match the operator-approved hash" >&2
  exit 1
}
for tool in awk date find git install mktemp node realpath sha256sum sort stat; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[[ -x "${HELIUM_BUILD_OPERATOR:?missing HELIUM_BUILD_OPERATOR}" &&
    -x "${HELIUM_NINJA_SHIM:?missing HELIUM_NINJA_SHIM}" &&
    -x "${HELIUM_REAL_NINJA:?missing HELIUM_REAL_NINJA}" ]] || {
  echo "retained graph repair requires the exact operator, failed shim, and real Ninja" >&2
  exit 1
}
real_ninja=$(realpath -e "$HELIUM_REAL_NINJA")
[[ "$real_ninja" != "$(realpath -e "$HELIUM_NINJA_SHIM")" ]] || {
  echo "retained graph repair refuses to execute the failed Ninja shim" >&2
  exit 1
}
[[ "$(node --version)" == v22.14.0 ]] || {
  echo "retained graph repair requires Node 22.14.0" >&2
  exit 1
}

failure_keys=(
  artifact_published
  broad_css_rule_edges
  broad_css_rule_edges_without_tsconfig
  build_ninja_sha256
  devtools_generate_css_edges
  devtools_generate_css_edges_without_tsconfig
  duration_seconds
  exit_code
  finished_at
  job
  ninja_shim_sha256
  operator_sha256
  result
  root_cause
  schema
  source_commit
  toolchain_ninja_sha256
  workspace_preserved
)
mapfile -t actual_failure_keys < <(awk -F= 'NF {print $1}' "$failure" | sort)
[[ "$(printf '%s\n' "${failure_keys[@]}" | sort)" == \
    "$(printf '%s\n' "${actual_failure_keys[@]}")" ]] || {
  echo "retained graph failure receipt has an unexpected field inventory" >&2
  exit 1
}
failure_value() {
  awk -F= -v key="$1" '
    $1 == key {count++; value=substr($0,length(key)+2)}
    END {if (count == 1 && value != "") print value; else exit 1}
  ' "$failure"
}
source_commit=$(git -C "$product_root" rev-parse HEAD)
[[ "$(failure_value schema)" == helium-linux-graph-gate-failure-v1 &&
    "$(failure_value job)" == "$job" &&
    "$(failure_value result)" == failure &&
    "$(failure_value exit_code)" == 1 &&
    "$(failure_value source_commit)" == "$source_commit" &&
    "$(failure_value root_cause)" == graph_gate_counted_unrelated_preprocess_html_css_rules_as_devtools_generate_css_actions &&
    "$(failure_value workspace_preserved)" == true &&
    "$(failure_value artifact_published)" == false &&
    "$(failure_value duration_seconds)" =~ ^[1-9][0-9]*$ &&
    "$(failure_value devtools_generate_css_edges)" =~ ^[1-9][0-9]*$ &&
    "$(failure_value devtools_generate_css_edges_without_tsconfig)" == 0 ]] || {
  echo "retained graph failure is not the admitted pre-Ninja false-positive" >&2
  exit 1
}
date -d "$(failure_value finished_at)" +%s >/dev/null
[[ "$(sha256sum "$HELIUM_BUILD_OPERATOR" | awk '{print $1}')" == \
      "$(failure_value operator_sha256)" &&
    "$(sha256sum "$HELIUM_NINJA_SHIM" | awk '{print $1}')" == \
      "$(failure_value ninja_shim_sha256)" ]] || {
  echo "retained graph failure does not bind the supplied operator and failed shim" >&2
  exit 1
}
[[ -f "$out/build.ninja" && ! -L "$out/build.ninja" &&
    -f "$out/toolchain.ninja" && ! -L "$out/toolchain.ninja" &&
    "$(sha256sum "$out/build.ninja" | awk '{print $1}')" == \
      "$(failure_value build_ninja_sha256)" &&
    "$(sha256sum "$out/toolchain.ninja" | awk '{print $1}')" == \
      "$(failure_value toolchain_ninja_sha256)" ]] || {
  echo "retained graph changed after the failed gate" >&2
  exit 1
}
[[ -z "$(git -C "$product_root" status --porcelain --untracked-files=all)" &&
    -z "$(git -C "$tool_root" status --porcelain --untracked-files=all)" &&
    "$(git -C "$source_root" rev-parse HEAD)" == \
      "$(HELIUM_PRODUCT_SOURCE_ROOT="$product_root" \
        "$product_root/scripts/linux-product-provenance.sh" \
          "$product" "$arch" "$target" |
        awk -F= '$1 == "chromium_commit" {print $2; exit}')" ]] || {
  echo "retained product, tooling, or Chromium identity is no longer frozen" >&2
  exit 1
}
[[ ! -e "$out/helium" && ! -e "$out/chromedriver" ]] || {
  echo "retained workspace contains full-build outputs despite its pre-Ninja failure" >&2
  exit 1
}

broad_edges=$(awk '
  /^build / && /_css_files___build_toolchain_linux_clang_x64__rule/ {count++}
  END {print count + 0}
' "$out/toolchain.ninja")
broad_without_tsconfig=$(awk '
  /^build / && /_css_files___build_toolchain_linux_clang_x64__rule/ &&
      $0 !~ /-tsconfig\.json / {count++}
  END {print count + 0}
' "$out/toolchain.ninja")
[[ "$broad_edges" == "$(failure_value broad_css_rule_edges)" &&
    "$broad_without_tsconfig" == \
      "$(failure_value broad_css_rule_edges_without_tsconfig)" ]] || {
  echo "retained graph no longer reproduces the failed overbroad diagnostic" >&2
  exit 1
}

temporary=$(mktemp -d "$output_parent/.retained-graph-repair.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT
chmod 700 "$temporary"
query="$temporary/ninja-query.txt"
"$real_ninja" -C "$out" -t query \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json \
  >"$query"
chmod 600 "$query"
generated="$temporary/generated.env"
node "$tool_root/scripts/linux-full-graph-audit.mjs" generated-prebuild \
  "$out/toolchain.ninja" "$query" "$out" >"$generated"
generated_value() {
  awk -F= -v key="$1" '
    $1 == key {count++; value=substr($0,length(key)+2)}
    END {if (count == 1 && value != "") print value; else exit 1}
  ' "$generated"
}
[[ "$(generated_value css_action_edges)" == \
      "$(failure_value devtools_generate_css_edges)" &&
    "$(generated_value css_action_edges_without_tsconfig)" == 0 &&
    "$broad_edges" -gt "$(generated_value css_action_edges)" &&
    "$broad_without_tsconfig" -gt 0 ]] || {
  echo "narrow DevTools graph audit does not prove the reported false-positive" >&2
  exit 1
}

boundary_epoch=$(date +%s)
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repair_tool_sha=$(sha256sum "$tool_root/scripts/continue-retained-linux-full-graph-failure.sh" |
  awk '{print $1}')
gni="$source_root/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni"
generator="$source_root/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js"
ai_skills="$source_root/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs"
for file in "$gni" "$generator" "$ai_skills"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "missing retained graph source: $file" >&2; exit 1; }
done
cat >"$preflight" <<EOF
schema=helium-retained-full-graph-repair-preflight-v1
job=$job
source_root=$source_root
source_commit=$source_commit
failure_receipt_sha256=$expected_failure_sha
failure_finished_at=$(failure_value finished_at)
operator_sha256=$(failure_value operator_sha256)
ninja_shim_sha256=$(failure_value ninja_shim_sha256)
real_ninja_sha256=$(sha256sum "$real_ninja" | awk '{print $1}')
boundary_epoch=$boundary_epoch
validated_at=$validated_at
node_version=$(node --version)
full_targets=chrome,chromedriver
build_ninja_sha256=$(failure_value build_ninja_sha256)
toolchain_ninja_sha256=$(failure_value toolchain_ninja_sha256)
generate_css_gni_sha256=$(sha256sum "$gni" | awk '{print $1}')
generate_css_js_sha256=$(sha256sum "$generator" | awk '{print $1}')
build_ai_skills_sha256=$(sha256sum "$ai_skills" | awk '{print $1}')
broad_css_rule_edges=$broad_edges
broad_css_rule_edges_without_tsconfig=$broad_without_tsconfig
css_action_edges=$(generated_value css_action_edges)
css_action_edges_without_tsconfig=$(generated_value css_action_edges_without_tsconfig)
ui_css_outputs_materialized_before_full_build=$(generated_value ui_css_outputs_materialized_before_full_build)
ui_css_phony_orders_all_outputs=$(generated_value ui_css_phony_orders_all_outputs)
ui_downstream_orders_css_phony=$(generated_value ui_downstream_orders_css_phony)
ai_skill_action_present=$(generated_value ai_skill_action_present)
ninja_query_sha256=$(sha256sum "$query" | awk '{print $1}')
repair_tool_sha256=$repair_tool_sha
graph_validation=passed
EOF
chmod 400 "$preflight"
preflight_sha=$(sha256sum "$preflight" | awk '{print $1}')

build_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
"$real_ninja" -j 1 -C "$out" chrome chromedriver
build_status=$?
set -e
build_completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "$build_status" -ne 0 ]]; then
  cat >"$repair_failure" <<EOF
schema=helium-retained-full-graph-repair-failure-v1
job=$job
source_commit=$source_commit
failure_receipt_sha256=$expected_failure_sha
repair_preflight_sha256=$preflight_sha
build_started_at=$build_started_at
build_completed_at=$build_completed_at
build_exit_code=$build_status
workspace_preserved=true
artifact_published=false
EOF
  chmod 400 "$repair_failure"
  echo "retained Ninja repair failed; workspace and durable failure evidence were preserved" >&2
  exit "$build_status"
fi
[[ -x "$out/helium" && -x "$out/chromedriver" &&
    "$(sha256sum "$out/build.ninja" | awk '{print $1}')" == \
      "$(failure_value build_ninja_sha256)" &&
    "$(sha256sum "$out/toolchain.ninja" | awk '{print $1}')" == \
      "$(failure_value toolchain_ninja_sha256)" ]] || {
  echo "retained full build did not produce both targets from the admitted graph" >&2
  exit 1
}
cat >"$boundary" <<EOF
schema=helium-retained-full-graph-repair-boundary-v1
job=$job
source_root=$source_root
boundary_epoch=$boundary_epoch
validated_at=$validated_at
node_version=v22.14.0
full_targets=chrome,chromedriver
build_ninja_sha256=$(failure_value build_ninja_sha256)
toolchain_ninja_sha256=$(failure_value toolchain_ninja_sha256)
generate_css_gni_sha256=$(sha256sum "$gni" | awk '{print $1}')
generate_css_js_sha256=$(sha256sum "$generator" | awk '{print $1}')
build_ai_skills_sha256=$(sha256sum "$ai_skills" | awk '{print $1}')
css_action_edges=$(generated_value css_action_edges)
css_action_edges_without_tsconfig=$(generated_value css_action_edges_without_tsconfig)
ui_css_outputs_materialized_before_full_build=false
ui_css_phony_orders_all_outputs=true
ui_downstream_orders_css_phony=true
ai_skill_action_present=true
ninja_query_sha256=$(sha256sum "$query" | awk '{print $1}')
graph_validation=passed
failure_receipt_sha256=$expected_failure_sha
failure_source_commit=$source_commit
failure_finished_at=$(failure_value finished_at)
failure_duration_seconds=$(failure_value duration_seconds)
failure_result=failure
failure_exit_code=1
failure_operator_sha256=$(failure_value operator_sha256)
failure_ninja_shim_sha256=$(failure_value ninja_shim_sha256)
failure_build_ninja_sha256=$(failure_value build_ninja_sha256)
failure_toolchain_ninja_sha256=$(failure_value toolchain_ninja_sha256)
failure_broad_css_rule_edges=$broad_edges
failure_broad_css_rule_edges_without_tsconfig=$broad_without_tsconfig
failure_devtools_generate_css_edges=$(generated_value css_action_edges)
failure_devtools_generate_css_edges_without_tsconfig=0
failure_root_cause=$(failure_value root_cause)
failure_workspace_preserved=true
failure_artifact_published=false
recovery_mode=retained-workspace-after-pre-ninja-graph-gate-failure
repair_preflight_sha256=$preflight_sha
repair_tool_sha256=$repair_tool_sha
build_started_at=$build_started_at
build_completed_at=$build_completed_at
build_exit_code=0
EOF
chmod 400 "$boundary"

HELIUM_PRODUCT_SOURCE_ROOT="$product_root" \
  "$tool_root/scripts/finalize-retained-linux-full-graph.sh" \
    "$product" "$arch" "$target" "$job" "$product_root" "$checkout" \
    "$boundary" "$artifact" "$receipt"
trap - EXIT
find "$temporary" -depth -delete
printf 'repair_preflight=%s\nrepair_boundary=%s\nartifact=%s\nreceipt=%s\n' \
  "$preflight" "$boundary" "$artifact" "$receipt"
