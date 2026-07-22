#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 ARCHIVE EXPECTED_PACKAGE EXPECTED_HELIUM_SYNC_COMMIT" >&2
  exit 64
fi

archive=$(realpath "$1")
expected_package=$2
expected_sync_commit=$3
aapt2=${AAPT2:-aapt2}

case "$expected_package" in
  computer.helium.sync|computer.helium.sync.test) ;;
  *) echo "invalid expected Android package" >&2; exit 64 ;;
esac
[[ "$expected_sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected Helium Sync commit must be a full SHA-1" >&2
  exit 64
}
command -v "$aapt2" >/dev/null

temporary=$(mktemp -d /tmp/helium-android-artifact.XXXXXX)
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT

while IFS= read -r entry; do
  case "$entry" in
    /*|..|../*|*/../*|*/..) echo "unsafe archive path: $entry" >&2; exit 1 ;;
  esac
done < <(tar -tf "$archive")
tar -xf "$archive" -C "$temporary"

provenance="$temporary/build-provenance"
[[ -d "$provenance" ]] || { echo "missing build provenance" >&2; exit 1; }
(
  cd "$provenance"
  sha256sum -c provenance.sha256
)

# shellcheck source=../../chromium/android-build.lock
. "$provenance/android-build.lock"
[[ "$(tr -d '\r\n' < "$provenance/chromium-source-commit.txt")" == \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
  echo "artifact Chromium commit does not match its lock" >&2
  exit 1
}
[[ "$(tr -d '\r\n' < "$provenance/helium-sync-commit.txt")" == \
  "$expected_sync_commit" ]] || {
  echo "artifact Helium Sync commit does not match the requested source" >&2
  exit 1
}
[[ ! -s "$provenance/helium-sync-status.txt" ]] || {
  echo "artifact was built from a dirty tracked source tree" >&2
  exit 1
}
grep -qx "chrome_public_manifest_package = \"$expected_package\"" \
  "$provenance/gn-args-resolved.txt" || {
  echo "artifact GN package does not match the expected package" >&2
  exit 1
}

mapfile -d '' apks < <(find "$temporary" -type f -name HeliumSync.apk -print0)
[[ ${#apks[@]} -eq 1 ]] || {
  echo "artifact must contain exactly one HeliumSync.apk" >&2
  exit 1
}
manifest_package=$($aapt2 dump packagename "${apks[0]}")
[[ "$manifest_package" == "$expected_package" ]] || {
  echo "APK manifest package does not match GN provenance" >&2
  exit 1
}

printf 'archive_sha256=%s\n' "$(sha256sum "$archive" | cut -d' ' -f1)"
printf 'package=%s\n' "$manifest_package"
printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
printf 'helium_sync_commit=%s\n' "$expected_sync_commit"
printf 'apk_path=%s\n' "${apks[0]#$temporary/}"
