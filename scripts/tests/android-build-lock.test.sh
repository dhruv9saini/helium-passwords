#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"

result=$("$repo_root/scripts/chromium/validate-android-build-lock.sh")
grep -qx 'android_build_lock=valid' <<<"$result"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" <<<"$result"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" <<<"$result"
[[ "$HELIUM_ANDROID_VERSION_CODE" -eq 787500005 ]]
[[ "$HELIUM_ANDROID_PREVIOUS_PRODUCTION_VERSION_CODE" -eq 787500004 ]]
[[ "$HELIUM_ANDROID_VERSION_NAME" == "$HELIUM_ANDROID_CHROMIUM_VERSION" ]]

grep -Fq '10#$HELIUM_ANDROID_VERSION_CODE >' \
  "$repo_root/scripts/chromium/validate-android-build-lock.sh"
grep -Fq '10#$HELIUM_ANDROID_VERSION_CODE <= 2100000000' \
  "$repo_root/scripts/chromium/validate-android-build-lock.sh"

printf 'android_build_lock_contract=passed\n'
