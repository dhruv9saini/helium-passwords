#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
src_dir=${INPUT_DISPLAY_ASSOC_SRC:-"$repo_root/android/input-display-assoc"}
out_dir=${INPUT_DISPLAY_ASSOC_OUT:-"$repo_root/out/input-display-assoc"}
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

rm -f "$out_dir/input-display-assoc.jar"
(cd "$out_dir/dex" && zip -q "$out_dir/input-display-assoc.jar" classes.dex)
printf '%s\n' "$out_dir/input-display-assoc.jar"
