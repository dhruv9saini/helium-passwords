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

if ! "$adb_bin" shell "run-as '$package' sh -c '
set -eu
for dir in helium-sync app_chrome/helium-sync app_chrome/Default/helium-sync; do
  mkdir -p \"\$dir\"
  cp \"$tmp_token\" \"\$dir/token\"
  printf %s\\\\n \"$base_url\" >\"\$dir/base_url\"
  printf %s\\\\n \"$device_name\" >\"\$dir/device_name\"
  chmod 0600 \"\$dir/token\" \"\$dir/base_url\" \"\$dir/device_name\"
done
'"; then
  "$adb_bin" shell "su -c '
set -eu
package=\"$package\"
base_url=\"$base_url\"
device_name=\"$device_name\"
tmp_token=\"$tmp_token\"
data_dir=\$(dumpsys package \"\$package\" | sed -n \"s/.*dataDir=//p\" | head -n1)
if [ -z \"\$data_dir\" ]; then
  data_dir=\"/data/user/0/\$package\"
fi
uid=\$(cmd package list packages -U | sed -n \"s/^package:\$package uid://p\" | head -n1)
if [ -z \"\$uid\" ]; then
  echo \"Could not resolve package uid for \$package\" >&2
  exit 1
fi
mkdir -p \"\$data_dir/app_chrome/Default\"
for dir in helium-sync app_chrome/helium-sync app_chrome/Default/helium-sync; do
  full_dir=\"\$data_dir/\$dir\"
  mkdir -p \"\$full_dir\"
  cp \"\$tmp_token\" \"\$full_dir/token\"
  printf %s\\\\n \"\$base_url\" >\"\$full_dir/base_url\"
  printf %s\\\\n \"\$device_name\" >\"\$full_dir/device_name\"
  chmod 0600 \"\$full_dir/token\" \"\$full_dir/base_url\" \"\$full_dir/device_name\"
done
chown -R \"\$uid:\$uid\" \"\$data_dir/helium-sync\" \"\$data_dir/app_chrome\"
chmod 0700 \"\$data_dir/helium-sync\" \"\$data_dir/app_chrome\" \"\$data_dir/app_chrome/Default\"
chmod 0700 \"\$data_dir/app_chrome/helium-sync\" \"\$data_dir/app_chrome/Default/helium-sync\"
restorecon -R \"\$data_dir/helium-sync\" \"\$data_dir/app_chrome\" >/dev/null 2>&1 || true
'"
fi

echo "Configured native Android Chromium Sync for $package as $device_name."
