#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 16 ]]; then
  echo "usage: $0 PRODUCT ARCH TARGET BUILD-JOB-ID PRODUCT-SOURCE PLATFORM-CHECKOUT GRAPH-FAILURE GRAPH-FAILURE-SHA256 FIRST-PREFLIGHT FIRST-PREFLIGHT-SHA256 FIRST-FAILURE FIRST-FAILURE-SHA256 NODE-FAILURE-LOG NODE-FAILURE-LOG-SHA256 OUTPUT.tar.xz OUTPUT.receipt.env" >&2
  exit 64
fi

product=$1
arch=$2
target=$3
job=$4
product_root=$(realpath -e "$5")
checkout=$(realpath -e "$6")
graph_failure=$(realpath -e "$7")
expected_graph_failure_sha=$8
first_preflight=$(realpath -e "$9")
expected_first_preflight_sha=${10}
first_failure=$(realpath -e "${11}")
expected_first_failure_sha=${12}
node_failure_log=$(realpath -e "${13}")
expected_node_failure_log_sha=${14}
artifact=$(realpath -m "${15}")
receipt=$(realpath -m "${16}")
tool_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root="$checkout/build/src"
out="$source_root/out/Default"
output_parent=$(dirname "$artifact")
preflight="$output_parent/${job}.retained-node22-repair-preflight.env"
boundary="$output_parent/${job}.retained-node22-repair-boundary.env"
repair_failure="$output_parent/${job}.retained-node22-repair-failure.env"
action_output_relative=gen/components/helium_onboarding/helium_onboarding_localized_strings.h
action_output="$out/$action_output_relative"
action_source="$source_root/components/helium_onboarding/util/generate-i18n.mts"
onboarding_build="$source_root/components/helium_onboarding/BUILD.gn"

[[ "$product" == helium-sync && "$arch" == x86_64 &&
    "$target" == linux-x86_64 &&
    "$job" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  echo "retained Node repair requires the Linux x86_64 Helium Sync product" >&2
  exit 64
}
for value in "$expected_graph_failure_sha" "$expected_first_preflight_sha" \
  "$expected_first_failure_sha" "$expected_node_failure_log_sha"; do
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
    echo "retained Node repair requires every approved SHA-256 value" >&2
    exit 64
  }
done
[[ -d "$output_parent" && ! -L "$output_parent" &&
    ! -e "$artifact" && ! -e "$receipt" &&
    ! -e "$preflight" && ! -e "$boundary" &&
    ! -e "$repair_failure" &&
    ! -e "$output_parent/${product}-linux-${arch}.full-graph" ]] || {
  echo "retained Node repair requires entirely new durable outputs" >&2
  exit 1
}
for input in "$graph_failure" "$first_preflight" "$first_failure" \
  "$node_failure_log"; do
  [[ -f "$input" && ! -L "$input" && "$(stat -c %a "$input")" == 400 ]] || {
    echo "retained Node repair input is not an immutable private receipt: $input" >&2
    exit 1
  }
done
[[ "$(sha256sum "$graph_failure" | awk '{print $1}')" == \
      "$expected_graph_failure_sha" &&
    "$(sha256sum "$first_preflight" | awk '{print $1}')" == \
      "$expected_first_preflight_sha" &&
    "$(sha256sum "$first_failure" | awk '{print $1}')" == \
      "$expected_first_failure_sha" &&
    "$(sha256sum "$node_failure_log" | awk '{print $1}')" == \
      "$expected_node_failure_log_sha" ]] || {
  echo "retained Node repair input changed after operator approval" >&2
  exit 1
}
for tool in awk date find git grep install mktemp node python3 realpath \
  sha256sum sort stat; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[[ -x "${HELIUM_BUILD_OPERATOR:?missing HELIUM_BUILD_OPERATOR}" &&
    -x "${HELIUM_NINJA_SHIM:?missing HELIUM_NINJA_SHIM}" &&
    -x "${HELIUM_REAL_NINJA:?missing HELIUM_REAL_NINJA}" ]] || {
  echo "retained Node repair requires the original operator and both Ninja paths" >&2
  exit 1
}
real_ninja=$(realpath -e "$HELIUM_REAL_NINJA")
[[ "$real_ninja" != "$(realpath -e "$HELIUM_NINJA_SHIM")" &&
    "$(node --version)" == v22.14.0 ]] || {
  echo "retained Node repair requires real Ninja and Node 22.14.0" >&2
  exit 1
}

