#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/package-linux-runtime.sh PRODUCT ARCH TARGET BUILD-JOB-ID PLATFORM-CHECKOUT FULL-GRAPH-EVIDENCE OUTPUT.tar.xz OUTPUT.receipt.env
EOF
}

[ "$#" -eq 8 ] || {
    usage
    exit 2
}

product=$1
arch=$2
target=$3
build_job_id=$4
checkout=$(realpath -e "$5")
full_graph=$(realpath -e "$6")
output=$7
receipt=$8
tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
product_root=$(realpath -e "${HELIUM_PRODUCT_SOURCE_ROOT:-$tool_root}")
source_info=$("${product_root}/scripts/linux-product-provenance.sh" \
    "${product}" "${arch}" "${target}")
[[ "${build_job_id}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || {
    echo "invalid build job id" >&2
    exit 2
}
source_value() {
    awk -F= -v key="$1" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${source_info}"
}
source_commit=$(source_value source_commit)
source_tree=$(source_value source_tree)
passwords_commit=$(source_value helium_passwords_commit)
sync_commit=$(source_value helium_sync_commit)
core_commit=$(source_value helium_core_commit)
chromium_version=$(source_value chromium_version)
chromium_commit=$(source_value chromium_commit)
output_parent=$(realpath -m "$(dirname "${output}")")
output="${output_parent}/$(basename "${output}")"
receipt_parent=$(realpath -m "$(dirname "${receipt}")")
receipt="${receipt_parent}/$(basename "${receipt}")"
bundle_name="${product}-linux-${arch}"
source_dir="${checkout}/build/src"
out_dir="${source_dir}/out/Default"

[ "$(basename "${output}")" = "${bundle_name}.tar.xz" ] && \
    [ "$(basename "${receipt}")" = "${bundle_name}.receipt.env" ] || {
    echo "artifact and receipt names must match explicit product and architecture" >&2
    exit 2
}
[ ! -e "${output}" ] && [ ! -e "${receipt}" ] || {
    echo "refusing to replace existing artifact or receipt" >&2
    exit 1
}
for path in "${checkout}/.helium-platform-source.env" "${out_dir}/args.gn" \
    "${out_dir}/helium" "${source_dir}/.git"; do
    [ -e "${path}" ] || {
        echo "missing completed Linux build input: ${path}" >&2
        exit 1
    }
done
[ -z "$(git -C "${product_root}" status --porcelain --untracked-files=all)" ] && \
    [ -z "$(git -C "${tool_root}" status --porcelain --untracked-files=all)" ] || {
    echo "product and packaging-tool sources must be clean before packaging" >&2
    exit 1
}

[ "$(git -C "${product_root}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "Helium checkout does not match its committed gitlink" >&2
    exit 1
}
[ "$(git -C "${checkout}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "prepared Linux checkout uses the wrong Helium core" >&2
    exit 1
}

build_config="${product_root}/helium-passwords.conf"
[ ! -f "${product_root}/go.mod" ] || build_config="${product_root}/helium-sync.conf"
# shellcheck source=/dev/null
. "${build_config}"
platform_commit=$(git -C "${checkout}" rev-parse HEAD)
[ "${platform_commit}" = "${HELIUM_LINUX_PLATFORM_COMMIT}" ] || {
    echo "prepared Linux checkout uses the wrong platform commit" >&2
    exit 1
}
platform_value() {
    awk -F= -v key="$1" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        "${checkout}/.helium-platform-source.env"
}
[ "$(platform_value platform_source_schema_version)" = 2 ] && \
    [ "$(platform_value platform_commit)" = "${platform_commit}" ] && \
    [ "$(platform_value helium_core_commit)" = "${core_commit}" ] && \
    [ "$(platform_value depot_tools_commit)" = \
        "${HELIUM_LINUX_DEPOT_TOOLS_COMMIT}" ] || {
    echo "prepared Linux checkout has invalid source-toolchain provenance" >&2
    exit 1
}
[ "$(git -C "${source_dir}" rev-parse HEAD)" = "${chromium_commit}" ] || {
    echo "built Chromium source does not match the locked commit" >&2
    exit 1
}
case "${arch}" in
    x86_64) target_cpu=x64 ;;
    arm64) target_cpu=arm64 ;;
    *) exit 2 ;;
esac
grep -Fqx "target_cpu = \"${target_cpu}\"" "${out_dir}/args.gn" || {
    echo "Linux GN args do not identify ${arch}" >&2
    exit 1
}

