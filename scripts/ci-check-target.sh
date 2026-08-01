#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/ci-check-target.sh <linux|macos|windows> <x86_64|arm64>

Prepare one platform checkout and verify that its locked core and toolchain are
compatible and that the password overlay is injected for the requested target.
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
temp_root=${TMPDIR:-/tmp}
checkout_root="$(mktemp -d "${temp_root}/helium-platform-check.XXXXXX")"
case "${checkout_root}" in
    "${temp_root}"/helium-platform-check.*) ;;
    *) echo "unexpected temporary checkout path: ${checkout_root}" >&2; exit 1 ;;
esac
cleanup() {
    find "${checkout_root}" -depth -delete
}
trap cleanup EXIT
checkout="$("${root_dir}/scripts/prepare-platform.sh" \
    "${platform}" "${checkout_root}/${platform}")"

depot_tools_commit=$(awk -F= \
    '$1 == "depot_tools_commit" { print substr($0, 20); exit }' \
    "${checkout}/.helium-platform-source.env")
[[ "${depot_tools_commit}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "prepared platform has no immutable depot_tools commit" >&2
    exit 1
}
depot_tools_checkout="${checkout_root}/depot_tools"
git init --quiet "${depot_tools_checkout}"
git -C "${depot_tools_checkout}" remote add origin \
    https://chromium.googlesource.com/chromium/tools/depot_tools
git -C "${depot_tools_checkout}" fetch --quiet --depth=1 origin \
    "${depot_tools_commit}"
git -C "${depot_tools_checkout}" checkout --quiet --detach FETCH_HEAD
git -C "${depot_tools_checkout}" apply --check --ignore-whitespace \
    "${checkout}/helium-chromium/utils/depot_tools.patch"

while IFS= read -r patch_path || [ -n "${patch_path}" ]; do
    patch_path="${patch_path%$'\r'}"
    case "${patch_path}" in
        ""|\#*) continue ;;
        helium-passwords/android-search-engine-api-compat.patch|\
        helium-passwords/disable-android-safe-browsing-bridges.patch)
            patch_name="$(basename "${patch_path}")"
            ! grep -qx "helium/passwords/${patch_name}" \
                "${checkout}/patches/series"
            [ ! -e "${checkout}/patches/helium/passwords/${patch_name}" ]
            continue
            ;;
    esac
    patch_name="$(basename "${patch_path}")"
    grep -qx "helium/passwords/${patch_name}" "${checkout}/patches/series"
    cmp -s "${root_dir}/patches/${patch_path}" \
        "${checkout}/patches/helium/passwords/${patch_name}"
done <"${root_dir}/patches/series"

grep -q 'r.PAYMENTS = r.AUTOFILL.createChild' \
    "${checkout}/patches/helium/passwords/restore-password-autofill.patch"
grep -q 'chrome::ShowPaymentMethods' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch"
[ "$(grep -c '\.SetEnabled(!is_guest_session)' \
    "${checkout}/patches/helium/passwords/restore-password-ui.patch")" -eq 3 ]
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
    grep -q 'HELIUM_BUILD_JOBS' "${checkout}/scripts/docker-build.sh"
    grep -Fq 'ninja -j "${HELIUM_BUILD_JOBS:-$(nproc)}"' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'local bootstrap_libcxx_ninja' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'libc = third_party/llvm-libc/src' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'shared/fp_bits.h' \
        "${checkout}/scripts/shared.sh"
    grep -Fq -- '-D_LIBCPP_CONSTINIT=constinit' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'local bootstrap_sysroot_arch' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'debian_bullseye_${bootstrap_sysroot_arch}-sysroot' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'CFLAGS="${CFLAGS:+${CFLAGS} }--sysroot=${bootstrap_sysroot}" \' \
        "${checkout}/scripts/shared.sh"
    ! grep -Fq 'LDFLAGS="${LDFLAGS:+${LDFLAGS} }--sysroot=${bootstrap_sysroot}" \' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'LDFLAGS="${LDFLAGS:+${LDFLAGS} }-fuse-ld=lld -rtlib=compiler-rt" \' \
        "${checkout}/scripts/shared.sh"
    grep -Fq '[ -x "$clang_bin/ld.lld" ]' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared' \
        "${checkout}/scripts/shared.sh"
    grep -Fq '[ -x "$clang_bin/llvm-ar" ]' \
        "${checkout}/scripts/shared.sh"
    grep -Fq 'AR="$clang_bin/llvm-ar" \' \
        "${checkout}/scripts/shared.sh"
    [ "$(grep -Fc '        --build-path out/Default \' \
        "${checkout}/scripts/shared.sh")" -eq 1 ]
    grep -Fq '        --use-custom-libcxx \' \
        "${checkout}/scripts/shared.sh"
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
