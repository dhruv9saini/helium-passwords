#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
# shellcheck source=../../chromium/android-runtime-kit.lock
. "$repo_root/chromium/android-runtime-kit.lock"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-media-config.XXXXXX")
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/src/out/Test" "$test_root/bin" "$test_root/provenance"
cat "$repo_root/helium-chromium/flags.gn" > "$test_root/src/out/Test/args.gn"
printf 'target_os = "android"\n' >> "$test_root/src/out/Test/args.gn"
git -C "$test_root/src" init -q
git -C "$test_root/src" config user.email test@helium.invalid
git -C "$test_root/src" config user.name 'Helium Test'
git -C "$test_root/src" add out/Test/args.gn
git -C "$test_root/src" commit -qm initial

cat > "$test_root/bin/gn" <<EOF
#!/usr/bin/env bash
sed 's/=/ = /' '$repo_root/helium-chromium/flags.gn'
cat <<'ARGS'
ffmpeg_branding = "Chrome"
media_use_ffmpeg = true
proprietary_codecs = true
is_debug = false
dcheck_always_on = false
debuggable_apks = true
chrome_public_manifest_package = "computer.helium.passwords.test"
android_override_version_code = "$HELIUM_ANDROID_VERSION_CODE"
android_override_version_name = "$HELIUM_ANDROID_VERSION_NAME"
target_cpu = "arm64"
target_os = "android"
ARGS
EOF
chmod +x "$test_root/bin/gn"
cat > "$test_root/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *helium-chromium*' rev-parse HEAD') printf '%s\\n' '$HELIUM_ANDROID_CORE_COMMIT' ;;
  *"$test_root/src"*' rev-parse HEAD') printf '%s\\n' '$HELIUM_ANDROID_CHROMIUM_COMMIT' ;;
  *' rev-parse HEAD') printf '%040d\\n' 1 ;;
  *' status '*) exit 0 ;;
  *) echo "unexpected fake git invocation: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/git"
mkdir -p "$test_root/runtime-kit"
cat > "$test_root/bin/runtime-kit-verifier" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_root/bin/runtime-kit-verifier"

PATH="$test_root/bin:$PATH" GN="$test_root/bin/gn" \
  HELIUM_ANDROID_BUILD_DRIVER="$repo_root/scripts/chromium/build-android-ci.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_VERIFIER="$repo_root/scripts/chromium/verify-android-runtime-kit-source.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  HELIUM_ANDROID_RUNTIME_KIT_SHA256="$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" \
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
  "$test_root/src" out/Test "$test_root/provenance" "$repo_root" \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT"

grep -qx 'proprietary_codecs = true' "$test_root/provenance/gn-args-resolved.txt"
grep -qx 'chrome_public_manifest_package = "computer.helium.passwords.test"' \
  "$test_root/provenance/gn-args-resolved.txt"
grep -qx 'debuggable_apks = true' \
  "$test_root/provenance/gn-args-resolved.txt"
cmp -s <(sed 's/=/ = /' "$repo_root/helium-chromium/flags.gn" | sort) \
  "$test_root/provenance/locked-gn-args-resolved.txt"
grep -Eq '^[0-9a-f]{40}$' "$test_root/provenance/chromium-source-commit.txt"
grep -qx "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  "$test_root/provenance/depot-tools-commit.txt"
grep -qx 'DEPOT_TOOLS_UPDATE=0' \
  "$test_root/provenance/depot-tools-update-policy.txt"
grep -q 'chromium/patches/0001-helium-sync-overlay-files.patch' \
  "$test_root/provenance/sync-inputs.sha256"

cp "$test_root/src/out/Test/args.gn" "$test_root/src/out/Test/args.reassigned.gn"
printf 'enable_mdns = true\n' >> "$test_root/src/out/Test/args.gn"
if PATH="$test_root/bin:$PATH" GN="$test_root/bin/gn" \
  HELIUM_ANDROID_BUILD_DRIVER="$repo_root/scripts/chromium/build-android-ci.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_VERIFIER="$repo_root/scripts/chromium/verify-android-runtime-kit-source.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  HELIUM_ANDROID_RUNTIME_KIT_SHA256="$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" \
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
  "$test_root/src" out/Test "$test_root/reassigned" "$repo_root" \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  2>/dev/null; then
  echo 'Android args.gn locked-key reassignment unexpectedly passed' >&2
  exit 1
