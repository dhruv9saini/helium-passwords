#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/verify-linux-runtime.sh PRODUCT ARCH TARGET ARTIFACT.tar.xz DEPLOYMENT-RECEIPT NEW-DESTINATION
EOF
}

[ "$#" -eq 6 ] || {
    usage
    exit 2
}

product=$1
arch=$2
target=$3
artifact=$(realpath -e "$4")
deployment_receipt=$(realpath -e "$5")
destination=$(realpath -m "$6")
tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
product_root=$(realpath -e "${HELIUM_PRODUCT_SOURCE_ROOT:-$tool_root}")
source_info=$("${product_root}/scripts/linux-product-provenance.sh" \
    "${product}" "${arch}" "${target}")
source_value() {
    awk -F= -v key="$1" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${source_info}"
}
expected_source=$(source_value source_commit)
expected_tree=$(source_value source_tree)
expected_passwords=$(source_value helium_passwords_commit)
expected_sync=$(source_value helium_sync_commit)
expected_core=$(source_value helium_core_commit)
expected_version=$(source_value chromium_version)
expected_chromium=$(source_value chromium_commit)
deployment_admission=$(
    "${tool_root}/scripts/verify-deployment-artifact-receipt.sh" \
        "${artifact}" "${deployment_receipt}" "${target}"
)
admission_value() {
    awk -F= -v key="$1" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${deployment_admission}"
}

[ -f "${artifact}" ] && [ ! -L "${artifact}" ] || {
    echo "artifact must be a regular non-symlink file" >&2
    exit 1
}
[ ! -e "${destination}" ] || {
    echo "verification destination must not exist" >&2
    exit 1
}
archive_root=$(tar -tf "${artifact}" | awk -F/ 'NF { print $1 }' | sort -u)
[ "$(wc -l <<<"${archive_root}")" -eq 1 ] && \
    [ "${archive_root}" = "${product}-linux-${arch}" ] || {
    echo "artifact has an invalid root" >&2
    exit 1
}
tar -tf "${artifact}" | awk '
    /^\// { bad=1 }
    /(^|\/)\.\.?(\/|$)/ { bad=1 }
    END { exit bad }
' || {
    echo "artifact contains an unsafe path" >&2
    exit 1
}

parent=$(dirname "${destination}")
mkdir -p "${parent}"
temporary=$(mktemp -d "${parent}/.helium-linux-verify.XXXXXX")
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT
tar --extract --xz --file="${artifact}" --directory="${temporary}"
bundle="${temporary}/${archive_root}"
runtime="${bundle}/runtime"
provenance="${bundle}/provenance"
manifest="${provenance}/manifest.env"

expected_files=(
    chromiumer-nix.env
    gn-args.txt
    manifest.env
    patches.sha256
    runtime.sha256
)
mapfile -t actual_provenance < <(find "${provenance}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[ "$(printf '%s\n' "${expected_files[@]}" | sort)" = "$(printf '%s\n' "${actual_provenance[@]}")" ] || {
    echo "artifact provenance inventory is invalid" >&2
    exit 1
}
[ -d "${provenance}/full-graph" ] && [ ! -L "${provenance}/full-graph" ] && \
    [ "$(find "${provenance}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" = \
        full-graph ] || {
    echo "artifact full-graph provenance directory is missing or unexpected" >&2
    exit 1
}
[ "$(find "${bundle}" -type l -printf '%P -> %l\n')" = 'runtime/chrome -> helium' ] || {
    echo "artifact symlink inventory is invalid" >&2
    exit 1
}
[ "$(find "${runtime}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" = "$(cat <<'EOF' | sort
chrome
chrome_100_percent.pak
chrome_200_percent.pak
chromedriver
helium
helium_crashpad_handler
helium-wrapper
helium.desktop
icudtl.dat
libEGL.so
libGLESv2.so
libqt5_shim.so
libqt6_shim.so
libvk_swiftshader.so
libvulkan.so.1
locales
product_logo_256.png
resources.pak
apparmor.cfg
v8_context_snapshot.bin
vk_swiftshader_icd.json
xdg-mime
xdg-settings
EOF
)" ] || {
    echo "artifact runtime top-level inventory is invalid" >&2
    exit 1
}
[ -x "${runtime}/helium" ] && [ -x "${runtime}/helium-wrapper" ] && \
    [ -f "${manifest}" ] || {
    echo "artifact runtime or manifest is missing" >&2
    exit 1
}

