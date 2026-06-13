#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
src_dir=${ARCH_DESKTOP_CONTROLLER_SRC:-"$repo_root/android/arch-desktop-controller"}
out_dir=${ARCH_DESKTOP_CONTROLLER_OUT:-"$repo_root/out/arch-desktop-controller"}
sdk=${ANDROID_SDK_ROOT:-/home/dhruv/Builds/helium-sync-local/chromium-android/src/third_party/android_sdk/public}
keystore=${ARCH_DESKTOP_KEYSTORE:-/home/dhruv/.local/state/arch-desktop-controller/debug.keystore}
storepass=${ARCH_DESKTOP_KEYSTORE_PASS:-android}
keypass=${ARCH_DESKTOP_KEY_PASS:-$storepass}
alias_name=${ARCH_DESKTOP_KEY_ALIAS:-archdesktop}

android_jar="$sdk/platforms/android-37.0/android.jar"
aapt2="$sdk/build-tools/37.0.0/aapt2"
d8="$sdk/build-tools/37.0.0/d8"
zipalign="$sdk/build-tools/37.0.0/zipalign"
apksigner="$sdk/build-tools/37.0.0/apksigner"

for tool in "$android_jar" "$aapt2" "$d8" "$zipalign" "$apksigner" "$keystore"; do
  [ -e "$tool" ] || {
    echo "missing required file: $tool" >&2
    exit 1
  }
done

rm -rf "$out_dir/classes" "$out_dir/compiled" "$out_dir/dex" "$out_dir/gen"
mkdir -p "$out_dir/classes" "$out_dir/compiled" "$out_dir/dex" "$out_dir/gen"

"$aapt2" compile --dir "$src_dir/res" -o "$out_dir/compiled/res.zip"
"$aapt2" link \
  -o "$out_dir/arch-desktop-unsigned.apk" \
  -I "$android_jar" \
  --manifest "$src_dir/AndroidManifest.xml" \
  --java "$out_dir/gen" \
  "$out_dir/compiled/res.zip"

javac --release 8 \
  -cp "$android_jar" \
  -d "$out_dir/classes" \
  $(find "$src_dir/src" "$out_dir/gen" -name '*.java' | sort)

"$d8" --min-api 26 --lib "$android_jar" --output "$out_dir/dex" \
  $(find "$out_dir/classes" -name '*.class' | sort)

(cd "$out_dir/dex" && zip -q -u "$out_dir/arch-desktop-unsigned.apk" classes.dex)
"$zipalign" -f 4 "$out_dir/arch-desktop-unsigned.apk" "$out_dir/arch-desktop-aligned.apk"
"$apksigner" sign \
  --ks "$keystore" \
  --ks-pass "pass:$storepass" \
  --ks-key-alias "$alias_name" \
  --key-pass "pass:$keypass" \
  --out "$out_dir/arch-desktop.apk" \
  "$out_dir/arch-desktop-aligned.apk"
"$apksigner" verify --verbose --print-certs "$out_dir/arch-desktop.apk"

printf '%s\n' "$out_dir/arch-desktop.apk"
