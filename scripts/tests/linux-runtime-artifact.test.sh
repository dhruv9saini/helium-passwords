#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
temporary=$(mktemp -d /tmp/helium-linux-artifact-test.XXXXXX)
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT

# shellcheck source=../../linux-product.conf
# shellcheck disable=SC1091
. "${repo_root}/linux-product.conf"
product=${HELIUM_LINUX_PRODUCT}
nix_source=$(sha256sum "${repo_root}/chromium/nix/chromiumer-shell.nix" |
    awk '{ print $1 }')

source_value() {
    local source_info=$1
    local key=$2
    awk -F= -v key="${key}" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${source_info}"
}

make_fixture() {
    local arch=$1
    local target=$2
    local stage="${temporary}/stage-${arch}"
    local bundle_name="${product}-linux-${arch}"
    local bundle="${stage}/${bundle_name}"
    local runtime="${bundle}/runtime"
    local provenance="${bundle}/provenance"
    local source_info source_commit source_tree passwords_commit sync_commit
    local core_commit chromium_version chromium_commit target_cpu job
    local artifact receipt verification output provenance_sha

    source_info=$("${repo_root}/scripts/linux-product-provenance.sh" \
        "${product}" "${arch}" "${target}")
    source_commit=$(source_value "${source_info}" source_commit)
    source_tree=$(source_value "${source_info}" source_tree)
    passwords_commit=$(source_value "${source_info}" helium_passwords_commit)
    sync_commit=$(source_value "${source_info}" helium_sync_commit)
    core_commit=$(source_value "${source_info}" helium_core_commit)
    chromium_version=$(source_value "${source_info}" chromium_version)
    chromium_commit=$(source_value "${source_info}" chromium_commit)
    case "${arch}" in
        x86_64) target_cpu=x64 ;;
        arm64) target_cpu=arm64 ;;
        *) exit 2 ;;
    esac
    job="synthetic-${arch}-01"

    mkdir -p "${runtime}/locales" "${provenance}"
    for file in \
        chrome_100_percent.pak chrome_200_percent.pak chromedriver \
        helium_crashpad_handler icudtl.dat libEGL.so libGLESv2.so \
        libqt5_shim.so libqt6_shim.so libvk_swiftshader.so libvulkan.so.1 \
        product_logo_256.png resources.pak v8_context_snapshot.bin \
        vk_swiftshader_icd.json xdg-mime xdg-settings; do
        printf 'synthetic %s %s\n' "${arch}" "${file}" >"${runtime}/${file}"
    done
    printf '#!/bin/sh\nexit 0\n' >"${runtime}/helium"
    chmod 755 "${runtime}/helium"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nexec "$(dirname "$0")/helium" "$@"\n' \
        >"${runtime}/helium-wrapper"
    chmod 755 "${runtime}/helium-wrapper"
    printf 'synthetic desktop entry\n' >"${runtime}/helium.desktop"
    printf 'synthetic apparmor policy\n' >"${runtime}/apparmor.cfg"
    printf 'synthetic locale\n' >"${runtime}/locales/en-US.pak"
    ln -s helium "${runtime}/chrome"
    printf 'target_cpu = "%s"\n' "${target_cpu}" >"${provenance}/gn-args.txt"
    cat >"${provenance}/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/aaaaaaaaaaaaaaaa-synthetic
nix_derivation=/nix/store/bbbbbbbbbbbbbbbb-synthetic.drv
closure_sha256=$(printf 'a%.0s' {1..64})
closure_bytes=1
chromium_commit=${chromium_commit}
environment_source_sha256=${nix_source}
EOF
    "${repo_root}/scripts/patch-inventory.sh" \
        >"${provenance}/patches.sha256"
    (
        cd "${bundle}"
        find runtime -type f -print0 | sort -z |
            xargs -0 sha256sum >provenance/runtime.sha256
    )
    cat >"${provenance}/manifest.env" <<EOF