manifest_keys=(
    arch
    chromium_commit
    chromium_version
    depot_tools_commit
    gn_args_sha256
    helium_core_commit
    helium_passwords_commit
    helium_sync_commit
    nix_provenance_sha256
    patch_inventory_sha256
    platform
    platform_commit
    platform_repository
    product
    runtime_inventory_sha256
    packaging_tool_commit
    packaging_tool_sha256
    full_graph_receipt_sha256
    full_graph_inventory_sha256
    schema_version
    source_commit
    source_tree
    target
    build_job_id
)
mapfile -t actual_keys < <(awk -F= 'NF { print $1 }' "${manifest}" | sort)
[ "$(printf '%s\n' "${manifest_keys[@]}" | sort)" = "$(printf '%s\n' "${actual_keys[@]}")" ] || {
    echo "artifact manifest field inventory is invalid" >&2
    exit 1
}
value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' "${manifest}"
}

build_config="${product_root}/helium-passwords.conf"
[ ! -f "${product_root}/go.mod" ] || build_config="${product_root}/helium-sync.conf"
# shellcheck source=/dev/null
. "${build_config}"
expected_nix_source=$(sha256sum "${product_root}/chromium/nix/chromiumer-shell.nix" | awk '{ print $1 }')
[ "$(value schema_version)" = 4 ] && \
    [ "$(value product)" = "${product}" ] && \
    [ "$(value platform)" = linux ] && \
    [ "$(value arch)" = "${arch}" ] && \
    [ "$(value target)" = "${target}" ] && \
    [ "$(value source_commit)" = "${expected_source}" ] && \
    [ "$(value source_tree)" = "${expected_tree}" ] && \
    [ "$(value helium_passwords_commit)" = "${expected_passwords}" ] && \
    [ "$(value helium_sync_commit)" = "${expected_sync}" ] && \
    [ "$(value helium_core_commit)" = "${expected_core}" ] && \
    [ "$(value chromium_version)" = "${expected_version}" ] && \
    [ "$(value chromium_commit)" = "${expected_chromium}" ] && \
    [ "$(value build_job_id)" = "$(admission_value build_job_id)" ] && \
    [ "$(value platform_repository)" = "${HELIUM_LINUX_REPO}" ] && \
    [ "$(value platform_commit)" = "${HELIUM_LINUX_PLATFORM_COMMIT}" ] && \
    [ "$(value depot_tools_commit)" = \
        "${HELIUM_LINUX_DEPOT_TOOLS_COMMIT}" ] && \
    [[ "$(value packaging_tool_commit)" =~ ^[0-9a-f]{40}$ ]] || {
    echo "artifact manifest does not match this audited source train" >&2
    exit 1
}
[ "$(value gn_args_sha256)" = "$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')" ] && \
    [ "$(value nix_provenance_sha256)" = "$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')" ] && \
    [ "$(value patch_inventory_sha256)" = "$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')" ] && \
    [ "$(value runtime_inventory_sha256)" = "$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')" ] && \
    [ "$(value packaging_tool_sha256)" = \
        "$(sha256sum "${provenance}/full-graph/packaging-tool.sh" | awk '{ print $1 }')" ] && \
    [ "$(value full_graph_receipt_sha256)" = \
        "$(sha256sum "${provenance}/full-graph/receipt.env" | awk '{ print $1 }')" ] && \
    [ "$(value full_graph_inventory_sha256)" = \
        "$(sha256sum "${provenance}/full-graph/SHA256SUMS" | awk '{ print $1 }')" ] || {
    echo "artifact provenance hash mismatch" >&2
    exit 1
}
graph="${provenance}/full-graph"
expected_graph_files=(
    SHA256SUMS
    build-operator.sh
    build.ninja
    build_ai_skills.mjs
    capture-tool.sh
    chromium-commit.txt
    deployment-receipt-tool.sh
    finalizer-tool.sh
    full-graph-audit-tool.mjs
    full-targets-query.txt
    generate_css.gni
    generate_css_js_files.js
    boundary-receipt.env
    ninja-query.txt
    ninja-binary
    ninja-shim
    ninja-version.txt
    packaging-tool.sh
    platform-commit.txt
    platform-shared.sh
    product-commit.txt
    receipt.env
    repair-tool.sh
    toolchain.ninja
)
mapfile -t actual_graph_files < <(
    find "${graph}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort
)
[ "$(printf '%s\n' "${expected_graph_files[@]}" | sort)" = \
    "$(printf '%s\n' "${actual_graph_files[@]}")" ] && \
    [ "$(find "${graph}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" = "" ] || {
    echo "artifact full-graph file inventory is invalid" >&2
    exit 1
}
for graph_file in "${expected_graph_files[@]}"; do
    [ ! -L "${graph}/${graph_file}" ] || {
        echo "artifact full-graph evidence contains a symlink" >&2
        exit 1
    }
