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
[[ "$(tr -d '\r\n' < "$provenance/depot-tools-commit.txt")" == \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" ]] || {
  echo "artifact depot_tools commit does not match its lock" >&2
  exit 1
}
grep -qx 'DEPOT_TOOLS_UPDATE=0' \
  "$provenance/depot-tools-update-policy.txt" || {
  echo "artifact depot_tools update policy is not pinned" >&2
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

runtime_kit="$temporary/runtime-acceptance"
[[ -d "$runtime_kit" ]] || { echo "missing Android runtime acceptance kit" >&2; exit 1; }
for kit_file in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs kit.env SHA256SUMS; do
  [[ -f "$runtime_kit/$kit_file" && ! -L "$runtime_kit/$kit_file" ]] || {
    echo "runtime acceptance kit is missing $kit_file" >&2
    exit 1
  }
done
[[ "$(find "$runtime_kit" -mindepth 1 -maxdepth 1 | wc -l)" -eq 5 ]] || {
  echo "runtime acceptance kit contains an unexpected file inventory" >&2
  exit 1
}
[[ "$(wc -l < "$runtime_kit/SHA256SUMS")" -eq 4 ]] || {
  echo "runtime acceptance kit checksum inventory is invalid" >&2
  exit 1
}
for checked_file in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs kit.env; do
  grep -Eq "^[0-9a-f]{64}  ${checked_file}$" "$runtime_kit/SHA256SUMS" || {
    echo "runtime acceptance kit checksum inventory is missing $checked_file" >&2
    exit 1
  }
done
(
  cd "$runtime_kit"
  sha256sum -c SHA256SUMS
)
[[ "$(wc -l < "$runtime_kit/kit.env")" -eq 7 ]] || {
  echo "runtime acceptance kit metadata inventory is invalid" >&2
  exit 1
}
grep -qx 'schema_version=1' "$runtime_kit/kit.env"
grep -qx 'probe_schema_version=1' "$runtime_kit/kit.env"
grep -qx "helium_sync_commit=$expected_sync_commit" "$runtime_kit/kit.env"
grep -qx "chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT" "$runtime_kit/kit.env"
grep -qx "manifest_package=$expected_package" "$runtime_kit/kit.env"
grep -qx 'target_cpu=arm64' "$runtime_kit/kit.env"
grep -qx 'artifact_target=chrome_public_apk' "$runtime_kit/kit.env"

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
printf 'apk_sha256=%s\n' "$(sha256sum "${apks[0]}" | cut -d' ' -f1)"
printf 'runtime_kit_sha256=%s\n' "$(sha256sum "$runtime_kit/SHA256SUMS" | cut -d' ' -f1)"
