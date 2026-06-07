#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-check-target.sh <linux|macos|windows> <x86_64|arm64>

Prepare one platform checkout and verify that the password and sync overlays
are injected for the requested target.
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

for sync_patch in "${root_dir}"/chromium/patches/*.patch; do
    sync_patch_name="$(basename "${sync_patch}")"
    grep -qx "helium/sync/${sync_patch_name}" \
        "${checkout}/patches/series"
    cmp -s "${sync_patch}" \
        "${checkout}/patches/helium/sync/${sync_patch_name}"
done

grep -q 'r.PAYMENTS = r.AUTOFILL.createChild' \
    "${checkout}/patches/helium/passwords/restore-password-autofill.patch"
grep -q 'chrome::ShowPaymentMethods' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'bwi->GetProfile()->IsGuestSession()' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
! grep -q 'is_guest_session' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'kActionShowPaymentsBubbleOrPage' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'PageActionIconType::kVirtualCardEnroll' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
grep -q 'PageActionIconType::kMandatoryReauth' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"

grep -q 'HeliumPasswordSyncBridge' \
    "${checkout}/patches/helium/sync/0001-helium-sync-overlay-files.patch"
grep -q 'HeliumSyncServiceFactory::GetInstance' \
    "${checkout}/patches/helium/sync/0002-helium-sync-profile-service.patch"
grep -q 'HeliumSyncServiceFactory::GetForProfile(profile)' \
    "${checkout}/patches/helium/sync/0003-helium-sync-android-profile-startup.patch"
grep -q 'PosixKeyProvider' \
    "${checkout}/patches/helium/sync/0004-helium-sync-android-oscrypt-provider.patch"

if [ "${platform}" = "linux" ]; then
    grep -q 'GetLibXml2Dirs, GitCherryPick, GetHostSysrootPlatform,' \
        "${checkout}/patches/ungoogled-chromium/portablelinux/fix-compiling-on-arm64.patch"
    grep -q 'test_wrap_static_fns' \
        "${checkout}/patches/ungoogled-chromium/portablelinux/fix-compiling-on-arm64.patch"
fi

if [ "${platform}" = "macos" ]; then
    grep -q 'MACOS_CERTIFICATE:-' \
        "${checkout}/.github/scripts/github_prepare_artifacts.sh"
    grep -q 'missing macOS dmg asset' \
        "${checkout}/devutils/generate_sparkle_deltas.py"
    grep -q 'if x86_url is None or arm_url is None:' \
        "${checkout}/devutils/generate_sparkle_deltas.py"
    ! grep -q 'assert(False)' \
        "${checkout}/devutils/generate_sparkle_deltas.py"
    grep -q 'SCCACHE_DIR' "${root_dir}/scripts/gha-macos-stage.sh"
    grep -q 'retry_command ./github_fetch_resources.sh' \
        "${root_dir}/scripts/gha-macos-stage.sh"
    grep -q 'build_job_10' \
        "${root_dir}/.github/workflows/macos-build.yml"
    grep -q 'needs: build-10' \
        "${root_dir}/.github/workflows/macos-build.yml"
fi

if [ "${platform}" = "windows" ]; then
    grep -q 'core.longpaths true' "${root_dir}/scripts/build.sh"
    grep -q 'LongPathsEnabled' "${root_dir}/scripts/build.sh"
    grep -q 'windows_args+=(-j 2)' "${root_dir}/scripts/build.sh"
    grep -q 'Windows staged build' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q 'build_part_18' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q "needs.build-18.outputs.finished == 'false'" \
        "${root_dir}/.github/workflows/windows-build.yml"
    grep -Fq 'HELIUM_WINDOWS_ROOT: D:\h' "${root_dir}/.github/workflows/windows-build.yml"
    grep -Fq 'HELIUM_WINDOWS_ROOT_BASH: /d/h' "${root_dir}/.github/workflows/windows-build.yml"
    ! grep -Fq 'helium-windows' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q 'from_artifact: true' "${root_dir}/.github/workflows/windows-build.yml"
    grep -q "tar --exclude='./.git'" \
        "${root_dir}/scripts/materialize-platform-workspace.sh"
    grep -q 'build-with-wasm-rollup.patch' \
        "${root_dir}/scripts/prepare-platform.sh"
    grep -q '_ensure_rollup_optional_deps' \
        "${root_dir}/scripts/prepare-platform.sh"
    grep -q "registry=https://registry.npmjs.org" \
        "${root_dir}/scripts/prepare-platform.sh"
    grep -q 'HELIUM_WINDOWS_STAGED_OUT' \
        "${checkout}/build.py"
    grep -q 'BUILD_STATE_ROOT' \
        "${checkout}/.github/actions/stage/index.js"
    grep -q 'HELIUM_WINDOWS_ROOT' \
        "${checkout}/.github/actions/stage/index.js"
    grep -Fq "D:\\\\h" \
        "${checkout}/.github/actions/stage/index.js"
    grep -q 'listFilesRecursive' \
        "${checkout}/.github/actions/stage/index.js"
    ! grep -q 'glob.create(path.join(BUILD_STATE_ROOT' \
        "${checkout}/.github/actions/stage/index.js"
    ! grep -Fq 'helium-windows' \
        "${checkout}/.github/actions/stage/index.js"
    grep -q 'compressionLevel: 0' \
        "${checkout}/.github/actions/stage/index.js"
    ! grep -q 'artifacts.zip' \
        "${checkout}/.github/actions/stage/index.js"
fi

echo "target ready: ${platform} ${arch}"