done
(
    cd "${graph}"
    sha256sum --strict --check SHA256SUMS
) >/dev/null
mapfile -t graph_inventory_paths < <(awk '{ print $2 }' "${graph}/SHA256SUMS" | sort)
mapfile -t graph_payload_paths < <(
    find "${graph}" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort
)
[ "$(printf '%s\n' "${graph_inventory_paths[@]}")" = \
    "$(printf '%s\n' "${graph_payload_paths[@]}")" ] || {
    echo "artifact full-graph checksum inventory is incomplete" >&2
    exit 1
}
graph_keys=(
    ai_skill_action_present
    arch
    build_ai_skills_sha256
    build_ninja_sha256
    build_operator_sha256
    capture_tool_sha256
    captured_at
    chromium_commit
    css_action_edges
    css_action_edges_without_tsconfig
    full_targets
    full_targets_query_sha256
    full_graph_audit_tool_sha256
    generate_css_gni_sha256
    generate_css_js_sha256
    graph_validation
    helium_core_commit
    helium_passwords_commit
    helium_sync_commit
    job
    boundary_receipt_sha256
    deployment_receipt_tool_sha256
    finalizer_tool_sha256
    ninja_query_sha256
    ninja_binary_sha256
    ninja_shim_sha256
    ninja_version_sha256
    node_version
    packaging_tool_sha256
    platform_commit
    platform_shared_sha256
    product
    repair_tool_sha256
    schema
    target
    toolchain_ninja_sha256
    ui_css_outputs_materialized_before_full_build
    ui_css_phony_orders_all_outputs
    ui_downstream_orders_css_phony
)
mapfile -t actual_graph_keys < <(awk -F= 'NF { print $1 }' "${graph}/receipt.env" | sort)
[ "$(printf '%s\n' "${graph_keys[@]}" | sort)" = \
    "$(printf '%s\n' "${actual_graph_keys[@]}")" ] || {
    echo "artifact full-graph receipt field inventory is invalid" >&2
    exit 1
}
graph_value() {
    awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' \
        "${graph}/receipt.env"
}
[ "$(graph_value schema)" = helium-linux-full-graph-evidence-v3 ] && \
    [ "$(graph_value job)" = "$(value build_job_id)" ] && \
    [ "$(graph_value product)" = "${product}" ] && \
    [ "$(graph_value arch)" = "${arch}" ] && \
    [ "$(graph_value target)" = "${target}" ] && \
    [ "$(graph_value helium_sync_commit)" = "${expected_sync}" ] && \
    [ "$(graph_value helium_passwords_commit)" = "${expected_passwords}" ] && \
    [ "$(graph_value helium_core_commit)" = "${expected_core}" ] && \
    [ "$(graph_value chromium_commit)" = "${expected_chromium}" ] && \
    [ "$(graph_value platform_commit)" = "${HELIUM_LINUX_PLATFORM_COMMIT}" ] && \
    [ "$(graph_value node_version)" = v22.14.0 ] && \
    [ "$(graph_value full_targets)" = chrome,chromedriver ] && \
    [[ "$(graph_value css_action_edges)" =~ ^[1-9][0-9]*$ ]] && \
    [ "$(graph_value css_action_edges_without_tsconfig)" = 0 ] && \
    [ "$(graph_value ui_css_outputs_materialized_before_full_build)" = false ] && \
    [ "$(graph_value ui_css_phony_orders_all_outputs)" = true ] && \
    [ "$(graph_value ui_downstream_orders_css_phony)" = true ] && \
    [ "$(graph_value ai_skill_action_present)" = true ] && \
    [ "$(graph_value graph_validation)" = passed ] && \
    [[ "$(graph_value captured_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "artifact full-graph receipt is source- or job-mismatched" >&2
    exit 1
}
graph_hash_bindings=(
    build_ninja_sha256:build.ninja
    toolchain_ninja_sha256:toolchain.ninja
    generate_css_gni_sha256:generate_css.gni
    generate_css_js_sha256:generate_css_js_files.js
    build_ai_skills_sha256:build_ai_skills.mjs
    platform_shared_sha256:platform-shared.sh
    build_operator_sha256:build-operator.sh
    ninja_shim_sha256:ninja-shim
    ninja_binary_sha256:ninja-binary
    ninja_version_sha256:ninja-version.txt
    ninja_query_sha256:ninja-query.txt
    full_targets_query_sha256:full-targets-query.txt
    boundary_receipt_sha256:boundary-receipt.env
    capture_tool_sha256:capture-tool.sh
    packaging_tool_sha256:packaging-tool.sh
    deployment_receipt_tool_sha256:deployment-receipt-tool.sh
    finalizer_tool_sha256:finalizer-tool.sh
    full_graph_audit_tool_sha256:full-graph-audit-tool.mjs
    repair_tool_sha256:repair-tool.sh
)
for binding in "${graph_hash_bindings[@]}"; do
    graph_field=${binding%%:*}
    graph_file=${binding#*:}
    [ "$(graph_value "${graph_field}")" = \
        "$(sha256sum "${graph}/${graph_file}" | awk '{ print $1 }')" ] || {
        echo "artifact full-graph receipt does not bind ${graph_file}" >&2
        exit 1
    }
done
[ "$(<"${graph}/product-commit.txt")" = "${expected_source}" ] && \
    [ "$(<"${graph}/chromium-commit.txt")" = "${expected_chromium}" ] && \
    [ "$(<"${graph}/platform-commit.txt")" = "${HELIUM_LINUX_PLATFORM_COMMIT}" ] || {
    echo "artifact full-graph concrete checkout identities are invalid" >&2
    exit 1
}
node "${tool_root}/scripts/linux-full-graph-audit.mjs" "${graph}" >/dev/null
[ "$(admission_value helium_passwords_commit)" = "${expected_passwords}" ] && \
    [ "$(admission_value helium_sync_commit)" = "${expected_sync}" ] && \
    [ "$(admission_value helium_core_commit)" = "${expected_core}" ] && \
    [ "$(admission_value chromium_commit)" = "${expected_chromium}" ] && \
    [ "$(admission_value provenance_sha256)" = \
        "$(sha256sum "${manifest}" | awk '{ print $1 }')" ] && \
    [ "$(admission_value full_graph_receipt_sha256)" = \
        "$(value full_graph_receipt_sha256)" ] && \
    [ "$(admission_value full_graph_inventory_sha256)" = \
        "$(value full_graph_inventory_sha256)" ] || {
    echo "deployment receipt does not bind the runtime provenance" >&2
    exit 1
}
grep -Fqx "chromium_commit=${expected_chromium}" "${provenance}/chromiumer-nix.env"
grep -Fqx "environment_source_sha256=${expected_nix_source}" "${provenance}/chromiumer-nix.env"
grep -Eq '^nix_environment=/nix/store/[a-z0-9]+-' "${provenance}/chromiumer-nix.env"
grep -Eq '^nix_derivation=/nix/store/[a-z0-9]+-.*\.drv$' "${provenance}/chromiumer-nix.env"
grep -Eq '^closure_sha256=[0-9a-f]{64}$' "${provenance}/chromiumer-nix.env"
grep -Eq '^closure_bytes=[1-9][0-9]*$' "${provenance}/chromiumer-nix.env"
(
    cd "${product_root}"
    sha256sum --check "${provenance}/patches.sha256"
)
(
    cd "${bundle}"
    sha256sum --check provenance/runtime.sha256
)
mapfile -t hashed_runtime < <(awk '{ print $2 }' "${provenance}/runtime.sha256" | sort)
mapfile -t actual_runtime < <(cd "${bundle}" && find runtime -type f -print | sort)
[ "$(printf '%s\n' "${hashed_runtime[@]}")" = "$(printf '%s\n' "${actual_runtime[@]}")" ] || {
    echo "artifact runtime file inventory is invalid" >&2
    exit 1
}
case "${arch}" in
    x86_64) target_cpu=x64 ;;
    arm64) target_cpu=arm64 ;;
    *) exit 2 ;;