schema_version=2
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
build_job_id=${job}
platform_repository=https://github.com/imputnet/helium-linux.git
platform_commit=9fbdff55283c9275f285c49dc054a1ff38dcdc96
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
EOF
    artifact="${temporary}/${bundle_name}.tar.xz"
    receipt="${temporary}/${bundle_name}.receipt.env"
    tar -cJf "${artifact}" -C "${stage}" "${bundle_name}"
    provenance_sha=$(sha256sum "${provenance}/manifest.env" |
        awk '{ print $1 }')
    "${repo_root}/scripts/write-deployment-artifact-receipt.sh" \
        "${artifact}" "${target}" "${sync_commit}" "${passwords_commit}" \
        "${core_commit}" "${chromium_commit}" "${job}" \
        "${provenance_sha}" "${receipt}" >/dev/null

    verification="${temporary}/verified-${arch}"
    output=$("${repo_root}/scripts/verify-linux-runtime.sh" \
        "${product}" "${arch}" "${target}" "${artifact}" "${receipt}" \
        "${verification}")
    grep -Fq \
        "browser=${verification}/${bundle_name}/runtime/helium-wrapper" \
        <<<"${output}"
    grep -Fq "receipt=${verification}/artifact-receipt.env" <<<"${output}"
    grep -Fqx "source_commit=${source_commit}" \
        "${verification}/artifact-receipt.env"
    grep -Fqx "product=${product}" "${verification}/artifact-receipt.env"
    grep -Fqx "arch=${arch}" "${verification}/artifact-receipt.env"
    cmp "${receipt}" "${verification}/deployment-artifact-receipt.env"
    grep -Fqx 'schema_version=1' "${receipt}"
    grep -Fqx "target=${target}" "${receipt}"
    grep -Fqx "helium_passwords_commit=${passwords_commit}" "${receipt}"
    grep -Fqx "helium_sync_commit=${sync_commit}" "${receipt}"
    grep -Fqx "build_job_id=${job}" "${receipt}"
    grep -Fqx "provenance_sha256=${provenance_sha}" "${receipt}"
    "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
        "${artifact}" "${receipt}" "${target}" >/dev/null

    if "${repo_root}/scripts/verify-linux-runtime.sh" \
        "${product}" "${arch}" \
        "$([ "${arch}" = x86_64 ] && echo linux-arm64 || echo linux-x86_64)" \
        "${artifact}" "${receipt}" "${temporary}/wrong-target-${arch}" \
        >/dev/null 2>&1; then
        echo "wrong explicit Linux target passed verification" >&2
        exit 1
    fi
}

make_fixture x86_64 "${HELIUM_LINUX_X86_64_TARGET}"
make_fixture arm64 "${HELIUM_LINUX_ARM64_TARGET}"

artifact="${temporary}/${product}-linux-x86_64.tar.xz"
receipt="${temporary}/${product}-linux-x86_64.receipt.env"
cp "${receipt}" "${temporary}/unknown-field.receipt.env"
printf 'legacy_field=forbidden\n' >>"${temporary}/unknown-field.receipt.env"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${artifact}" "${temporary}/unknown-field.receipt.env" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "receipt with a legacy field passed verification" >&2
    exit 1
fi
cp "${receipt}" "${temporary}/wrong-schema.receipt.env"
sed -i 's/^schema_version=1$/schema_version=2/' \
    "${temporary}/wrong-schema.receipt.env"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${artifact}" "${temporary}/wrong-schema.receipt.env" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "unsupported receipt schema passed verification" >&2
    exit 1
fi
cp "${artifact}" "${temporary}/tampered.tar.xz"
printf tamper >>"${temporary}/tampered.tar.xz"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${temporary}/tampered.tar.xz" "${receipt}" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "tampered Linux artifact passed deployment verification" >&2
    exit 1
fi
if "${repo_root}/scripts/linux-product-provenance.sh" \
    helium-sync x86_64 linux-x86_64 >/dev/null 2>&1; then
    echo "wrong product passed the public repository binding" >&2
    exit 1
fi

grep -q 'bash scripts/build.sh -c' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
# shellcheck disable=SC2016
grep -q 'ARCH="${arch}"' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'write-deployment-artifact-receipt.sh' \
    "${repo_root}/scripts/package-linux-runtime.sh"
if grep -q '^schema_version=1' \
    "${repo_root}/scripts/package-linux-runtime.sh"; then
    echo "packager hand-authors the deployment receipt" >&2
    exit 1
fi
grep -q 'nodejs_22' "${repo_root}/chromium/nix/chromiumer-shell.nix"
grep -q 'ninja' "${repo_root}/chromium/nix/chromiumer-shell.nix"
printf 'linux_runtime_artifact=passed\n'
