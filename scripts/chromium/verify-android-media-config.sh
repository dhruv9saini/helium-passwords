#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 CHROMIUM_SRC OUT_DIR PROVENANCE_DIR HELIUM_SYNC_REPO REQUESTED_CHROMIUM_REF DEPOT_TOOLS_COMMIT" >&2
  exit 64
fi

chromium_src=$(cd "$1" && pwd)
out_dir=$2
provenance_dir=$3
repo_root=$(cd "$4" && pwd)
requested_ref=$5
depot_tools_commit=$6
gn_bin=${GN:-gn}
build_driver=$(realpath -e "${HELIUM_ANDROID_BUILD_DRIVER:?missing Android build-driver path}")
media_config_verifier=$(realpath -e "${HELIUM_ANDROID_MEDIA_CONFIG_VERIFIER:-${BASH_SOURCE[0]}}")
locked_gn_verifier=$(realpath -e "${HELIUM_ANDROID_LOCKED_GN_VERIFIER:-$repo_root/scripts/chromium/verify-android-locked-gn-args.sh}")
runtime_kit_verifier=$(realpath -e "${HELIUM_ANDROID_RUNTIME_KIT_VERIFIER:?missing Android runtime-kit verifier}")
runtime_kit_commit=${HELIUM_ANDROID_RUNTIME_KIT_COMMIT:?missing Android runtime-kit commit}
runtime_kit_source_sha256=${HELIUM_ANDROID_RUNTIME_KIT_SHA256:?missing Android runtime-kit SHA256SUMS binding}
tooling_commit=${HELIUM_ANDROID_TOOLING_COMMIT:-$(git -C "$repo_root" rev-parse HEAD)}
[[ "$tooling_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Android tooling commit must be a full SHA-1" >&2
  exit 1
}
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
"$repo_root/scripts/chromium/validate-android-build-lock.sh" >/dev/null

[[ -f "$chromium_src/$out_dir/args.gn" ]] || {
  echo "missing Android args.gn: $chromium_src/$out_dir/args.gn" >&2
  exit 1
}
command -v "$gn_bin" >/dev/null
[[ "$requested_ref" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
  echo "requested Chromium ref does not match android-build.lock" >&2
  exit 1
}
[[ "$depot_tools_commit" == "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" ]] || {
  echo "executing depot_tools commit does not match android-build.lock" >&2
  exit 1
}
[[ "$(git -C "$chromium_src" rev-parse HEAD)" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
  echo "prepared Chromium source does not match android-build.lock" >&2
  exit 1
}

mkdir -p "$provenance_dir"
resolved_args="$provenance_dir/gn-args-resolved.txt"
(
  cd "$chromium_src"
  "$gn_bin" args "$out_dir" --list --short
) > "$resolved_args"

require_arg() {
  local pattern=$1
  local description=$2
  if ! grep -Eq "$pattern" "$resolved_args"; then
    echo "Android media configuration rejected: $description" >&2
    exit 1
  fi
}

require_arg '^target_os = "android"$' 'target_os must be android'
require_arg '^target_cpu = "(arm|arm64|x86|x64)"$' 'target_cpu is missing or unsupported'
require_arg '^proprietary_codecs = true$' 'proprietary_codecs must be true for H.264/AAC recognition'
require_arg '^ffmpeg_branding = "Chrome"$' 'ffmpeg_branding must be Chrome for the proprietary FFmpeg configuration'
require_arg '^media_use_ffmpeg = true$' 'media_use_ffmpeg must remain enabled'
require_arg '^is_debug = false$' 'Android APKs must be non-debug Chromium builds'
require_arg '^dcheck_always_on = false$' 'Android APKs must disable always-on DCHECKs'
require_arg '^chrome_public_manifest_package = "computer\.helium\.sync(\.test)?"$' \
  'manifest package must be the fixed production or disposable Helium Sync identity'
if grep -qx 'chrome_public_manifest_package = "computer.helium.passwords.test"' \
    "$resolved_args"; then
  require_arg '^debuggable_apks = true$' \
    'the disposable package must explicitly permit rootless test instrumentation'
else
  require_arg '^debuggable_apks = false$' \
    'the production package must be non-debuggable'
fi
require_arg "^android_override_version_code = \"${HELIUM_ANDROID_VERSION_CODE}\"$" \
  'versionCode must match the monotonic Android build lock'
require_arg "^android_override_version_name = \"${HELIUM_ANDROID_VERSION_NAME//./\\.}\"$" \
  'versionName must match the Chromium engine version'

cp "$chromium_src/$out_dir/args.gn" "$provenance_dir/args.gn"
cp "$repo_root/helium-chromium/flags.gn" "$provenance_dir/flags.gn"
"$locked_gn_verifier" \
  "$provenance_dir/flags.gn" "$provenance_dir/args.gn" "$resolved_args" \
  "$provenance_dir/locked-gn-args-resolved.txt" >/dev/null
{
  printf 'schema_version=1\n'
  printf 'tooling_commit=%s\n' "$tooling_commit"
  printf 'build_driver_source=scripts/chromium/build-android-ci.sh\n'
  printf 'build_driver_sha256=%s\n' \
    "$(sha256sum "$build_driver" | cut -d' ' -f1)"
  printf 'media_config_verifier_source=scripts/chromium/verify-android-media-config.sh\n'
  printf 'media_config_verifier_sha256=%s\n' \
    "$(sha256sum "$media_config_verifier" | cut -d' ' -f1)"
  printf 'locked_gn_verifier_source=scripts/chromium/verify-android-locked-gn-args.sh\n'
  printf 'locked_gn_verifier_sha256=%s\n' \
    "$(sha256sum "$locked_gn_verifier" | cut -d' ' -f1)"
  printf 'runtime_kit_commit=%s\n' "$runtime_kit_commit"
  printf 'runtime_kit_source_sha256=%s\n' "$runtime_kit_source_sha256"
  printf 'runtime_kit_verifier_source=scripts/chromium/verify-android-runtime-kit-source.sh\n'
  printf 'runtime_kit_verifier_sha256=%s\n' \
    "$(sha256sum "$runtime_kit_verifier" | cut -d' ' -f1)"
} > "$provenance_dir/android-tooling.env"
cp "$repo_root/chromium/android-build.lock" "$provenance_dir/android-build.lock"
printf '%s\n' "$requested_ref" > "$provenance_dir/chromium-ref-requested.txt"
printf '%s\n' "$depot_tools_commit" > "$provenance_dir/depot-tools-commit.txt"
printf '%s\n' 'DEPOT_TOOLS_UPDATE=0' \
  > "$provenance_dir/depot-tools-update-policy.txt"
git -C "$chromium_src" rev-parse HEAD > "$provenance_dir/chromium-source-commit.txt"
git -C "$repo_root/helium-chromium" rev-parse HEAD > "$provenance_dir/helium-core-commit.txt"
git -C "$repo_root" rev-parse HEAD > "$provenance_dir/helium-sync-commit.txt"
# The remote workflow places the Chromium checkout below the staged repository.
# Never traverse that untracked tree while a build is running.
git -C "$repo_root" status --short --untracked-files=no > "$provenance_dir/helium-sync-status.txt"

(
  cd "$repo_root"
  find chromium/patches chromium/overlay -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
) > "$provenance_dir/sync-inputs.sha256"

"$repo_root/scripts/chromium/apply-android-backbone.sh" plan \
  > "$provenance_dir/android-composition.tsv"
while IFS=$'\t' read -r layer entry; do
  case "$layer" in
    core) patch_file="$repo_root/helium-chromium/patches/$entry" ;;
    passwords) patch_file="$repo_root/patches/$entry" ;;
    sync) patch_file="$repo_root/chromium/patches/$entry" ;;
    *) echo "unknown Android composition layer: $layer" >&2; exit 1 ;;
  esac
  printf '%s  %s/%s\n' "$(sha256sum "$patch_file" | cut -d' ' -f1)" "$layer" "$entry"
done < "$provenance_dir/android-composition.tsv" \
  > "$provenance_dir/android-composition.sha256"

(
  cd "$provenance_dir"
  sha256sum \
    args.gn \
    flags.gn \
    gn-args-resolved.txt \
    locked-gn-args-resolved.txt \
    android-tooling.env \
    chromium-source-commit.txt \
    chromium-ref-requested.txt \
    depot-tools-commit.txt \
    depot-tools-update-policy.txt \
    helium-core-commit.txt \
    helium-sync-commit.txt \
    helium-sync-status.txt \
    android-build.lock \
    android-composition.sha256 \
    sync-inputs.sha256 \
    > provenance.sha256
)

printf 'Android media configuration verified: %s\n' "$provenance_dir"
