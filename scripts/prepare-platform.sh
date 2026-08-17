#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/prepare-platform.sh [--skip-submodules] <linux|macos|windows> [destination]

Clone the official Helium platform repo, remove the upstream password-disable
patch from helium-chromium, and append this repo's password and sync overlay
patches to the platform patch series.
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
    linux)
        repo_url="${HELIUM_LINUX_REPO}"
        platform_ref="${HELIUM_PLATFORM_REF:-${HELIUM_LINUX_PLATFORM_REF}}"
        expected_platform_commit="${HELIUM_LINUX_PLATFORM_COMMIT}"
        expected_core_commit="${HELIUM_LINUX_CORE_COMMIT}"
        expected_depot_tools_commit="${HELIUM_LINUX_DEPOT_TOOLS_COMMIT}"
        ;;
    macos)
        repo_url="${HELIUM_MACOS_REPO}"
        platform_ref="${HELIUM_PLATFORM_REF:-${HELIUM_MACOS_PLATFORM_REF}}"
        expected_platform_commit="${HELIUM_MACOS_PLATFORM_COMMIT}"
        expected_core_commit="${HELIUM_MACOS_CORE_COMMIT}"
        expected_depot_tools_commit="${HELIUM_MACOS_DEPOT_TOOLS_COMMIT}"
        ;;
    windows)
        repo_url="${HELIUM_WINDOWS_REPO}"
        platform_ref="${HELIUM_PLATFORM_REF:-${HELIUM_WINDOWS_PLATFORM_REF}}"
        expected_platform_commit="${HELIUM_WINDOWS_PLATFORM_COMMIT}"
        expected_core_commit="${HELIUM_WINDOWS_CORE_COMMIT}"
        expected_depot_tools_commit="${HELIUM_WINDOWS_DEPOT_TOOLS_COMMIT}"
        ;;
    *)
        echo "unknown platform: ${platform}" >&2
        usage
        exit 2
        ;;
esac

