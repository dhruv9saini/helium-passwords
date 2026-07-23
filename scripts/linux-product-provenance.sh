#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: scripts/linux-product-provenance.sh PRODUCT ARCH TARGET" >&2
}

[ "$#" -eq 3 ] || {
    usage
    exit 2
}
product=$1
arch=$2
target=$3
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

# shellcheck source=../linux-product.conf
# shellcheck disable=SC1091
. "${root_dir}/linux-product.conf"
: "${HELIUM_LINUX_PRODUCT:?}" "${HELIUM_LINUX_PASSWORDS_REF:?}" \
    "${HELIUM_LINUX_SYNC_REF:?}" "${HELIUM_LINUX_X86_64_TARGET:?}" \
    "${HELIUM_LINUX_ARM64_TARGET:?}"
[ "${product}" = "${HELIUM_LINUX_PRODUCT}" ] || {
    echo "product does not match this repository binding: ${product}" >&2
    exit 1
}
case "${arch}" in
    x86_64) expected_target=${HELIUM_LINUX_X86_64_TARGET} ;;
    arm64) expected_target=${HELIUM_LINUX_ARM64_TARGET} ;;
    *) echo "unsupported Linux architecture: ${arch}" >&2; exit 2 ;;
esac
[ "${target}" = "${expected_target}" ] || {
    echo "target does not match product architecture: ${target}" >&2
    exit 1
}
case "${target}" in
    linux-x86_64|linux-arm64|linux-arm64-chroot) ;;
    *) echo "unsupported Linux deployment target: ${target}" >&2; exit 1 ;;
esac

resolve_ref() {
    if [ "$1" = 0000000000000000000000000000000000000000 ]; then
        printf '%s\n' "$1"
    else
        git -C "${root_dir}" rev-parse --verify "$1^{commit}"
    fi
}
source_commit=$(git -C "${root_dir}" rev-parse HEAD)
source_tree=$(git -C "${root_dir}" rev-parse 'HEAD^{tree}')
passwords_commit=$(resolve_ref "${HELIUM_LINUX_PASSWORDS_REF}")
sync_commit=$(resolve_ref "${HELIUM_LINUX_SYNC_REF}")
core_commit=$(git -C "${root_dir}" rev-parse HEAD:helium-chromium)
chromium_version=$(tr -d '\r\n' \
    <"${root_dir}/helium-chromium/chromium_version.txt")
chromium_commit=$(awk -F= \
    '$1 == "HELIUM_ANDROID_CHROMIUM_COMMIT" { print $2; exit }' \
    "${root_dir}/chromium/android-build.lock")

case "${product}" in
    helium-passwords)
        if [ "${passwords_commit}" != "${source_commit}" ] || \
            [ "${sync_commit}" != \
                0000000000000000000000000000000000000000 ]; then
            echo "public product provenance is inconsistent" >&2
            exit 1
        fi
        ;;
    helium-sync)
        if [ "${sync_commit}" != "${source_commit}" ] || \
            [ "${passwords_commit}" = \
                0000000000000000000000000000000000000000 ] || \
            ! git -C "${root_dir}" merge-base --is-ancestor \
                "${passwords_commit}" "${sync_commit}"; then
            echo "private product provenance is inconsistent" >&2
            exit 1
        fi
        ;;
    *) echo "unsupported Linux product: ${product}" >&2; exit 2 ;;
esac

for commit in "${source_commit}" "${passwords_commit}" "${sync_commit}" \
    "${core_commit}" "${chromium_commit}"; do
    [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || {
        echo "Linux product provenance contains a non-full commit" >&2
        exit 1
    }
done
cat <<EOF
product=${product}
arch=${arch}
target=${target}
source_commit=${source_commit}
source_tree=${source_tree}
helium_passwords_commit=${passwords_commit}
helium_sync_commit=${sync_commit}
helium_core_commit=${core_commit}
chromium_version=${chromium_version}
chromium_commit=${chromium_commit}
EOF
