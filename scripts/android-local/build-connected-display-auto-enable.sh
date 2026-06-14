#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
src_dir=${CONNECTED_DISPLAY_AUTO_ENABLE_SRC:-"$repo_root/android/connected-display-auto-enable"}
out_dir=${CONNECTED_DISPLAY_AUTO_ENABLE_OUT:-"$repo_root/out/connected-display-auto-enable"}
sdk=${ANDROID_SDK_ROOT:-/home/dhruv/Builds/helium-sync-local/chromium-android/src/third_party/android_sdk/public}

android_jar="$sdk/platforms/android-37.0/android.jar"
d8="$sdk/build-tools/37.0.0/d8"

for tool in "$android_jar" "$d8"; do
  [ -e "$tool" ] || {
    echo "missing required file: $tool" >&2
    exit 1
  }
done

rm -rf "$out_dir/classes" "$out_dir/dex"
mkdir -p "$out_dir/classes" "$out_dir/dex"

javac --release 8 \
  -cp "$android_jar" \
  -d "$out_dir/classes" \
  $(find "$src_dir/src" -name '*.java' | sort)

"$d8" --min-api 26 --lib "$android_jar" --output "$out_dir/dex" \
  $(find "$out_dir/classes" -name '*.class' | sort)

rm -f "$out_dir/connected-display-auto-enable.jar"
(cd "$out_dir/dex" && zip -q "$out_dir/connected-display-auto-enable.jar" classes.dex)
printf '%s\n' "$out_dir/connected-display-auto-enable.jar"