env_value() {
  local file=$1 key=$2
  awk -F= -v key="$key" '
    $1 == key {count++; value=substr($0,length(key)+2)}
    END {if (count == 1 && value != "") print value; else exit 1}
  ' "$file"
}
source_commit=$(git -C "$product_root" rev-parse HEAD)
[[ "$(env_value "$graph_failure" schema)" == \
      helium-linux-graph-gate-failure-v1 &&
    "$(env_value "$graph_failure" job)" == "$job" &&
    "$(env_value "$graph_failure" source_commit)" == "$source_commit" &&
    "$(env_value "$graph_failure" root_cause)" == \
      graph_gate_counted_unrelated_preprocess_html_css_rules_as_devtools_generate_css_actions &&
    "$(env_value "$graph_failure" workspace_preserved)" == true &&
    "$(env_value "$graph_failure" artifact_published)" == false &&
    "$(env_value "$first_preflight" schema)" == \
      helium-retained-full-graph-repair-preflight-v1 &&
    "$(env_value "$first_preflight" job)" == "$job" &&
    "$(env_value "$first_preflight" source_commit)" == "$source_commit" &&
    "$(env_value "$first_preflight" failure_receipt_sha256)" == \
      "$expected_graph_failure_sha" &&
    "$(env_value "$first_failure" schema)" == \
      helium-retained-full-graph-repair-failure-v1 &&
    "$(env_value "$first_failure" job)" == "$job" &&
    "$(env_value "$first_failure" source_commit)" == "$source_commit" &&
    "$(env_value "$first_failure" repair_preflight_sha256)" == \
      "$expected_first_preflight_sha" &&
    "$(env_value "$first_failure" build_exit_code)" == 1 &&
    "$(env_value "$first_failure" workspace_preserved)" == true &&
    "$(env_value "$first_failure" artifact_published)" == false ]] || {
  echo "retained Node repair receipts do not describe the admitted terminal failure" >&2
  exit 1
}
first_started=$(env_value "$first_failure" build_started_at)
first_completed=$(env_value "$first_failure" build_completed_at)
[[ "$(date -d "$first_started" +%s)" -lt \
    "$(date -d "$first_completed" +%s)" ]] || {
  echo "retained Node repair failure chronology is invalid" >&2
  exit 1
}
[[ "$(sha256sum "$HELIUM_BUILD_OPERATOR" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" operator_sha256)" &&
    "$(sha256sum "$HELIUM_NINJA_SHIM" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" ninja_shim_sha256)" &&
    -f "$out/build.ninja" && ! -L "$out/build.ninja" &&
    -f "$out/toolchain.ninja" && ! -L "$out/toolchain.ninja" &&
    "$(sha256sum "$out/build.ninja" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" build_ninja_sha256)" &&
    "$(sha256sum "$out/toolchain.ninja" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" toolchain_ninja_sha256)" ]] || {
  echo "retained Node repair graph or original execution boundary changed" >&2
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
[[ -f "$action_source" && ! -L "$action_source" &&
    -f "$onboarding_build" && ! -L "$onboarding_build" &&
    ! -e "$action_output" && ! -e "$out/helium" &&
    ! -e "$out/chromedriver" ]] || {
  echo "retained Node repair requires the untouched failed action and incomplete targets" >&2
  exit 1
}
grep -Fq 'script = "util/generate-i18n.mts"' "$onboarding_build"
if grep -Fq -- '--experimental-strip-types' "$onboarding_build"; then
  echo "retained source already contains an unrecorded Node repair" >&2
  exit 1
fi
for pattern in \
  '[41656/56430] ACTION //components/helium_onboarding:localized_strings' \
  'FAILED: gen/components/helium_onboarding/helium_onboarding_localized_strings.h' \
  'Unknown file extension ".mts"' \
  'ERR_UNKNOWN_FILE_EXTENSION' \
  'Node.js v22.14.0' \
  'retained Ninja repair failed; workspace and durable failure evidence were preserved'; do
  grep -Fq "$pattern" "$node_failure_log" || {
    echo "retained Node failure log is missing: $pattern" >&2
    exit 1
  }
done
if grep -F 'python3 ../../third_party/node/node.py' "$node_failure_log" |
    grep -Fq -- '--experimental-strip-types'; then
  echo "retained failure log unexpectedly contains the repaired action" >&2
  exit 1
fi

