#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 ANDROID_ARCHIVE EXPECTED_PACKAGE EXPECTED_HELIUM_SYNC_COMMIT NEW_OUTPUT_DIRECTORY" >&2
  exit 64
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
"$repo_root/scripts/chromium/validate-android-build-lock.sh" >/dev/null
archive=$(realpath "$1")
expected_package=$2
expected_sync_commit=$3
output=$(realpath -m "$4")

case "$expected_package" in
  computer.helium.sync.test) expected_apk=HeliumSync.apk ;;
  computer.helium.control.test) expected_apk=ChromiumControl.apk ;;
  *) echo "expected package must be a disposable Sync or control identity" >&2; exit 64 ;;
esac

[[ "$expected_sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected Helium Sync commit must be a full SHA-1" >&2
  exit 64
}
[[ ! -e "$output" ]] || { echo "output directory already exists" >&2; exit 1; }
command -v tar >/dev/null
command -v sha256sum >/dev/null

output_parent=$(dirname "$output")
mkdir -p "$output_parent"
temporary=$(mktemp -d "$output_parent/.helium-android-acceptance.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT

verify_result="$temporary/verify.env"
"$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$archive" "$expected_package" "$expected_sync_commit" > "$verify_result"

extracted="$temporary/extracted"
staged="$temporary/staged"
mkdir -p "$extracted" "$staged"
tar -xf "$archive" -C "$extracted"
mapfile -d '' apks < <(find "$extracted" -type f -name "$expected_apk" -print0)
[[ ${#apks[@]} -eq 1 ]] || { echo "verified archive lost its unique APK" >&2; exit 1; }

install -m 600 "${apks[0]}" "$staged/Browser-test.apk"
cp -a "$extracted/build-provenance" "$staged/build-provenance"
cp -a "$extracted/runtime-acceptance" "$staged/runtime-acceptance"
mkdir -p "$staged/media"
"$staged/runtime-acceptance/generate-fixtures.sh" "$staged/media"
(
  cd "$staged/media"
  sha256sum -c SHA256SUMS
)

{
  printf 'schema_version=2\n'
  printf 'package=%s\n' "$expected_package"
  printf 'helium_sync_commit=%s\n' "$expected_sync_commit"
  printf 'chromium_commit=%s\n' \
    "$(tr -d '\r\n' < "$staged/build-provenance/chromium-source-commit.txt")"
  printf 'version_code=%s\n' "$HELIUM_ANDROID_VERSION_CODE"
  printf 'version_name=%s\n' "$HELIUM_ANDROID_VERSION_NAME"
  printf 'source_archive_sha256=%s\n' "$(sha256sum "$archive" | cut -d' ' -f1)"
  printf 'apk_sha256=%s\n' "$(sha256sum "$staged/Browser-test.apk" | cut -d' ' -f1)"
  printf 'runtime_kit_sha256=%s\n' \
    "$(sha256sum "$staged/runtime-acceptance/SHA256SUMS" | cut -d' ' -f1)"
  printf 'prepared_at=%s\n' "$(date --iso-8601=seconds)"
} > "$staged/acceptance.env"

(
  cd "$staged"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > PACKAGE_SHA256SUMS
)
mv "$staged" "$output"
trap - EXIT
find "$temporary" -depth -delete
printf 'acceptance_directory=%s\n' "$output"
cat "$output/acceptance.env"