[ -d "${full_graph}" ] && [ ! -L "${full_graph}" ] && \
    [ "$(stat -c %a "${full_graph}")" = 700 ] || {
    echo "full-graph evidence must be a private real directory" >&2
    exit 1
}
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
    find "${full_graph}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort
)
[ "$(printf '%s\n' "${expected_graph_files[@]}" | sort)" = \
    "$(printf '%s\n' "${actual_graph_files[@]}")" ] && \
    [ "$(find "${full_graph}" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" = "" ] || {
    echo "full-graph evidence has an invalid file inventory" >&2
    exit 1
}
for graph_file in "${expected_graph_files[@]}"; do
    [ -f "${full_graph}/${graph_file}" ] && \
        [ ! -L "${full_graph}/${graph_file}" ] && \
        [ "$(stat -c %a "${full_graph}/${graph_file}")" = 600 ] || {
        echo "full-graph evidence file is unsafe: ${graph_file}" >&2
        exit 1
    }
done
(
    cd "${full_graph}"
    sha256sum --strict --check SHA256SUMS
) >/dev/null
mapfile -t graph_inventory_paths < <(awk '{ print $2 }' "${full_graph}/SHA256SUMS" | sort)
mapfile -t graph_payload_paths < <(
    find "${full_graph}" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort
)
[ "$(printf '%s\n' "${graph_inventory_paths[@]}")" = \
    "$(printf '%s\n' "${graph_payload_paths[@]}")" ] || {
    echo "full-graph checksum inventory is incomplete" >&2
    exit 1
}
graph_value() {
    awk -F= -v key="$1" '
        $1 == key { count++; value=substr($0,length(key)+2) }
        END { if (count == 1 && value != "") print value; else exit 1 }
    ' "${full_graph}/receipt.env"
}
[ "$(graph_value schema)" = helium-linux-full-graph-evidence-v3 ] && \
    [ "$(graph_value job)" = "${build_job_id}" ] && \
    [ "$(graph_value product)" = "${product}" ] && \
    [ "$(graph_value arch)" = "${arch}" ] && \
    [ "$(graph_value target)" = "${target}" ] && \
    [ "$(graph_value helium_sync_commit)" = "${sync_commit}" ] && \
    [ "$(graph_value helium_passwords_commit)" = "${passwords_commit}" ] && \
    [ "$(graph_value helium_core_commit)" = "${core_commit}" ] && \
    [ "$(graph_value chromium_commit)" = "${chromium_commit}" ] && \
    [ "$(graph_value platform_commit)" = "${platform_commit}" ] && \
    [ "$(graph_value node_version)" = v22.14.0 ] && \
    [ "$(graph_value full_targets)" = chrome,chromedriver ] && \
    [ "$(graph_value graph_validation)" = passed ] || {
    echo "full-graph receipt is not bound to this build" >&2
    exit 1
}
[ "$(<"${full_graph}/product-commit.txt")" = "${source_commit}" ] && \
    [ "$(<"${full_graph}/chromium-commit.txt")" = "${chromium_commit}" ] && \
    [ "$(<"${full_graph}/platform-commit.txt")" = "${platform_commit}" ] && \
    [ "$(sha256sum "${full_graph}/packaging-tool.sh" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/package-linux-runtime.sh" | awk '{print $1}')" ] && \
    [ "$(sha256sum "${full_graph}/capture-tool.sh" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/capture-linux-full-graph-evidence.sh" | awk '{print $1}')" ] && \
    [ "$(sha256sum "${full_graph}/deployment-receipt-tool.sh" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/write-deployment-artifact-receipt.sh" | awk '{print $1}')" ] && \
    [ "$(sha256sum "${full_graph}/finalizer-tool.sh" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/finalize-retained-linux-full-graph.sh" | awk '{print $1}')" ] && \
    [ "$(sha256sum "${full_graph}/full-graph-audit-tool.mjs" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/linux-full-graph-audit.mjs" | awk '{print $1}')" ] && \
    [ "$(sha256sum "${full_graph}/repair-tool.sh" | awk '{print $1}')" = \
        "$(sha256sum "${tool_root}/scripts/continue-retained-linux-full-graph-failure.sh" | awk '{print $1}')" ] || {
    echo "full-graph concrete source or tooling binding changed" >&2
    exit 1
}
full_graph_receipt_sha256=$(sha256sum "${full_graph}/receipt.env" | awk '{ print $1 }')
full_graph_inventory_sha256=$(sha256sum "${full_graph}/SHA256SUMS" | awk '{ print $1 }')
packaging_tool_sha256=$(sha256sum "${tool_root}/scripts/package-linux-runtime.sh" | awk '{ print $1 }')
packaging_tool_commit=$(git -C "${tool_root}" rev-parse HEAD)
node "${tool_root}/scripts/linux-full-graph-audit.mjs" "${full_graph}" >/dev/null

