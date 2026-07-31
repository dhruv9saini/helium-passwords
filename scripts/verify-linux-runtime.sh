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
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
source_info=$("${root_dir}/scripts/linux-product-provenance.sh" \
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
    "${root_dir}/scripts/verify-deployment-artifact-receipt.sh" \
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

build_config="${root_dir}/helium-passwords.conf"
[ ! -f "${root_dir}/go.mod" ] || build_config="${root_dir}/helium-sync.conf"
# shellcheck source=/dev/null
. "${build_config}"
expected_nix_source=$(sha256sum "${root_dir}/chromium/nix/chromiumer-shell.nix" | awk '{ print $1 }')
[ "$(value schema_version)" = 3 ] && \
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
        "${HELIUM_LINUX_DEPOT_TOOLS_COMMIT}" ] || {
    echo "artifact manifest does not match this audited source train" >&2
    exit 1
}
[ "$(value gn_args_sha256)" = "$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')" ] && \
    [ "$(value nix_provenance_sha256)" = "$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')" ] && \
    [ "$(value patch_inventory_sha256)" = "$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')" ] && \
    [ "$(value runtime_inventory_sha256)" = "$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')" ] || {
    echo "artifact provenance hash mismatch" >&2
    exit 1
}
[ "$(admission_value helium_passwords_commit)" = "${expected_passwords}" ] && \
    [ "$(admission_value helium_sync_commit)" = "${expected_sync}" ] && \
    [ "$(admission_value helium_core_commit)" = "${expected_core}" ] && \
    [ "$(admission_value chromium_commit)" = "${expected_chromium}" ] && \
    [ "$(admission_value provenance_sha256)" = \
        "$(sha256sum "${manifest}" | awk '{ print $1 }')" ] || {
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
    cd "${root_dir}"
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
schema_version=2
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
verified_at=$(date --iso-8601=seconds)
EOF
chmod 600 "${receipt}"
mv --no-clobber "${temporary}" "${destination}"
trap - EXIT
printf 'browser=%s\nreceipt=%s\n' \
    "${destination}/${browser_relative}" "${destination}/artifact-receipt.env"