for lock in "${expected_platform_commit}" "${expected_core_commit}" \
    "${expected_depot_tools_commit}"; do
    if ! [[ "${lock}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "platform, core, and depot_tools commits must be immutable SHA-1s" >&2
        exit 1
    fi
done

destination="${1:-${root_dir}/${HELIUM_WORK_DIR}/${platform}}"
mkdir -p "$(dirname "${destination}")"

if [ ! -d "${destination}/.git" ]; then
    if [[ "${platform_ref}" =~ ^[0-9a-f]{40}$ ]]; then
        git init --quiet "${destination}"
        git -C "${destination}" remote add origin "${repo_url}"
        git -C "${destination}" fetch --depth 1 origin "${platform_ref}" >&2
        git -C "${destination}" checkout --quiet --detach FETCH_HEAD
    else
        git clone --depth 1 --branch "${platform_ref}" "${repo_url}" "${destination}" >&2
    fi
else
    echo "using existing platform checkout: ${destination}" >&2
fi

actual_platform_commit=$(git -C "${destination}" rev-parse HEAD)
if [ "${actual_platform_commit}" != "${expected_platform_commit}" ]; then
    echo "${platform} platform checkout does not match its immutable commit lock" >&2
    exit 1
fi
actual_core_commit=$(git -C "${destination}" ls-tree HEAD helium-chromium | awk '{ print $3 }')
if [ "${actual_core_commit}" != "${expected_core_commit}" ]; then
    echo "${platform} platform checkout does not contain its locked Helium core" >&2
    exit 1
fi

cat >"${destination}/.helium-platform-source.env" <<EOF
platform_source_schema_version=2
platform_repository=${repo_url}
platform_requested_ref=${platform_ref}
platform_commit=${actual_platform_commit}
helium_core_commit=${actual_core_commit}
depot_tools_commit=${expected_depot_tools_commit}
EOF

if [ "${skip_submodules}" != true ]; then
    git -C "${destination}" submodule update --init --recursive helium-chromium >&2

    if [ "${platform}" = linux ]; then
        linux_direct_source_patch="${root_dir}/chromium/tooling/linux-direct-source.patch"
        [ -f "${linux_direct_source_patch}" ] || {
            echo "missing Linux direct-source patch" >&2
            exit 1
        }
        git -C "${destination}/helium-chromium" apply --check --ignore-whitespace \
            "${linux_direct_source_patch}"
        git -C "${destination}/helium-chromium" apply --ignore-whitespace \
            "${linux_direct_source_patch}"
    fi

    clone_helper="${destination}/helium-chromium/utils/clone.py"
    grep -Fq "get_logger().info('Cloning latest depot_tools')" "${clone_helper}" || {
        echo "${platform} Helium core no longer has the expected depot_tools clone path" >&2
        exit 1
    }
    grep -Fq "'git', 'fetch', '--depth=1', 'origin', 'HEAD'" "${clone_helper}" || {
        echo "${platform} Helium core no longer fetches depot_tools through the expected command" >&2
        exit 1
    }
    sed -i.bak \
        -e "s/get_logger().info('Cloning latest depot_tools')/get_logger().info('Cloning pinned depot_tools: ${expected_depot_tools_commit}')/" \
        -e "s/'git', 'fetch', '--depth=1', 'origin', 'HEAD'/'git', 'fetch', '--depth=1', 'origin', '${expected_depot_tools_commit}'/" \
        "${clone_helper}"
    rm -f -- "${clone_helper}.bak"
    grep -Fq "Cloning pinned depot_tools: ${expected_depot_tools_commit}" \
        "${clone_helper}"
    grep -Fq "'git', 'fetch', '--depth=1', 'origin', '${expected_depot_tools_commit}'" \
        "${clone_helper}"

    if [ "${platform}" = linux ]; then
        grep -Fq "str(gcpath), 'sync', '--jobs=1', '-f', '-D', '-R', '--no-history', '--nohooks'," \
            "${clone_helper}"
        grep -Fqx 'cache_dir = None;' "${clone_helper}"
        grep -Fq "environ.pop('GIT_CACHE_PATH', None)" "${clone_helper}"
    fi
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
    linux_flags="${destination}/flags.linux.gn"
    [ -f "${linux_flags}" ] || {
        echo "missing Linux GN flags: ${linux_flags}" >&2
        exit 1
    }
    if ! grep -Fqx '# HELIUM_CHROMIUMER_LOW_MEMORY_LINK_V1' \
        "${linux_flags}"; then
        [ "$(grep -Fxc 'symbol_level=1' "${linux_flags}")" -eq 1 ] || {
            echo "unexpected Linux symbol level before low-memory setup" >&2
            exit 1
        }
        sed -i 's/^symbol_level=1$/symbol_level=0/' "${linux_flags}"
        cat >>"${linux_flags}" <<'EOF'
# HELIUM_CHROMIUMER_LOW_MEMORY_LINK_V1
v8_symbol_level=0
use_thin_lto=false
is_cfi=false
EOF
    fi
    for low_memory_arg in \
        'symbol_level=0' \
        'blink_symbol_level=0' \
        'v8_symbol_level=0' \
        'use_thin_lto=false' \
        'is_cfi=false'; do
        [ "$(grep -Fxc "${low_memory_arg}" "${linux_flags}")" -eq 1 ] || {
            echo "invalid low-memory Linux GN argument: ${low_memory_arg}" >&2
            exit 1
        }
    done

    linux_build_script="${destination}/scripts/build.sh"
    if ! grep -Fq 'HELIUM_LINUX_PREFLIGHT_HOOK_V1' \
        "${linux_build_script}"; then
        tmp_linux_build="$(mktemp)"
        awk '
            $0 == "build" {
                print "# HELIUM_LINUX_PREFLIGHT_HOOK_V1"
                print "if [ -n \"${HELIUM_LINUX_PREFLIGHT_HOOK:-}\" ]; then"
                print "    \"${HELIUM_LINUX_PREFLIGHT_HOOK}\" \"${_root_dir}\" \"${_src_dir}\" \"${_out_dir}\""
                print "fi"
            }
            { print }
        ' "${linux_build_script}" >"${tmp_linux_build}"
        mv "${tmp_linux_build}" "${linux_build_script}"
    fi
    [ "$(grep -Fc 'HELIUM_LINUX_PREFLIGHT_HOOK_V1' \
        "${linux_build_script}")" -eq 1 ] || {
        echo "invalid Linux preflight hook boundary" >&2
        exit 1
    }

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
                print "_extra_env+=(-e \"GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-Helium Sync Builder}\")"
                print "_extra_env+=(-e \"GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-builder@helium-sync.invalid}\")"
                print "_extra_env+=(-e \"GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-Helium Sync Builder}\")"
                print "_extra_env+=(-e \"GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-builder@helium-sync.invalid}\")"
            }
        ' "${linux_docker_build}" > "${tmp_docker_build}"
        mv "${tmp_docker_build}" "${linux_docker_build}"
    fi
    if [ -f "${linux_docker_build}" ] && \
        ! grep -q 'HELIUM_BUILD_JOBS' "${linux_docker_build}"; then
        tmp_docker_build="$(mktemp)"
        awk '
            { print }
            $0 == "[ -n \"${ARCH:-}\" ] && _extra_env+=(-e ARCH)" {
                print "[ -n \"${HELIUM_BUILD_JOBS:-}\" ] && _extra_env+=(-e HELIUM_BUILD_JOBS)"
            }
        ' "${linux_docker_build}" > "${tmp_docker_build}"
        mv "${tmp_docker_build}" "${linux_docker_build}"
    fi

    linux_shared_build="${destination}/scripts/shared.sh"
    if [ -f "${linux_shared_build}" ] && \
        ! grep -q 'HELIUM_BUILD_JOBS' "${linux_shared_build}"; then
        sed -i 's/ninja -C out\/Default chrome chromedriver/ninja -j "${HELIUM_BUILD_JOBS:-$(nproc)}" -C out\/Default chrome chromedriver/' \
            "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq 'local bootstrap_libcxx_ninja' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    local clang_bin=\"${_src_dir}/third_party/llvm-build/Release+Asserts/bin\"" {
                print
                print "    local bootstrap_libcxx_ninja=\"${_src_dir}/tools/gn/bootstrap/libc++.ninja\""
                print "    local bootstrap_llvm_libc=\"${_src_dir}/third_party/llvm-libc/src\""
                print "    [ -f \"$bootstrap_libcxx_ninja\" ] || {"
                print "        echo \"missing GN bootstrap libc++ template: $bootstrap_libcxx_ninja\" >&2"
                print "        return 1"
                print "    }"
                print "    [ -f \"$bootstrap_llvm_libc/shared/fp_bits.h\" ] || {"
                print "        echo \"missing GN bootstrap LLVM libc headers: $bootstrap_llvm_libc\" >&2"
                print "        return 1"
                print "    }"
                print "    if grep -Fqx \047libc = third_party/llvm/libc\047 \"$bootstrap_libcxx_ninja\"; then"
                print "        sed -i \047s|^libc = third_party/llvm/libc$|libc = third_party/llvm-libc/src|\047 \"$bootstrap_libcxx_ninja\""
                print "    fi"
                print "    grep -Fqx \047libc = third_party/llvm-libc/src\047 \"$bootstrap_libcxx_ninja\" || {"
                print "        echo \"unexpected GN bootstrap LLVM libc include root\" >&2"
                print "        return 1"
                print "    }"
                print "    if ! grep -Fq -- \047-D_LIBCPP_CONSTINIT=constinit\047 \"$bootstrap_libcxx_ninja\"; then"
                print "        sed -i \047/^rule cxx_libcxxabi$/{n;s/ -DLIBCXXABI_SILENT_TERMINATE / -D_LIBCPP_CONSTINIT=constinit -DLIBCXXABI_SILENT_TERMINATE /;}\047 \"$bootstrap_libcxx_ninja\""
                print "    fi"
                print "    grep -Fqx \047  command = $cxx $cflags -D_LIBCXXABI_NO_EXCEPTIONS -D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_CONSTINIT=constinit -DLIBCXXABI_SILENT_TERMINATE -c $in -o $out\047 \"$bootstrap_libcxx_ninja\" || {"
                print "        echo \"unexpected GN bootstrap libc++abi compatibility defines\" >&2"
                print "        return 1"
                print "    }"
                next
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
        grep -Fq 'local bootstrap_libcxx_ninja' "${linux_shared_build}"
        grep -Fq 'libc = third_party/llvm-libc/src' "${linux_shared_build}"
        grep -Fq 'shared/fp_bits.h' "${linux_shared_build}"
        grep -Fq -- '-D_LIBCPP_CONSTINIT=constinit' "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq -- '-D_LIBCPP_CONSTINIT=constinit' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    local bootstrap_sysroot_arch" {
                print "    if ! grep -Fq -- \047-D_LIBCPP_CONSTINIT=constinit\047 \"$bootstrap_libcxx_ninja\"; then"
                print "        sed -i \047/^rule cxx_libcxxabi$/{n;s/ -DLIBCXXABI_SILENT_TERMINATE / -D_LIBCPP_CONSTINIT=constinit -DLIBCXXABI_SILENT_TERMINATE /;}\047 \"$bootstrap_libcxx_ninja\""
                print "    fi"
                print "    grep -Fqx \047  command = $cxx $cflags -D_LIBCXXABI_NO_EXCEPTIONS -D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_CONSTINIT=constinit -DLIBCXXABI_SILENT_TERMINATE -c $in -o $out\047 \"$bootstrap_libcxx_ninja\" || {"
                print "        echo \"unexpected GN bootstrap libc++abi compatibility defines\" >&2"
                print "        return 1"
                print "    }"
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
        grep -Fq -- '-D_LIBCPP_CONSTINIT=constinit' "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq 'local bootstrap_sysroot_arch' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    CXX=\"$clang_bin/clang++\" ./tools/gn/bootstrap/bootstrap.py \\" {
                print "    local bootstrap_sysroot_arch"
                print "    case \"$_host_arch\" in"
                print "        x64) bootstrap_sysroot_arch=amd64 ;;"
                print "        arm64) bootstrap_sysroot_arch=arm64 ;;"
                print "        *)"
                print "            echo \"unsupported GN bootstrap host architecture: $_host_arch\" >&2"
                print "            return 1"
                print "            ;;"
                print "    esac"
                print "    local bootstrap_sysroot=\"${_src_dir}/build/linux/debian_bullseye_${bootstrap_sysroot_arch}-sysroot\""
                print "    [ -d \"$bootstrap_sysroot\" ] || {"
                print "        echo \"missing GN bootstrap host sysroot: $bootstrap_sysroot\" >&2"
                print "        return 1"
                print "    }"
                print "    LDFLAGS=\"${LDFLAGS:+${LDFLAGS} }-fuse-ld=lld -rtlib=compiler-rt\" \\"
                print "    CFLAGS=\"${CFLAGS:+${CFLAGS} }--sysroot=${bootstrap_sysroot}\" \\"
                print "    AR=\"$clang_bin/llvm-ar\" \\"
                print
                print "        --use-custom-libcxx \\"
                next
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
        grep -Fq 'local bootstrap_sysroot_arch' "${linux_shared_build}"
        grep -Fq 'CFLAGS="${CFLAGS:+${CFLAGS} }--sysroot=${bootstrap_sysroot}" \' \
            "${linux_shared_build}"
        grep -Fq '        --use-custom-libcxx \' "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        grep -Fqx '    LDFLAGS="${LDFLAGS:+${LDFLAGS} }--sysroot=${bootstrap_sysroot}" \' \
            "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    LDFLAGS=\"${LDFLAGS:+${LDFLAGS} }--sysroot=${bootstrap_sysroot}\" \\" { next }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ]; then
        ! grep -Fq 'LDFLAGS="${LDFLAGS:+${LDFLAGS} }--sysroot=${bootstrap_sysroot}" \' \
            "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq 'LDFLAGS="${LDFLAGS:+${LDFLAGS} }-fuse-ld=lld -rtlib=compiler-rt" \' \
            "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    CFLAGS=\"${CFLAGS:+${CFLAGS} }--sysroot=${bootstrap_sysroot}\" \\" {
                print "    LDFLAGS=\"${LDFLAGS:+${LDFLAGS} }-fuse-ld=lld -rtlib=compiler-rt\" \\"
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq 'command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared' \
            "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    local bootstrap_sysroot_arch" {
                print "    [ -x \"$clang_bin/ld.lld\" ] || {"
                print "        echo \"missing downloaded GN bootstrap linker: $clang_bin/ld.lld\" >&2"
                print "        return 1"
                print "    }"
                print "    if grep -Fqx \047  command = $cxx -shared -fPIC -o $out -Wl,--start-group $in -Wl,--end-group\047 \"$bootstrap_libcxx_ninja\"; then"
                print "        sed -i \047s|^  command = \\$cxx -shared -fPIC -o \\$out -Wl,--start-group \\$in -Wl,--end-group$|  command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared -fPIC -o $out -Wl,--start-group $in -Wl,--end-group|\047 \"$bootstrap_libcxx_ninja\""
                print "    fi"
                print "    if grep -Fqx \047  command = $cxx -fuse-ld=lld -shared -fPIC -o $out -Wl,--start-group $in -Wl,--end-group\047 \"$bootstrap_libcxx_ninja\"; then"
                print "        sed -i \047s|^  command = \\$cxx -fuse-ld=lld -shared -fPIC -o \\$out -Wl,--start-group \\$in -Wl,--end-group$|  command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared -fPIC -o $out -Wl,--start-group $in -Wl,--end-group|\047 \"$bootstrap_libcxx_ninja\""
                print "    fi"
                print "    grep -Fqx \047  command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared -fPIC -o $out -Wl,--start-group $in -Wl,--end-group\047 \"$bootstrap_libcxx_ninja\" || {"
                print "        echo \"unexpected GN bootstrap libc++ linker command\" >&2"
                print "        return 1"
                print "    }"
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ]; then
        grep -Fq '[ -x "$clang_bin/ld.lld" ]' "${linux_shared_build}"
        grep -Fq 'LDFLAGS="${LDFLAGS:+${LDFLAGS} }-fuse-ld=lld -rtlib=compiler-rt" \' \
            "${linux_shared_build}"
        grep -Fq 'command = $cxx -fuse-ld=lld -rtlib=compiler-rt -shared' \
            "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq '[ -x "$clang_bin/llvm-ar" ]' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    local bootstrap_sysroot_arch" {
                print "    [ -x \"$clang_bin/llvm-ar\" ] || {"
                print "        echo \"missing downloaded GN bootstrap archiver: $clang_bin/llvm-ar\" >&2"
                print "        return 1"
                print "    }"
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq 'AR="$clang_bin/llvm-ar" \' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "    CFLAGS=\"${CFLAGS:+${CFLAGS} }--sysroot=${bootstrap_sysroot}\" \\" {
                print
                print "    AR=\"$clang_bin/llvm-ar\" \\"
                next
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ]; then
        grep -Fq '[ -x "$clang_bin/llvm-ar" ]' "${linux_shared_build}"
        grep -Fq 'AR="$clang_bin/llvm-ar" \' "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ] && \
        ! grep -Fq '        --build-path out/Default \' "${linux_shared_build}"; then
        tmp_linux_shared="$(mktemp)"
        awk '
            $0 == "        --use-custom-libcxx \\" {
                print "        --build-path out/Default \\"
            }
            { print }
        ' "${linux_shared_build}" > "${tmp_linux_shared}"
        mv "${tmp_linux_shared}" "${linux_shared_build}"
    fi
    if [ -f "${linux_shared_build}" ]; then
        [ "$(grep -Fc '        --build-path out/Default \' \
            "${linux_shared_build}")" -eq 1 ]
    fi

    linux_package_sh="${destination}/scripts/package.sh"
    if [ -f "${linux_package_sh}" ] && \
        ! grep -q 'HELIUM_SYNC_OPTIONAL_RELEASE_FILES' "${linux_package_sh}"; then
        perl -0pi -e 's/vk_swiftshader_icd\.json\nxdg-mime\nxdg-settings"/vk_swiftshader_icd.json"\n\n# HELIUM_SYNC_OPTIONAL_RELEASE_FILES\n_optional_files="xdg-mime\nxdg-settings"/' \
            "${linux_package_sh}"
        perl -0pi -e 's/(for file in \$_files; do\n    cp -r "\$_build_dir\/src\/out\/Default\/\$file" "\$_tarball_dir" &\ndone\n)/$1\nfor file in \$_optional_files; do\n    if [ -e "\$_build_dir\/src\/out\/Default\/\$file" ]; then\n        cp -r "\$_build_dir\/src\/out\/Default\/\$file" "\$_tarball_dir" &\n    fi\ndone\n/s' \
            "${linux_package_sh}"
        perl -0pi -e 's/if command -v eu-strip >\/dev\/null 2>&1; then\n    _strip_cmd=eu-strip\nelse\n    _strip_cmd="strip --strip-unneeded"\nfi/if command -v eu-strip >\/dev\/null 2>\&1; then\n    _strip_cmd=eu-strip\nelif command -v llvm-strip >\/dev\/null 2>\&1; then\n    _strip_cmd=llvm-strip\nelse\n    _strip_cmd="strip --strip-unneeded"\nfi/s' \
            "${linux_package_sh}"
        perl -0pi -e 's/(find "\$_tarball_dir" -type f -exec file \{\} \+ \\\n    \| awk -F: '\''\/ELF\/ \{print \$1\}'\'' \\\n    \| xargs \$_strip_cmd)/$1 || echo "warning: could not strip release binaries; continuing" >\&2/' \
            "${linux_package_sh}"
        perl -0pi -e 's/(appimagetool \\\n    -u "\$_update_info" \\\n    "\$_app_dir" \\\n    "\$_release_name\.AppImage" "\$@" &)/if command -v appimagetool >\/dev\/null 2>\&1; then\n    $1\nelse\n    echo "warning: appimagetool not found; skipping AppImage" >\&2\nfi/s' \
            "${linux_package_sh}"
    fi
    if [ -f "${linux_package_sh}" ] && \
        ! grep -q 'HELIUM_SYNC_PACKAGE_PV_FALLBACK' "${linux_package_sh}"; then
        perl -0pi -e 's/tar vcf - "\$_tarball_name" \\\n    \| pv -s"\$\{_size\}k" \\\n    \| xz -e9 > "\$TAR_PATH" &/# HELIUM_SYNC_PACKAGE_PV_FALLBACK\nif command -v pv >\/dev\/null 2>\&1; then\n    tar vcf - "\$_tarball_name" \\\n        | pv -s"\${_size}k" \\\n        | xz -e9 > "\$TAR_PATH" &\nelse\n    tar cf - "\$_tarball_name" \\\n        | xz -e9 > "\$TAR_PATH" &\nfi/s' \
            "${linux_package_sh}"
    fi
fi

if [ "${platform}" = "windows" ]; then
    windows_build_py="${destination}/build.py"
    if [ -f "${windows_build_py}" ] && \
        ! grep -q '_ensure_rollup_optional_deps' "${windows_build_py}"; then
        tmp_build_py="$(mktemp)"
        awk '
            $0 == "    if not args.ci or not (source_tree / \047out/Default\047).exists():" {
                print "    _restore_staged_out(source_tree)"
                print ""
                print
                next
            }
            { print }
            $0 == "import argparse" {
                print "import json"
                print "import tarfile"
                print "import tempfile"
            }
            $0 == "_PATCH_BIN_RELPATH = Path(\047third_party/git/usr/bin/patch.exe\047)" {
                print ""
                print "def _touch_tree(root):"
                print "    now = time.time()"
                print "    for current_root, _, files in os.walk(root):"
                print "        try:"
                print "            os.utime(current_root, (now, now))"
                print "        except FileNotFoundError:"
                print "            continue"
                print "        for file_name in files:"
                print "            file_path = Path(current_root) / file_name"
                print "            try:"
                print "                os.utime(file_path, (now, now))"
                print "            except FileNotFoundError:"
                print "                pass"
                print ""
                print "def _restore_staged_out(source_tree):"
                print "    staged_out = os.environ.get(\047HELIUM_WINDOWS_STAGED_OUT\047)"
                print "    if not staged_out:"
                print "        return"
                print ""
                print "    staged_out_path = Path(staged_out)"
                print "    if not staged_out_path.exists():"
                print "        raise RuntimeError(f\047Staged Windows build output is missing: {staged_out_path}\047)"
                print ""
                print "    out_dir = source_tree / \047out\047 / \047Default\047"
                print "    if out_dir.exists():"
                print "        shutil.rmtree(out_dir)"
                print "    out_dir.parent.mkdir(parents=True, exist_ok=True)"
                print "    shutil.move(str(staged_out_path), str(out_dir))"
                print "    _touch_tree(out_dir)"
                print ""
                print "def _ensure_rollup_optional_deps(source_tree):"
                print "    devtools_root = source_tree / \047third_party\047 / \047devtools-frontend\047 / \047src\047"
                print "    rollup_package = devtools_root / \047node_modules\047 / \047rollup\047 / \047package.json\047"
                print "    if not rollup_package.exists():"
                print "        return"
                print ""
                print "    with rollup_package.open(encoding=ENCODING) as file:"
                print "        rollup_version = json.load(file).get(\047version\047)"
                print "    if not rollup_version:"
                print "        return"
                print ""
                print "    package_name = \047@rollup/rollup-win32-x64-msvc\047"
                print "    package_path = devtools_root / \047node_modules\047 / \047@rollup\047 / \047rollup-win32-x64-msvc\047"
                print "    if package_path.exists():"
                print "        return"
                print ""
                print "    npm = shutil.which(\047npm.cmd\047) or shutil.which(\047npm\047)"
                print "    if npm is None:"
                print "        raise RuntimeError(\047npm is required to restore Rollup Windows optional dependencies\047)"
                print ""
                print "    package_path.parent.mkdir(parents=True, exist_ok=True)"
                print "    with tempfile.TemporaryDirectory() as temp_dir:"
                print "        result = subprocess.run("
                print "            ["
                print "                npm,"
                print "                \047pack\047,"
                print "                \047--ignore-scripts\047,"
                print "                \047--json\047,"
                print "                \047--pack-destination\047,"
                print "                temp_dir,"
                print "                \047--registry=https://registry.npmjs.org/\047,"
                print "                f\047{package_name}@{rollup_version}\047,"
                print "            ],"
                print "            cwd=temp_dir,"
                print "            check=True,"
                print "            stdout=subprocess.PIPE,"
                print "            encoding=ENCODING)"
                print "        pack_info = json.loads(result.stdout)"
                print "        tarball = Path(temp_dir) / pack_info[0][\047filename\047]"
                print "        extract_root = Path(temp_dir) / \047extract\047"
                print "        with tarfile.open(tarball, \047r:gz\047) as archive:"
                print "            archive.extractall(extract_root)"
                print "        shutil.move(str(extract_root / \047package\047), str(package_path))"
            }
            $0 == "        downloads.unpack_downloads(download_info_win, downloads_cache, None, source_tree, extractors)" {
                print ""
                print "        _ensure_rollup_optional_deps(source_tree)"
            }
        ' "${windows_build_py}" > "${tmp_build_py}"
        mv "${tmp_build_py}" "${windows_build_py}"
    fi

    windows_stage_action="${destination}/.github/actions/stage/index.js"
    if [ -f "${windows_stage_action}" ]; then
        if ! grep -q 'HELIUM_WINDOWS_STAGED_OUT' "${windows_stage_action}"; then
            tmp_stage_action="$(mktemp)"
            awk '
            $0 == "async function run() {" {
                print ""
                print "const BUILD_ROOT = process.env.HELIUM_WINDOWS_ROOT || \047D:\\\\h\047;"
                print "const BUILD_SRC_ROOT = path.join(BUILD_ROOT, \047build\\\\src\047);"
                print "const BUILD_STATE_ROOT = path.join(BUILD_SRC_ROOT, \047out\\\\Default\047);"
                print "const STAGED_OUT_ENV = \047HELIUM_WINDOWS_STAGED_OUT\047;"
                print ""
                print "async function listBuildStateFiles() {"
                print "    if (!existsSync(BUILD_STATE_ROOT)) {"
                print "        throw new Error(`Missing Windows build state: ${BUILD_STATE_ROOT}`);"
                print "    }"
                print ""
                print "    const files = await listFilesRecursive(BUILD_STATE_ROOT);"
                print "    if (files.length === 0) {"
                print "        throw new Error(`No Windows build state files found in ${BUILD_STATE_ROOT}`);"
                print "    }"
                print "    return files;"
                print "}"
                print ""
                print "async function listFilesRecursive(root) {"
                print "    const entries = await fs.readdir(root, {withFileTypes: true});"
                print "    const files = [];"
                print "    for (const entry of entries) {"
                print "        const filePath = path.join(root, entry.name);"
                print "        if (entry.isDirectory()) {"
                print "            files.push(...await listFilesRecursive(filePath));"
                print "        } else if (entry.isFile()) {"
                print "            files.push(filePath);"
                print "        }"
                print "    }"
                print "    return files;"
                print "}"
            print ""
            print "async function downloadBuildState(artifact, artifactName) {"
            print "    const artifactInfo = await artifact.getArtifact(artifactName);"
                print "    const stagedOut = path.join(BUILD_ROOT, \047build\\\\staged-out-Default\047);"
            print "    await io.rmRF(stagedOut);"
            print "    await artifact.downloadArtifact(artifactInfo.artifact.id, {path: stagedOut});"
            print "    process.env[STAGED_OUT_ENV] = stagedOut;"
                print "}"
                print ""
                print "async function uploadBuildState(artifact, artifactName) {"
                print "    const files = await listBuildStateFiles();"
                print "    let lastError = null;"
                print "    for (let i = 0; i < 5; ++i) {"
                print "        try {"
                print "            await artifact.deleteArtifact(artifactName);"
                print "        } catch (e) {"
                print "            // ignored"
                print "        }"
                print "        try {"
                print "            await artifact.uploadArtifact(artifactName, files, BUILD_STATE_ROOT,"
                print "                { retentionDays: 4, compressionLevel: 0 });"
                print "            return;"
                print "        } catch (e) {"
                print "            lastError = e;"
                print "            console.error(`Upload artifact failed: ${e}`);"
                print "            await new Promise(r => setTimeout(r, 10000));"
                print "        }"
                print "    }"
                print "    throw lastError || new Error(`Failed to upload ${artifactName}`);"
                print "}"
                print ""
                print "async function run() {"
                next
            }
            $0 == "    if (from_artifact && !same_runner) {" {
                print "    if (from_artifact && !same_runner) {"
                print "        await downloadBuildState(artifact, artifactName);"
                print "    }"
                skip_download = 1
                next
            }
            skip_download {
                if ($0 == "    }") {
                    skip_download = 0
                }
                next
            }
            $0 == "    if (!gen_installer) {" {
                print "    if (!gen_installer) {"
                print "        await uploadBuildState(artifact, artifactName);"
                print "    }"
                skip_upload = 1
                next
            }
            skip_upload {
                if ($0 == "}") {
                    skip_upload = 0
                    print
                }
                next
            }
            { print }
            ' "${windows_stage_action}" > "${tmp_stage_action}"
            mv "${tmp_stage_action}" "${windows_stage_action}"
        fi

        if grep -q 'glob.create(path.join(BUILD_STATE_ROOT' "${windows_stage_action}"; then
            perl -0pi -e 's/    const globber = await glob\.create\(path\.join\(BUILD_STATE_ROOT, '\''\*\*'\''\), \{matchDirectories: false\}\);\n    const files = await globber\.glob\(\);\n/    const files = await listFilesRecursive\(BUILD_STATE_ROOT\);\n/s' \
                "${windows_stage_action}"
            perl -0pi -e 's/(async function downloadBuildState\(artifact, artifactName\) \{)/async function listFilesRecursive\(root\) {\n    const entries = await fs.readdir\(root, {withFileTypes: true}\);\n    const files = \[];\n    for \(const entry of entries\) {\n        const filePath = path.join\(root, entry.name\);\n        if \(entry.isDirectory\(\)\) {\n            files.push\(...await listFilesRecursive\(filePath\)\);\n        } else if \(entry.isFile\(\)\) {\n            files.push\(filePath\);\n        }\n    }\n    return files;\n}\n\n$1/s' \
                "${windows_stage_action}"
        fi

        if grep -q 'helium-windows' "${windows_stage_action}"; then
            tmp_stage_action="$(mktemp)"
            awk '
                $0 == "    const ROOT = \047C:\\\\helium-windows\\\\build\\\\src\047;" {
                    print "    const ROOT = BUILD_SRC_ROOT;"
                    next
                }
                $0 == "const BUILD_STATE_ROOT = \047C:\\\\helium-windows\\\\build\\\\src\\\\out\\\\Default\047;" {
                    print "const BUILD_ROOT = process.env.HELIUM_WINDOWS_ROOT || \047D:\\\\h\047;"
                    print "const BUILD_SRC_ROOT = path.join(BUILD_ROOT, \047build\\\\src\047);"
                    print "const BUILD_STATE_ROOT = path.join(BUILD_SRC_ROOT, \047out\\\\Default\047);"
                    next
                }
                $0 == "    const stagedOut = \047C:\\\\helium-windows\\\\build\\\\staged-out-Default\047;" {
                    print "    const stagedOut = path.join(BUILD_ROOT, \047build\\\\staged-out-Default\047);"
                    next
                }
                $0 == "        core.addPath(\047C:\\\\helium-windows\\\\build\\\\src\\\\third_party\\\\nsis\047);" {
                    print "        core.addPath(path.join(BUILD_SRC_ROOT, \047third_party\\\\nsis\047));"
                    next
                }
                $0 == "        const globber = await glob.create(\047C:\\\\helium-windows\\\\build\\\\helium*\047," {
                    print "        const globber = await glob.create(path.join(BUILD_ROOT, \047build\\\\helium*\047),"
                    next
                }
                $0 == "                    \047C:\\\\helium-windows\\\\build\047, { retentionDays: 4, compressionLevel: 0 });" {
                    print "                    path.join(BUILD_ROOT, \047build\047), { retentionDays: 4, compressionLevel: 0 });"
                    next
                }
                $0 == "        cwd: \047C:\\\\helium-windows\047," {
                    print "        cwd: BUILD_ROOT,"
                    next
                }
                { print }
            ' "${windows_stage_action}" > "${tmp_stage_action}"
            mv "${tmp_stage_action}" "${windows_stage_action}"
        fi
    fi
fi

if [ "${platform}" = "macos" ]; then
    macos_artifacts="${destination}/.github/scripts/github_prepare_artifacts.sh"
    if [ -f "${macos_artifacts}" ] && \
        ! grep -q 'MACOS_CERTIFICATE:-' "${macos_artifacts}"; then
        perl -0pi -e 's/(  # Prepar the certificate for app signing\n  echo \$MACOS_CERTIFICATE \| base64 --decode > "\$TMPDIR\/certificate\.p12"\n\n  security create-keychain -p "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n  security default-keychain -s build\.keychain\n  security unlock-keychain -p "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n  security import "\$TMPDIR\/certificate\.p12" -k build\.keychain -P "\$MACOS_CERTIFICATE_PWD" -T \/usr\/bin\/codesign\n  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "\$MACOS_CI_KEYCHAIN_PWD" build\.keychain\n)/  if [[ -n "\${MACOS_CERTIFICATE:-}" ]]; then\n$1  fi\n/s' \
            "${macos_artifacts}"
    fi

    sparkle_deltas="${destination}/devutils/generate_sparkle_deltas.py"
    if [ -f "${sparkle_deltas}" ] && \
        ! grep -q 'missing macOS dmg asset' "${sparkle_deltas}"; then
        perl -0pi -e 's/  assert\(False\)\n/  print(f"missing macOS dmg asset for {arch}; skipping release")\n  return None\n/s' \
            "${sparkle_deltas}"
        perl -0pi -e 's/    x86_url = get_asset_url\(release, '\''x86_64'\''\)\n    arm_url = get_asset_url\(release, '\''arm64'\''\)\n    urls\[version\] = \(arm_url, x86_url\)\n/    x86_url = get_asset_url(release, '\''x86_64'\'')\n    arm_url = get_asset_url(release, '\''arm64'\'')\n    if x86_url is None or arm_url is None:\n      continue\n    urls[version] = (arm_url, x86_url)\n/s' \
            "${sparkle_deltas}"
    fi
