#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
adb_bin=${ADB:-adb}
package=${CHROMIUM_ANDROID_PACKAGE:-computer.helium.sync}

usage() {
  cat >&2 <<'EOF'
usage: backup-android-chromium-profile.sh CONFIG [GENERATION]

Force-stop Helium Sync and stream its complete app_chrome tree directly from
Android tar through zstd and age into the CONFIG's two independent destination
filesystems. Plaintext profile data is never written on lm.
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 64; }
[[ "$package" == computer.helium.sync || "$package" == computer.helium.sync.test ]] || {
  echo "unsupported Android package" >&2
  exit 64
}
config=$(realpath -e -- "$1")
generation=${2:-"$(date -u +%Y%m%dT%H%M%SZ)-$(tr -d - </proc/sys/kernel/random/uuid | cut -c1-16)"}
[[ "$generation" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]] || {
  echo "invalid generation" >&2
  exit 64
}

data_dir=$("$adb_bin" shell "dumpsys package '$package'" | tr -d '\r' | sed -n 's/.*dataDir=//p' | head -n1)
[[ "$data_dir" =~ ^/data/(user/[0-9]+|data)/[A-Za-z0-9._]+$ ]] || {
  echo "could not resolve a safe installed package dataDir" >&2
  exit 1
}
profile_path=$data_dir/app_chrome
config_source_count=$(awk -F= '$1 == "source_path" {count++} END {print count+0}' "$config")
config_source=$(awk -F= '$1 == "source_path" {print substr($0,13)}' "$config")
[[ "$config_source_count" == 1 && "$config_source" == "$profile_path" ]] || {
  echo "profile backup config does not name the installed app_chrome path" >&2
  exit 1
}

"$adb_bin" shell "am force-stop '$package'"
if "$adb_bin" shell "pidof '$package'" | grep -q '[0-9]'; then
  echo "Android package is still running after force-stop" >&2
  exit 1
fi
"$adb_bin" shell "/debug_ramdisk/su -c 'test -d \"$profile_path\"'"

archive_parent=${profile_path%/*}
archive_root=${profile_path##*/}
stream_profile() {
  "$adb_bin" exec-out /debug_ramdisk/su -c \
    "cd '$archive_parent' && /system/bin/tar -cf - '$archive_root'"
}

work_dir=$(mktemp -d)
fingerprint_pipe=$work_dir/fingerprint.pipe
fingerprint_file=$work_dir/fingerprint.sha256
cleanup() {
  [[ -z "${fingerprint_pid:-}" ]] || kill "$fingerprint_pid" 2>/dev/null || true
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
mkfifo -m 600 "$fingerprint_pipe"
sha256sum <"$fingerprint_pipe" | awk '{print $1}' >"$fingerprint_file" &
fingerprint_pid=$!
source_bytes=$(stream_profile | tee "$fingerprint_pipe" | wc -c)
wait "$fingerprint_pid"
fingerprint_pid=
[[ "$source_bytes" =~ ^[1-9][0-9]*$ ]] || { echo "Android profile archive was empty" >&2; exit 1; }
source_tree_sha=$(tr -d '\r\n' <"$fingerprint_file")
[[ "$source_tree_sha" =~ ^[a-f0-9]{64}$ ]] || { echo "Android profile fingerprint failed" >&2; exit 1; }

result=$(stream_profile | "$repo_root/scripts/profile-backup/helium-profile-backup.sh" \
  backup-stream "$config" "$generation" "$source_tree_sha" "$source_bytes" "$archive_root")
grep -qx 'backup=committed' <<<"$result"
[[ "$(awk -F= '$1 == "source_tree_sha256" {print $2}' <<<"$result")" == "$source_tree_sha" ]] || {
  echo "committed Android backup fingerprint mismatch" >&2
  exit 1
}
printf '%s\n' "$result"
