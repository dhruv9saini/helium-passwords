#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/package-linux-runtime.sh PRODUCT ARCH TARGET BUILD-JOB-ID PLATFORM-CHECKOUT OUTPUT.tar.xz OUTPUT.receipt.env
EOF
}

[ "$#" -eq 7 ] || {
    usage
    exit 2
}

product=$1
arch=$2
target=$3
build_job_id=$4
checkout=$(realpath -e "$5")
output=$6
receipt=$7
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
source_info=$("${root_dir}/scripts/linux-product-provenance.sh" \
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
[ -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ] || {
    echo "Helium source must be clean before packaging" >&2
    exit 1
}

[ "$(git -C "${root_dir}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "Helium checkout does not match its committed gitlink" >&2
    exit 1
}
[ "$(git -C "${checkout}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "prepared Linux checkout uses the wrong Helium core" >&2
    exit 1
}

# shellcheck source=../helium-passwords.conf
# shellcheck disable=SC1091
. "${root_dir}/helium-passwords.conf"
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
"${root_dir}/scripts/chromiumer-nix.sh" provenance >"${provenance}/chromiumer-nix.env"
"${root_dir}/scripts/patch-inventory.sh" >"${provenance}/patches.sha256"
(
    cd "${bundle}"
    find runtime -type f -print0 | sort -z | xargs -0 sha256sum >provenance/runtime.sha256
)
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
cat >"${provenance}/manifest.env" <<EOF
schema_version=3
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
EOF

archive="${temporary}/$(basename "${output}")"
tar --create --xz --file="${archive}" --directory="${temporary}" "${bundle_name}"
provenance_sha256=$(sha256sum "${provenance}/manifest.env" | awk '{ print $1 }')
staged_receipt="${temporary}/$(basename "${receipt}")"
"${root_dir}/scripts/write-deployment-artifact-receipt.sh" \
    "${archive}" "${target}" "${sync_commit}" "${passwords_commit}" \
    "${core_commit}" "${chromium_commit}" "${build_job_id}" \
    "${provenance_sha256}" "${staged_receipt}" >/dev/null
mv --no-clobber "${archive}" "${output}"
mv --no-clobber "${staged_receipt}" "${receipt}"
[ -f "${output}" ] && [ -f "${receipt}" ] || {
    echo "failed to publish Linux artifact and receipt" >&2
    exit 1
}
printf 'artifact=%s\nreceipt=%s\nsha256=%s\n' \
    "${output}" "${receipt}" "$(sha256sum "${output}" | awk '{ print $1 }')"
