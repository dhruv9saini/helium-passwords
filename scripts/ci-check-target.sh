#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-check-target.sh <linux|macos|windows> <x86_64|arm64>

Prepare one platform checkout and verify that the password overlay is injected
for the requested target.
EOF
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

platform="$1"
arch="$2"

case "${platform}" in
    linux|macos|windows) ;;
    *)
        echo "unknown platform: ${platform}" >&2
        usage
        exit 2
        ;;
esac

case "${arch}" in
    x86_64|arm64) ;;
    *)
        echo "unsupported arch: ${arch}" >&2
        usage
        exit 2
        ;;
esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
checkout="$("${root_dir}/scripts/prepare-platform.sh" \
    --skip-submodules "${platform}" "${root_dir}/build/platforms/${platform}")"

grep -qx 'helium/passwords/restore-password-autofill.patch' \
    "${checkout}/patches/series"
grep -qx 'helium/passwords/restore-password-ui.patch' \
    "${checkout}/patches/series"

cmp -s "${root_dir}/patches/helium-passwords/restore-password-autofill.patch" \
    "${checkout}/patches/helium/passwords/restore-password-autofill.patch"
cmp -s "${root_dir}/patches/helium-passwords/restore-password-ui.patch" \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"

grep -q 'r.PAYMENTS = r.AUTOFILL.createChild' \
    "${checkout}/patches/helium/passwords/restore-password-autofill.patch"
grep -q 'chrome::ShowPaymentMethods' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'kActionShowPaymentsBubbleOrPage' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'PageActionIconType::kVirtualCardEnroll' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'PageActionIconType::kMandatoryReauth' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"

if [ "${platform}" = "linux" ]; then
    grep -q 'GetLibXml2Dirs, GitCherryPick, GetHostSysrootPlatform,' \
        "${checkout}/patches/ungoogled-chromium/portablelinux/fix-compiling-on-arm64.patch"
    grep -q 'test_wrap_static_fns' \
        "${checkout}/patches/ungoogled-chromium/portablelinux/fix-compiling-on-arm64.patch"
fi

if [ "${platform}" = "macos" ]; then
    grep -q 'MACOS_CERTIFICATE:-' \
        "${checkout}/.github/scripts/github_prepare_artifacts.sh"
    grep -q 'SCCACHE_DIR' "${root_dir}/scripts/gha-macos-stage.sh"
fi

if [ "${platform}" = "windows" ]; then
    grep -q 'core.longpaths true' "${root_dir}/scripts/build.sh"
    grep -q 'LongPathsEnabled' "${root_dir}/scripts/build.sh"
    grep -q 'windows_args+=(-j 2)' "${root_dir}/scripts/build.sh"
    grep -q 'Windows staged build' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q 'C:\\helium-windows' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q 'from_artifact: true' "${root_dir}/.github/workflows/windows-build.yml"
fi

echo "target ready: ${platform} ${arch}"