temporary=$(mktemp -d "$output_parent/.retained-node22-repair.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT
chmod 700 "$temporary"
query="$temporary/ninja-query.txt"
"$real_ninja" -C "$out" -t query \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json \
  gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json \
  >"$query"
chmod 600 "$query"
[[ "$(sha256sum "$query" | awk '{print $1}')" == \
    "$(env_value "$first_preflight" ninja_query_sha256)" ]] || {
  echo "retained Node repair query changed after the terminal failure" >&2
  exit 1
}
generated_value() { env_value "$first_preflight" "$1"; }
[[ "$(generated_value css_action_edges)" =~ ^[1-9][0-9]*$ &&
    "$(generated_value css_action_edges_without_tsconfig)" == 0 &&
    "$(generated_value ui_css_outputs_materialized_before_full_build)" == \
      false &&
    "$(generated_value ui_css_phony_orders_all_outputs)" == true &&
    "$(generated_value ui_downstream_orders_css_phony)" == true &&
    "$(generated_value ai_skill_action_present)" == true &&
    "$(generated_value graph_validation)" == passed ]] || {
  echo "retained Node repair lost the admitted DevTools graph proof" >&2
  exit 1
}

case "${HELIUM_NODE22_REPAIR_PREFLIGHT_ONLY:-false}" in
  true)
    printf 'retained_node22_repair_preflight=passed\njob=%s\nsource_commit=%s\n' \
      "$job" "$source_commit"
    printf 'graph_failure_sha256=%s\nfirst_repair_failure_sha256=%s\n' \
      "$expected_graph_failure_sha" "$expected_first_failure_sha"
    exit 0
    ;;
  false) ;;
  *)
    echo "HELIUM_NODE22_REPAIR_PREFLIGHT_ONLY must be true or false" >&2
    exit 64
    ;;
esac

node_repair_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
(
  cd "$out"
  python3 ../../third_party/node/node.py --experimental-strip-types \
    ../../components/helium_onboarding/util/generate-i18n.mts \
    "$action_output_relative"
)
action_status=$?
set -e
node_repair_completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "$action_status" -ne 0 || ! -f "$action_output" ||
    -L "$action_output" ]]; then
  cat >"$repair_failure" <<EOF
schema=helium-retained-node22-repair-failure-v1
job=$job
stage=manual-node-action
source_commit=$source_commit
first_repair_failure_sha256=$expected_first_failure_sha
node_failure_log_sha256=$expected_node_failure_log_sha
node_repair_started_at=$node_repair_started_at
node_repair_completed_at=$node_repair_completed_at
exit_code=$action_status
workspace_preserved=true
artifact_published=false
EOF
  chmod 400 "$repair_failure"
  echo "retained Node repair action failed; workspace and receipt were preserved" >&2
  [[ "$action_status" -ne 0 ]] || action_status=1
  exit "$action_status"
fi
action_output_sha=$(sha256sum "$action_output" | awk '{print $1}')
dry_run="$temporary/action-dry-run.txt"
"$real_ninja" -C "$out" -n "$action_output_relative" >"$dry_run"
grep -Fq 'ninja: no work to do.' "$dry_run" || {
  echo "manual Node repair output is not clean in the unchanged Ninja graph" >&2
  exit 1
}

repair_tool_sha=$(sha256sum "$tool_root/scripts/continue-retained-linux-node22-mts-failure.sh" |
  awk '{print $1}')
cat >"$preflight" <<EOF
schema=helium-retained-node22-repair-preflight-v1
job=$job
source_root=$source_root
source_commit=$source_commit
graph_failure_sha256=$expected_graph_failure_sha
first_repair_preflight_sha256=$expected_first_preflight_sha
first_repair_failure_sha256=$expected_first_failure_sha
node_failure_log_sha256=$expected_node_failure_log_sha
build_ninja_sha256=$(env_value "$graph_failure" build_ninja_sha256)
toolchain_ninja_sha256=$(env_value "$graph_failure" toolchain_ninja_sha256)
node_version=$(node --version)
node_repair_action=third_party_node_with_experimental_strip_types
node_repair_action_source_sha256=$(sha256sum "$action_source" | awk '{print $1}')
node_repair_action_output=$action_output_relative
node_repair_action_output_sha256=$action_output_sha
node_repair_started_at=$node_repair_started_at
node_repair_completed_at=$node_repair_completed_at
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
schema=helium-retained-node22-repair-failure-v1
job=$job
stage=continued-full-build
source_commit=$source_commit
first_repair_failure_sha256=$expected_first_failure_sha
node_failure_log_sha256=$expected_node_failure_log_sha
repair_preflight_sha256=$preflight_sha
build_started_at=$build_started_at
build_completed_at=$build_completed_at
exit_code=$build_status
workspace_preserved=true
artifact_published=false
EOF
  chmod 400 "$repair_failure"
  echo "retained Node continuation failed; workspace and receipt were preserved" >&2
  exit "$build_status"