fi

password_overlay_dir="${destination}/patches/helium/passwords"
rm -rf "${password_overlay_dir}"
mkdir -p "${password_overlay_dir}"

password_overlay_entries=()
while IFS= read -r patch_path; do
    patch_path="${patch_path%$'\r'}"
    case "${patch_path}" in
        ""|\#*) continue ;;
        helium-passwords/android-search-engine-api-compat.patch|\
        helium-passwords/disable-android-safe-browsing-bridges.patch)
            continue
            ;;
    esac

    source_patch="${root_dir}/patches/${patch_path}"
    if [ ! -f "${source_patch}" ]; then
        echo "missing overlay patch: ${source_patch}" >&2
        exit 1
    fi

    patch_name="$(basename "${patch_path}")"
    cp "${source_patch}" "${password_overlay_dir}/${patch_name}"
    password_overlay_entries+=("helium/passwords/${patch_name}")
done < "${root_dir}/patches/series"

sync_overlay_dir="${destination}/patches/helium/sync"
rm -rf "${sync_overlay_dir}"
mkdir -p "${sync_overlay_dir}"

sync_overlay_entries=()
for source_patch in "${root_dir}"/chromium/patches/*.patch; do
    [ -e "${source_patch}" ] || continue
    patch_name="$(basename "${source_patch}")"
    case "${patch_name}" in
        0003-helium-sync-android-profile-startup.patch|\
        0004-helium-sync-android-oscrypt-provider.patch|\
        0005-helium-sync-android-branding.patch|\
        0006-helium-sync-android-ai-overview-blocker.patch)
            continue
            ;;
    esac
    if [ "${patch_name}" = "0001-helium-sync-overlay-files.patch" ]; then
        "${root_dir}/scripts/chromium/filter-overlay-patch.sh" \
            "${source_patch}" > "${sync_overlay_dir}/${patch_name}"
    else
        cp "${source_patch}" "${sync_overlay_dir}/${patch_name}"
    fi
    sync_overlay_entries+=("helium/sync/${patch_name}")
done

tmp_series="$(mktemp)"
awk '$0 !~ /^helium\/(passwords|sync)\//' "${platform_series}" > "${tmp_series}"
{
    cat "${tmp_series}"
    printf '\n'
    printf '%s\n' "${password_overlay_entries[@]}"
    printf '%s\n' "${sync_overlay_entries[@]}"
} > "${platform_series}"
rm -f "${tmp_series}"

echo "${destination}"