esac
grep -Fqx "target_cpu = \"${target_cpu}\"" "${provenance}/gn-args.txt" || {
    echo "artifact GN args do not identify ${arch}" >&2
    exit 1
}

browser_relative="${archive_root}/runtime/helium-wrapper"
browser="${temporary}/${browser_relative}"
install -m 0600 "${deployment_receipt}" \
    "${temporary}/deployment-artifact-receipt.env"
receipt="${temporary}/artifact-receipt.env"
cat >"${receipt}" <<EOF
schema_version=3
product=${product}
platform=linux
arch=${arch}
source_commit=${expected_source}
helium_core_commit=${expected_core}
chromium_version=${expected_version}
chromium_commit=${expected_chromium}
platform_commit=${HELIUM_LINUX_PLATFORM_COMMIT}
bundle=${artifact}
bundle_sha256=$(sha256sum "${artifact}" | awk '{ print $1 }')
provenance_manifest_sha256=$(sha256sum "${manifest}" | awk '{ print $1 }')
browser_executable=${browser_relative}
browser_sha256=$(sha256sum "${browser}" | awk '{ print $1 }')
runtime_inventory=${archive_root}/provenance/runtime.sha256
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
full_graph_receipt=${archive_root}/provenance/full-graph/receipt.env
full_graph_receipt_sha256=$(value full_graph_receipt_sha256)
full_graph_inventory=${archive_root}/provenance/full-graph/SHA256SUMS
full_graph_inventory_sha256=$(value full_graph_inventory_sha256)
verified_at=$(date --iso-8601=seconds)
EOF
chmod 600 "${receipt}"
mv --no-clobber "${temporary}" "${destination}"
trap - EXIT
printf 'browser=%s\nreceipt=%s\n' \
    "${destination}/${browser_relative}" "${destination}/artifact-receipt.env"
