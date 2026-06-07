#!/usr/bin/env bash
set -euo pipefail

adb_bin=${ADB:-adb}
root=${ARCH_CHROOT:-/data/local/chroots/arch}
package=${CHROMIUM_ANDROID_PACKAGE:-org.chromium.chrome}
base_url=${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}
device_name=${HELIUM_ANDROID_SYNC_DEVICE_NAME:-helium-android}
token_src=${HELIUM_PASSWORD_SYNC_TOKEN:-$root/root/.local/share/helium-sync/token}

tmp_token=/data/local/tmp/helium-sync-token.$$
cleanup() {
  "$adb_bin" shell "rm -f '$tmp_token'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$adb_bin" shell "su -c 'test -s \"$token_src\" && cp \"$token_src\" \"$tmp_token\" && chmod 0644 \"$tmp_token\"'"

"$adb_bin" shell "run-as '$package' sh -c '
set -eu
for dir in helium-sync app_chrome/helium-sync app_chrome/Default/helium-sync; do
  mkdir -p \"\$dir\"
  cp \"$tmp_token\" \"\$dir/token\"
  printf %s\\\\n \"$base_url\" >\"\$dir/base_url\"
  printf %s\\\\n \"$device_name\" >\"\$dir/device_name\"
  chmod 0600 \"\$dir/token\" \"\$dir/base_url\" \"\$dir/device_name\"
done
'"

echo "Configured native Android Chromium Sync for $package as $device_name."
