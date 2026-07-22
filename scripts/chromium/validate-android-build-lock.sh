#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
lock="$repo_root/chromium/android-build.lock"

# This file is repository-owned build input, not artifact input.
# shellcheck source=../../chromium/android-build.lock
. "$lock"

for value in \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" \
  "$HELIUM_ANDROID_CORE_COMMIT" \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT"; do
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Android build lock contains a non-immutable commit" >&2
    exit 1
  }
done

[[ "$HELIUM_ANDROID_CHROMIUM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Android build lock contains an invalid Chromium version" >&2
  exit 1
}
[[ "$HELIUM_ANDROID_VERSION_NAME" == "$HELIUM_ANDROID_CHROMIUM_VERSION" ]] || {
  echo "Android versionName must equal the locked Chromium version" >&2
  exit 1
}
for value in \
  "$HELIUM_ANDROID_PREVIOUS_PRODUCTION_VERSION_CODE" \
  "$HELIUM_ANDROID_VERSION_CODE"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "Android version codes must be positive decimal integers" >&2
    exit 1
  }
done
(( 10#$HELIUM_ANDROID_VERSION_CODE > \
   10#$HELIUM_ANDROID_PREVIOUS_PRODUCTION_VERSION_CODE )) || {
  echo "Android versionCode must exceed the installed production version" >&2
  exit 1
}
(( 10#$HELIUM_ANDROID_VERSION_CODE <= 2100000000 )) || {
  echo "Android versionCode exceeds the supported release ceiling" >&2
  exit 1
}

printf 'android_build_lock=valid\nversion_code=%s\nversion_name=%s\n' \
  "$HELIUM_ANDROID_VERSION_CODE" "$HELIUM_ANDROID_VERSION_NAME"
