#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/prepare-platform.sh [--skip-submodules] <linux|macos|windows> [destination]

Clone the official Helium platform repo, remove the upstream password-disable
patch from helium-chromium, and append this repo's password overlay patches to
the platform patch series.
EOF
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../helium-passwords.conf
. "${root_dir}/helium-passwords.conf"

skip_submodules=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-submodules)
            skip_submodules=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

platform="${1:-}"
if [ -z "${platform}" ]; then
    usage
    exit 2
fi
shift || true

case "${platform}" in
    linux) repo_url="${HELIUM_LINUX_REPO}" ;;
    macos) repo_url="${HELIUM_MACOS_REPO}" ;;
    windows) repo_url="${HELIUM_WINDOWS_REPO}" ;;
    *)
        echo "unknown platform: ${platform}" >&2
        usage
        exit 2
        ;;
esac

destination="${1:-${root_dir}/${HELIUM_WORK_DIR}/${platform}}"
mkdir -p "$(dirname "${destination}")"

if [ ! -d "${destination}/.git" ]; then
    git clone --depth 1 --branch "${HELIUM_PLATFORM_REF}" "${repo_url}" "${destination}" >&2
else
    echo "using existing platform checkout: ${destination}" >&2
fi

if [ "${skip_submodules}" != true ]; then
    git -C "${destination}" submodule update --init --recursive helium-chromium >&2
fi

core_series="${destination}/helium-chromium/patches/series"
if [ -f "${core_series}" ]; then
    tmp_series="$(mktemp)"
    awk -v platform="${platform}" '
        $0 == "helium/hop/disable-password-manager.patch" { next }
        platform == "windows" && $0 == "ungoogled-chromium/build-with-wasm-rollup.patch" { next }
        { print }
    ' "${core_series}" > "${tmp_series}"
    mv "${tmp_series}" "${core_series}"
elif [ "${skip_submodules}" != true ]; then
    echo "missing core patch series: ${core_series}" >&2
    exit 1
fi

platform_series="${destination}/patches/series"
if [ ! -f "${platform_series}" ]; then
    echo "missing platform patch series: ${platform_series}" >&2
    exit 1
fi

if [ "${platform}" = "linux" ]; then
    rust_arm64_patch="${destination}/patches/ungoogled-chromium/portablelinux/fix-compiling-on-arm64.patch"
    if [ -f "${rust_arm64_patch}" ]; then
        sed -i \
            's/GetLibXml2Dirs, GetHostSysrootPlatform,/GetLibXml2Dirs, GitCherryPick, GetHostSysrootPlatform,/' \
            "${rust_arm64_patch}"
        if ! grep -q 'test_wrap_static_fns' "${rust_arm64_patch}"; then
            cat >> "${rust_arm64_patch}" <<'EOF'
--- a/tools/rust/build_bindgen.py
+++ b/tools/rust/build_bindgen.py
@@ -54,5 +54,6 @@ EXCLUDED_TESTS = [
     'header_constified_enum_module_overflow_hpp',
     'header_issue_544_stylo_creduce_2_hpp',
     'header_nsbasehashtable_hpp',
-    'header_typedef_pointer_overlap_h'
+    'header_typedef_pointer_overlap_h',
+    'test_wrap_static_fns'
 ]
EOF
        fi
    fi

    linux_docker_build="${destination}/scripts/docker-build.sh"
    if [ -f "${linux_docker_build}" ] && \
        ! grep -q 'GIT_COMMITTER_EMAIL' "${linux_docker_build}"; then
        tmp_docker_build="$(mktemp)"
        awk '
            { print }
            $0 ~ /_extra_env\+=\(-e ARCH\)/ {
                print "_extra_env+=(-e \"GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Helium Passwords Builder}\")"
                print "_extra_env+=(-e \"GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-builder@helium-passwords.invalid}\")"
                print "_extra_env+=(-e \"GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-Helium Passwords Builder}\")"
                print "_extra_env+=(-e \"GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-builder@helium-passwords.invalid}\")"
            }
        ' "${linux_docker_build}" > "${tmp_docker_build}"
        mv "${tmp_docker_build}" "${linux_docker_build}"
    fi
fi

if [ "${platform}" = "macos" ]; then
    macos_artifacts="${destination}/.github/scripts/github_prepare_artifacts.sh"
    if [ -f "${macos_artifacts}" ] && \
        ! grep -q 'MACOS_CERTIFICATE:-' "${macos_artifacts}"; then
        perl -0pi -e 's/(  # Prepar the certificate for app signing\n  echo \$MACOS_CERTIFICATE \| base64 --decode > "\$TMPDIR\/certificate\.p12"\n\n  security create-keychain -p "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n  security default-keychain -s build\.keychain\n  security unlock-keychain -p "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n  security import "\$TMPDIR\/certificate\.p12" -k build\.keychain -P "\$MACOS_CERTIFICATE_PWD" -T \/usr\/bin\/codesign\n  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n)/  if [[ -n "\${MACOS_CERTIFICATE:-}" ]]; then\n$1  fi\n/s' \
            "${macos_artifacts}"
    fi
fi

overlay_dir="${destination}/patches/helium/passwords"
rm -rf "${overlay_dir}"
mkdir -p "${overlay_dir}"

overlay_entries=()
while IFS= read -r patch_path; do
    patch_path="${patch_path%$'\r'}"
    case "${patch_path}" in
        ""|\#*) continue ;;
    esac

    source_patch="${root_dir}/patches/${patch_path}"
    if [ ! -f "${source_patch}" ]; then
        echo "missing overlay patch: ${source_patch}" >&2
        exit 1
    fi

    patch_name="$(basename "${patch_path}")"
    cp "${source_patch}" "${overlay_dir}/${patch_name}"
    overlay_entries+=("helium/passwords/${patch_name}")
done < "${root_dir}/patches/series"

tmp_series="$(mktemp)"
awk '$0 !~ /^helium\/passwords\//' "${platform_series}" > "${tmp_series}"
{
    cat "${tmp_series}"
    printf '\n'
    printf '%s\n' "${overlay_entries[@]}"
} > "${platform_series}"
rm -f "${tmp_series}"

echo "${destination}"
