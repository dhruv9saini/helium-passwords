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
    if [ -f "${windows_stage_action}" ] && \
        ! grep -q 'HELIUM_WINDOWS_STAGED_OUT' "${windows_stage_action}"; then
        tmp_stage_action="$(mktemp)"
        awk '
            $0 == "async function run() {" {
                print ""
                print "const BUILD_STATE_ROOT = \047C:\\\\helium-windows\\\\build\\\\src\\\\out\\\\Default\047;"
                print "const STAGED_OUT_ENV = \047HELIUM_WINDOWS_STAGED_OUT\047;"
                print ""
                print "async function listBuildStateFiles() {"
                print "    if (!existsSync(BUILD_STATE_ROOT)) {"
                print "        throw new Error(`Missing Windows build state: ${BUILD_STATE_ROOT}`);"
                print "    }"
                print ""
                print "    const globber = await glob.create(path.join(BUILD_STATE_ROOT, \047**\047), {matchDirectories: false});"
                print "    const files = await globber.glob();"
                print "    if (files.length === 0) {"
                print "        throw new Error(`No Windows build state files found in ${BUILD_STATE_ROOT}`);"
                print "    }"
                print "    return files;"
                print "}"
                print ""
                print "async function downloadBuildState(artifact, artifactName) {"
                print "    const artifactInfo = await artifact.getArtifact(artifactName);"
                print "    const stagedOut = \047C:\\\\helium-windows\\\\build\\\\staged-out-Default\047;"
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
