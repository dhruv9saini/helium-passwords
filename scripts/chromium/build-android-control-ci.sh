#!/usr/bin/env bash
set -euxo pipefail

repo_root=${HELIUM_SYNC_REPO:-"$GITHUB_WORKSPACE/helium-sync"}
repo_root=$(cd "$repo_root" && pwd)
github_workspace=$(realpath -m "$GITHUB_WORKSPACE")
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
"$repo_root/scripts/chromium/validate-android-build-lock.sh" >/dev/null

workspace=${CHROMIUM_WORKSPACE:-"$github_workspace/chromium-android-control"}
workspace=$(realpath -m "$workspace")
artifact_dir=${ARTIFACT_DIR:-"$github_workspace/android-control-artifacts"}
artifact_dir=$(realpath -m "$artifact_dir")
out_dir=${OUT_DIR:-out/Control}
gclient_jobs=${GCLIENT_JOBS:-1}
autoninja_jobs=${AUTONINJA_JOBS:-1}
manifest_package=computer.helium.control.test
target=chrome_public_apk
build_driver=$(realpath -e "${HELIUM_ANDROID_BUILD_DRIVER:-${BASH_SOURCE[0]}}")
locked_gn_verifier=${HELIUM_ANDROID_LOCKED_GN_VERIFIER:-"$repo_root/scripts/chromium/verify-android-locked-gn-args.sh"}
locked_gn_verifier=$(realpath -e "$locked_gn_verifier")
tooling_commit=${HELIUM_ANDROID_TOOLING_COMMIT:-$(git -C "$repo_root" rev-parse HEAD)}
[[ "$tooling_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Android tooling commit must be a full SHA-1" >&2
  exit 1
}

[[ "$autoninja_jobs" == 1 ]] || {
  echo 'AUTONINJA_JOBS must remain 1 for the isolated control build' >&2
  exit 64
}
[[ "$gclient_jobs" == 1 ]] || {
  echo 'GCLIENT_JOBS must remain 1 for the isolated control build' >&2
  exit 64
}

verify_depot_tools() {
  "$repo_root/scripts/chromium/verify-depot-tools-cache-contract.sh" \
    "$workspace/depot_tools" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT"
}

run_pinned_gclient() {
  verify_depot_tools >/dev/null
  export DEPOT_TOOLS_UPDATE=0
  set +e
  "$workspace/depot_tools/gclient" "$@"
  local status=$?
  set -e
  verify_depot_tools >/dev/null
  return "$status"
}

package_runtime_acceptance() {
  local destination=$1
  local sync_commit source
  sync_commit=$(git -C "$repo_root" rev-parse HEAD)
  mkdir -p "$destination"
  for source in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh verify-probe-pair.sh; do
    git -C "$repo_root" show "$sync_commit:scripts/android-media/$source" \
      > "$destination/$source"
    chmod 755 "$destination/$source"
  done
  {
    printf 'schema_version=6\n'
    printf 'probe_schema_version=1\n'
    printf 'helium_sync_commit=%s\n' "$sync_commit"
    printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
    printf 'manifest_package=%s\n' "$manifest_package"
    printf 'version_code=%s\n' "$HELIUM_ANDROID_VERSION_CODE"
    printf 'version_name=%s\n' "$HELIUM_ANDROID_VERSION_NAME"
    printf 'target_cpu=arm64\n'
    printf 'artifact_target=%s\n' "$target"
  } > "$destination/kit.env"
  (
    cd "$destination"
    sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
      disposable-browser.sh prepare-cookie-acceptance-profile.sh \
      run-device-probe.sh verify-probe-pair.sh kit.env > SHA256SUMS
  )
}

CHROMIUM_REF="$HELIUM_ANDROID_CHROMIUM_COMMIT" \
CHROMIUM_URL=https://chromium.googlesource.com/chromium/src.git \
GCLIENT_JOBS="$gclient_jobs" \
  "$repo_root/scripts/chromium/prepare-android-source.sh" "$workspace"
verify_depot_tools
export DEPOT_TOOLS_UPDATE=0
export PATH="$workspace/depot_tools:$PATH"

cd "$workspace/src"
run_pinned_gclient runhooks
git diff --quiet HEAD --
git diff --cached --quiet HEAD --

rm -rf "$artifact_dir/build-provenance"
mkdir -p "$out_dir" "$artifact_dir/build-provenance"
cat "$repo_root/helium-chromium/flags.gn" > "$out_dir/args.gn"
cat >> "$out_dir/args.gn" <<EOF
target_os = "android"
target_cpu = "arm64"
is_official_build = false
is_debug = false
dcheck_always_on = false
debuggable_apks = true
is_component_build = false
use_siso = false
android_static_analysis = "off"
symbol_level = 0
blink_symbol_level = 0
ffmpeg_branding = "Chrome"
proprietary_codecs = true
chrome_public_manifest_package = "$manifest_package"
android_override_version_code = "$HELIUM_ANDROID_VERSION_CODE"
android_override_version_name = "$HELIUM_ANDROID_VERSION_NAME"
EOF
gn gen "$out_dir" --fail-on-unused-args
gn args "$out_dir" --list --short \
  > "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'target_os = "android"' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'target_cpu = "arm64"' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'ffmpeg_branding = "Chrome"' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'proprietary_codecs = true' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'media_use_ffmpeg = true' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'is_debug = false' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'dcheck_always_on = false' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx 'debuggable_apks = true' \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx "chrome_public_manifest_package = \"$manifest_package\"" \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx "android_override_version_code = \"$HELIUM_ANDROID_VERSION_CODE\"" \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"
grep -qx "android_override_version_name = \"$HELIUM_ANDROID_VERSION_NAME\"" \
  "$artifact_dir/build-provenance/gn-args-resolved.txt"

provenance="$artifact_dir/build-provenance"
cp "$out_dir/args.gn" "$provenance/args.gn"
cp "$repo_root/helium-chromium/flags.gn" "$provenance/flags.gn"
"$locked_gn_verifier" \
  "$provenance/flags.gn" "$provenance/args.gn" \
  "$provenance/gn-args-resolved.txt" \
  "$provenance/locked-gn-args-resolved.txt" >/dev/null
{
  printf 'schema_version=1\n'
  printf 'tooling_commit=%s\n' "$tooling_commit"
  printf 'build_driver_source=scripts/chromium/build-android-control-ci.sh\n'
  printf 'build_driver_sha256=%s\n' \
    "$(sha256sum "$build_driver" | cut -d' ' -f1)"
  printf 'locked_gn_verifier_source=scripts/chromium/verify-android-locked-gn-args.sh\n'
  printf 'locked_gn_verifier_sha256=%s\n' \
    "$(sha256sum "$locked_gn_verifier" | cut -d' ' -f1)"
} > "$provenance/android-tooling.env"
cp "$repo_root/chromium/android-build.lock" "$provenance/android-build.lock"
printf '%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT" \
  > "$provenance/chromium-ref-requested.txt"
git rev-parse HEAD > "$provenance/chromium-source-commit.txt"
git status --short --untracked-files=no > "$provenance/chromium-source-status.txt"
[[ ! -s "$provenance/chromium-source-status.txt" ]]
printf '%s\n' "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  > "$provenance/depot-tools-commit.txt"
printf 'DEPOT_TOOLS_UPDATE=0\n' \
  > "$provenance/depot-tools-update-policy.txt"
git -C "$repo_root" rev-parse HEAD > "$provenance/helium-sync-commit.txt"
git -C "$repo_root" status --short --untracked-files=no \
  > "$provenance/helium-sync-status.txt"
[[ ! -s "$provenance/helium-sync-status.txt" ]]
printf 'upstream-control\n' > "$provenance/android-composition.txt"
"$repo_root/scripts/chromium/android-build-environment.sh" record "$provenance"

autoninja -j "$autoninja_jobs" -C "$out_dir" "$target"
control_apk="$out_dir/apks/ChromePublic.apk"
[[ -f "$control_apk" && ! -L "$control_apk" ]]

staging="$artifact_dir/staging"
rm -rf "$staging"
mkdir -p "$staging"
install -m 600 "$control_apk" "$staging/ChromiumControl.apk"
cp -a "$provenance" "$staging/build-provenance"
package_runtime_acceptance "$staging/runtime-acceptance"
tar -C "$staging" -caf "$artifact_dir/chromium-control-apk-arm64.tar.xz" .
