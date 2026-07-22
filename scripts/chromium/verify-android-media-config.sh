#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 CHROMIUM_SRC OUT_DIR PROVENANCE_DIR HELIUM_SYNC_REPO REQUESTED_CHROMIUM_REF" >&2
  exit 64
fi

chromium_src=$(cd "$1" && pwd)
out_dir=$2
provenance_dir=$3
repo_root=$(cd "$4" && pwd)
requested_ref=$5
gn_bin=${GN:-gn}
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"

[[ -f "$chromium_src/$out_dir/args.gn" ]] || {
  echo "missing Android args.gn: $chromium_src/$out_dir/args.gn" >&2
  exit 1
}
command -v "$gn_bin" >/dev/null
[[ "$requested_ref" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
  echo "requested Chromium ref does not match android-build.lock" >&2
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
require_arg '^chrome_public_manifest_package = "computer\.helium\.sync(\.test)?"$' \
  'manifest package must be the fixed production or disposable Helium Sync identity'

cp "$chromium_src/$out_dir/args.gn" "$provenance_dir/args.gn"
cp "$repo_root/chromium/android-build.lock" "$provenance_dir/android-build.lock"
printf '%s\n' "$requested_ref" > "$provenance_dir/chromium-ref-requested.txt"
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

sha256sum \
  "$provenance_dir/args.gn" \
  "$provenance_dir/gn-args-resolved.txt" \
  "$provenance_dir/chromium-source-commit.txt" \
  "$provenance_dir/helium-core-commit.txt" \
  "$provenance_dir/helium-sync-commit.txt" \
  "$provenance_dir/android-composition.sha256" \
  "$provenance_dir/sync-inputs.sha256" \
  > "$provenance_dir/provenance.sha256"

printf 'Android media configuration verified: %s\n' "$provenance_dir"