fi
[[ -x "$out/helium" && -x "$out/chromedriver" &&
    "$(sha256sum "$out/build.ninja" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" build_ninja_sha256)" &&
    "$(sha256sum "$out/toolchain.ninja" | awk '{print $1}')" == \
      "$(env_value "$graph_failure" toolchain_ninja_sha256)" &&
    "$(sha256sum "$action_output" | awk '{print $1}')" == \
      "$action_output_sha" ]] || {
  echo "retained full build changed its admitted graph or repair output" >&2
  exit 1
}

cat >"$boundary" <<EOF
schema=helium-retained-full-graph-node-repair-boundary-v1
job=$job
source_root=$source_root
boundary_epoch=$(env_value "$first_preflight" boundary_epoch)
validated_at=$(env_value "$first_preflight" validated_at)
node_version=v22.14.0
full_targets=chrome,chromedriver
build_ninja_sha256=$(env_value "$graph_failure" build_ninja_sha256)
toolchain_ninja_sha256=$(env_value "$graph_failure" toolchain_ninja_sha256)
generate_css_gni_sha256=$(env_value "$first_preflight" generate_css_gni_sha256)
generate_css_js_sha256=$(env_value "$first_preflight" generate_css_js_sha256)
build_ai_skills_sha256=$(env_value "$first_preflight" build_ai_skills_sha256)
css_action_edges=$(generated_value css_action_edges)
css_action_edges_without_tsconfig=0
ui_css_outputs_materialized_before_full_build=false
ui_css_phony_orders_all_outputs=true
ui_downstream_orders_css_phony=true
ai_skill_action_present=true
ninja_query_sha256=$(sha256sum "$query" | awk '{print $1}')
graph_validation=passed
failure_receipt_sha256=$expected_graph_failure_sha
failure_source_commit=$source_commit
failure_finished_at=$(env_value "$graph_failure" finished_at)
failure_duration_seconds=$(env_value "$graph_failure" duration_seconds)
failure_result=failure
failure_exit_code=1
failure_operator_sha256=$(env_value "$graph_failure" operator_sha256)
failure_ninja_shim_sha256=$(env_value "$graph_failure" ninja_shim_sha256)
failure_build_ninja_sha256=$(env_value "$graph_failure" build_ninja_sha256)
failure_toolchain_ninja_sha256=$(env_value "$graph_failure" toolchain_ninja_sha256)
failure_broad_css_rule_edges=$(env_value "$graph_failure" broad_css_rule_edges)
failure_broad_css_rule_edges_without_tsconfig=$(env_value "$graph_failure" broad_css_rule_edges_without_tsconfig)
failure_devtools_generate_css_edges=$(env_value "$graph_failure" devtools_generate_css_edges)
failure_devtools_generate_css_edges_without_tsconfig=0
failure_root_cause=$(env_value "$graph_failure" root_cause)
failure_workspace_preserved=true
failure_artifact_published=false
recovery_mode=retained-workspace-after-node22-mts-terminal-failure
repair_preflight_sha256=$preflight_sha
repair_tool_sha256=$repair_tool_sha
build_started_at=$build_started_at
build_completed_at=$build_completed_at
build_exit_code=0
first_repair_preflight_sha256=$expected_first_preflight_sha
first_repair_failure_sha256=$expected_first_failure_sha
first_repair_build_started_at=$first_started
first_repair_build_completed_at=$first_completed
first_repair_build_exit_code=1
node_failure_log_sha256=$expected_node_failure_log_sha
node_failure_root_cause=node22_unknown_mts_extension_in_helium_onboarding_localized_strings
node_repair_action=third_party_node_with_experimental_strip_types
node_repair_action_output=$action_output_relative
node_repair_action_output_sha256=$action_output_sha
node_repair_started_at=$node_repair_started_at
node_repair_completed_at=$node_repair_completed_at
EOF
chmod 400 "$boundary"

HELIUM_REPAIR_TOOL="$tool_root/scripts/continue-retained-linux-node22-mts-failure.sh" \
HELIUM_PRODUCT_SOURCE_ROOT="$product_root" \
  "$tool_root/scripts/finalize-retained-linux-full-graph.sh" \
    "$product" "$arch" "$target" "$job" "$product_root" "$checkout" \
    "$boundary" "$artifact" "$receipt"
trap - EXIT
find "$temporary" -depth -delete
printf 'repair_preflight=%s\nrepair_boundary=%s\nartifact=%s\nreceipt=%s\n' \
  "$preflight" "$boundary" "$artifact" "$receipt"