mkdir -p "${output_parent}"
mkdir -p "${receipt_parent}"
temporary=$(mktemp -d "${output_parent}/.helium-linux-package.XXXXXX")
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT
bundle="${temporary}/${bundle_name}"
runtime="${bundle}/runtime"
provenance="${bundle}/provenance"
mkdir -p "${runtime}" "${provenance}"

runtime_entries=(
    helium
    chrome_100_percent.pak
    chrome_200_percent.pak
    helium_crashpad_handler
    chromedriver
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
    v8_context_snapshot.bin
    vk_swiftshader_icd.json
    xdg-mime
    xdg-settings
)
for entry in "${runtime_entries[@]}"; do
    [ -e "${out_dir}/${entry}" ] || {
        echo "built Linux runtime is missing ${entry}" >&2
        exit 1
    }
    cp -a "${out_dir}/${entry}" "${runtime}/"
done
cp -a "${checkout}/package/helium.desktop" "${runtime}/"
cp -a "${checkout}/package/apparmor.cfg" "${runtime}/"
cp -a "${checkout}/package/helium-wrapper.sh" "${runtime}/helium-wrapper"
ln -s helium "${runtime}/chrome"
[ -x "${runtime}/helium" ] && [ -x "${runtime}/helium-wrapper" ] || {
    echo "packaged Helium browser or wrapper is not executable" >&2
    exit 1
}

cp "${out_dir}/args.gn" "${provenance}/gn-args.txt"
cp -a "${full_graph}" "${provenance}/full-graph"
"${product_root}/scripts/chromiumer-nix.sh" provenance >"${provenance}/chromiumer-nix.env"
"${product_root}/scripts/patch-inventory.sh" >"${provenance}/patches.sha256"
(
    cd "${bundle}"
    find runtime -type f -print0 | sort -z | xargs -0 sha256sum >provenance/runtime.sha256
)
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
cat >"${provenance}/manifest.env" <<EOF
schema_version=4
product=${product}
platform=linux
arch=${arch}
target=${target}
source_commit=${source_commit}
source_tree=${source_tree}
helium_passwords_commit=${passwords_commit}
helium_sync_commit=${sync_commit}
helium_core_commit=${core_commit}
chromium_version=${chromium_version}
chromium_commit=${chromium_commit}
build_job_id=${build_job_id}
platform_repository=${HELIUM_LINUX_REPO}
platform_commit=${platform_commit}
depot_tools_commit=${HELIUM_LINUX_DEPOT_TOOLS_COMMIT}
gn_args_sha256=${gn_args_sha256}
nix_provenance_sha256=${nix_provenance_sha256}
patch_inventory_sha256=${patch_inventory_sha256}
runtime_inventory_sha256=${runtime_inventory_sha256}
packaging_tool_commit=${packaging_tool_commit}
packaging_tool_sha256=${packaging_tool_sha256}
full_graph_receipt_sha256=${full_graph_receipt_sha256}
full_graph_inventory_sha256=${full_graph_inventory_sha256}
EOF

archive="${temporary}/$(basename "${output}")"
tar --create --xz --file="${archive}" --directory="${temporary}" "${bundle_name}"
provenance_sha256=$(sha256sum "${provenance}/manifest.env" | awk '{ print $1 }')
staged_receipt="${temporary}/$(basename "${receipt}")"
"${tool_root}/scripts/write-deployment-artifact-receipt.sh" \
    "${archive}" "${target}" "${sync_commit}" "${passwords_commit}" \
    "${core_commit}" "${chromium_commit}" "${build_job_id}" \
    "${provenance_sha256}" "${full_graph_receipt_sha256}" \
    "${full_graph_inventory_sha256}" "${staged_receipt}" >/dev/null
mv --no-clobber "${archive}" "${output}"
mv --no-clobber "${staged_receipt}" "${receipt}"
[ -f "${output}" ] && [ -f "${receipt}" ] || {
    echo "failed to publish Linux artifact and receipt" >&2
    exit 1
}
printf 'artifact=%s\nreceipt=%s\nsha256=%s\n' \
    "${output}" "${receipt}" "$(sha256sum "${output}" | awk '{ print $1 }')"