fi
mv "$test_root/src/out/Test/args.reassigned.gn" "$test_root/src/out/Test/args.gn"

sed -i 's/proprietary_codecs = true/proprietary_codecs = false/' "$test_root/bin/gn"
if PATH="$test_root/bin:$PATH" GN="$test_root/bin/gn" \
  HELIUM_ANDROID_BUILD_DRIVER="$repo_root/scripts/chromium/build-android-ci.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_VERIFIER="$repo_root/scripts/chromium/verify-android-runtime-kit-source.sh" \
  HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  HELIUM_ANDROID_RUNTIME_KIT_SHA256="$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" \
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
  "$test_root/src" out/Test "$test_root/rejected" "$repo_root" \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  2>/dev/null; then
  echo 'codec-stripped Android configuration unexpectedly passed' >&2
  exit 1
fi

grep -Fq 'find "$PWD" -mindepth 2 -name .git' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'verify-android-media-config.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'cp -a "$artifact_dir/build-provenance" "$staging/"' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'CHROMIUM_ANDROID_PROVENANCE_ONLY:-false' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'github_workspace=$(realpath -m "$GITHUB_WORKSPACE")' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'compile-proof.env' "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'compile-${artifact_target}-${target_cpu}.tar.xz' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'package_runtime_acceptance "$staging/runtime-acceptance"' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'android-build-environment.sh" record' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'run-device-probe.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'verify-probe-pair.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'audit-probe-pair.mjs' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'disposable-browser.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'schema_version=7' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'HELIUM_ANDROID_RUNTIME_KIT_ROOT' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'runtime_kit_commit' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
! grep -Fq 'show "$sync_commit:scripts/android-media/' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'prepare-cookie-acceptance-profile.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'probe_schema_version=1' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'prepare-android-source.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'ensure_bootstrap' \
  "$repo_root/scripts/chromium/prepare-android-source.sh"
! grep -Fq 'gclient-sync-direct.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
! grep -Fq 'cache_dir = None' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'verify-depot-tools-cache-contract.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'export DEPOT_TOOLS_UPDATE=0' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq '"$workspace/depot_tools/gclient" "$@"' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'HELIUM_ANDROID_DEPOT_TOOLS_COMMIT' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
! grep -Fq 'configure_git_cache_pack_memory' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
! grep -Fq 'GIT_CONFIG_COUNT' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'install -m 755 "$runtime_kit_root/$source"' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'runtime acceptance kit checksum inventory is invalid' \
  "$repo_root/scripts/chromium/verify-android-artifact.sh"
grep -Fq 'artifact_target=chrome_public_apk' \
  "$repo_root/scripts/chromium/verify-android-artifact.sh"
grep -Fq 'android_override_version_code' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'android_override_version_name' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'debuggable_apks = $android_debuggable_apks' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'dump badging' \
  "$repo_root/scripts/chromium/verify-android-artifact.sh"
grep -Fq 'status --short --untracked-files=no' \
  "$repo_root/scripts/chromium/verify-android-media-config.sh"
! grep -Fq 'status --short --untracked-files=all' \
  "$repo_root/scripts/chromium/verify-android-media-config.sh"

if GITHUB_WORKSPACE="$test_root" HELIUM_SYNC_REPO="$repo_root" \
  HELIUM_ANDROID_RUNTIME_KIT_VERIFIER="$test_root/bin/runtime-kit-verifier" \
  HELIUM_ANDROID_RUNTIME_KIT_ROOT="$test_root/runtime-kit" \
  HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  HELIUM_ANDROID_RUNTIME_KIT_SHA256="$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" \
  CHROMIUM_ANDROID_MANIFEST_PACKAGE=arbitrary.example \
  "$repo_root/scripts/chromium/build-android-ci.sh" \
  >"$test_root/arbitrary-package.out" 2>&1; then
  echo 'arbitrary Android package unexpectedly passed' >&2
  exit 1
fi
grep -q 'must be computer.helium.passwords or computer.helium.passwords.test' \
  "$test_root/arbitrary-package.out"

grep -Fq 'CHROMIUM_ANDROID_MANIFEST_PACKAGE:-computer.helium.passwords' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'computer.helium.passwords)' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'computer.helium.passwords.test)' \
  "$repo_root/scripts/chromium/build-android-ci.sh"

echo 'Android media build configuration contract passed'
