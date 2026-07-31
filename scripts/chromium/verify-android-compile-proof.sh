#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 ARCHIVE EXPECTED_TARGET EXPECTED_HELIUM_SYNC_COMMIT" >&2
  exit 64
fi

archive=$(realpath "$1")
expected_target=$2
expected_sync_commit=$3
[[ -n "$expected_target" && "$expected_target" != *$'\n'* ]] || {
  echo "expected target must be one nonempty line" >&2
  exit 64
}
[[ "$expected_sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected Helium Sync commit must be a full SHA-1" >&2
  exit 64
}

temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-compile-proof.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT

while IFS= read -r entry; do
  case "$entry" in
    /*|..|../*|*/../*|*/..) echo "unsafe archive path: $entry" >&2; exit 1 ;;
  esac
done < <(tar -tf "$archive")
tar -xf "$archive" -C "$temporary"

provenance="$temporary/build-provenance"
proof="$temporary/compile-proof.env"
[[ -d "$provenance" && -f "$proof" && ! -L "$proof" ]] || {
  echo "compile proof archive is incomplete" >&2
  exit 1
}
(
  cd "$provenance"
  sha256sum -c provenance.sha256
)

# shellcheck source=../../chromium/android-build.lock
. "$provenance/android-build.lock"
[[ "$(tr -d '\r\n' < "$provenance/chromium-source-commit.txt")" == \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]]
[[ "$(tr -d '\r\n' < "$provenance/depot-tools-commit.txt")" == \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" ]]
grep -qx 'DEPOT_TOOLS_UPDATE=0' \
  "$provenance/depot-tools-update-policy.txt"
[[ "$(tr -d '\r\n' < "$provenance/helium-sync-commit.txt")" == \
  "$expected_sync_commit" ]]
[[ ! -s "$provenance/helium-sync-status.txt" ]]
grep -qx 'target_os = "android"' "$provenance/gn-args-resolved.txt"
grep -qx 'target_cpu = "arm64"' "$provenance/gn-args-resolved.txt"
grep -qx 'proprietary_codecs = true' "$provenance/gn-args-resolved.txt"
grep -qx 'ffmpeg_branding = "Chrome"' "$provenance/gn-args-resolved.txt"

[[ "$(wc -l < "$proof")" -eq 5 ]]
grep -qx 'schema_version=1' "$proof"
grep -Fxq "target=$expected_target" "$proof"
grep -qx 'target_cpu=arm64' "$proof"
grep -Fxq "chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT" "$proof"
grep -Eq '^completed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$proof"

printf 'archive_sha256=%s\n' "$(sha256sum "$archive" | cut -d' ' -f1)"
printf 'target=%s\n' "$expected_target"
printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
printf 'helium_sync_commit=%s\n' "$expected_sync_commit"
printf 'compile_proof=verified\n'
