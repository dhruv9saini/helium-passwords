#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
backup_tool=${HELIUM_PROFILE_BACKUP_TOOL:-$repo_root/scripts/profile-backup/helium-profile-backup.sh}
acceptance=${HELIUM_NATIVE_RECOVERY_ACCEPTANCE:-$repo_root/scripts/native-recovery/acceptance.mjs}
adb_bin=${ADB:-adb}
package=${CHROMIUM_ANDROID_PACKAGE:-computer.helium.sync.test}

usage() {
  cat >&2 <<'EOF'
usage: backup-android-native-recovery.sh CONFIG [GENERATION]

Stream OnePlus's browser-native neutral password/cookie snapshot directory
directly through the common two-destination backup boundary. The snapshots
are atomically published by Chromium outside app_chrome; the browser need not
be stopped. A concurrent snapshot refresh changes the second stream hash and
fails the generation instead of publishing mixed bytes.
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 64; }
[[ "$package" == computer.helium.sync.test ]] || {
  echo "native recovery backup is disposable .test-package only" >&2
  exit 64
}
config=$(realpath -e -- "$1")
generation=${2:-"$(date -u +%Y%m%dT%H%M%SZ)-$(tr -d - </proc/sys/kernel/random/uuid | cut -c1-16)"}
[[ "$generation" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]] || {
  echo "invalid generation" >&2
  exit 64
}

data_dir=$("$adb_bin" shell "dumpsys package '$package'" | tr -d '\r' |
  sed -n 's/.*dataDir=//p' | head -n1)
[[ "$data_dir" =~ ^/data/(user/[0-9]+|data)/[A-Za-z0-9._]+$ ]] || {
  echo "could not resolve a safe installed package dataDir" >&2
  exit 1
}
recovery_path=$data_dir/files/helium-native-recovery/oneplus/default
config_source_count=$(awk -F= '$1 == "source_path" {count++} END {print count+0}' "$config")
config_source=$(awk -F= '$1 == "source_path" {print substr($0,13)}' "$config")
[[ "$config_source_count" == 1 && "$config_source" == "$recovery_path" ]] || {
  echo "native recovery backup config does not name the installed snapshot path" >&2
  exit 1
}

inventory=$("$adb_bin" shell "/debug_ramdisk/su -c '
set -eu
ROOT=\"$recovery_path\"
test -d \"\$ROOT\"
test ! -L \"\$ROOT\"
test \"\$(stat -c %a \"\$ROOT\")\" = 700
for FILE in .helium-native-recovery-root-v1 passwords.current.json cookies.current.json; do
  test -f \"\$ROOT/\$FILE\"
  test ! -L \"\$ROOT/\$FILE\"
  test \"\$(stat -c %a \"\$ROOT/\$FILE\")\" = 600
done
NOW=\$(date +%s)
for FILE in passwords.current.json cookies.current.json; do
  MTIME=\$(stat -c %Y \"\$ROOT/\$FILE\")
  AGE=\$((NOW - MTIME))
  test \"\$AGE\" -ge -30
  test \"\$AGE\" -le 600
done
find \"\$ROOT\" -mindepth 1 -maxdepth 1 -printf \"%f\\n\" | sort
'" | tr -d '\r')
[[ "$inventory" == $'.helium-native-recovery-root-v1\ncookies.current.json\npasswords.current.json' ]] || {
  echo "Android native recovery snapshot inventory is invalid" >&2
  exit 1
}
for kind in passwords cookies; do
  "$adb_bin" exec-out /debug_ramdisk/su -c \
    "cat '$recovery_path/$kind.current.json'" |
    node "$acceptance" verify-snapshot-stream --kind "$kind" \
      --device oneplus --max-age-seconds 600 >/dev/null
done

archive_parent=${recovery_path%/*}
archive_root=${recovery_path##*/}
stream_recovery() {
  "$adb_bin" exec-out /debug_ramdisk/su -c \
    "cd '$archive_parent' && /system/bin/tar -cf - '$archive_root'"
}

work_dir=$(mktemp -d)
fingerprint_pipe=$work_dir/fingerprint.pipe
fingerprint_file=$work_dir/fingerprint.sha256
cleanup() {
  [[ -z "${fingerprint_pid:-}" ]] ||
    kill "$fingerprint_pid" 2>/dev/null || true
  find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
mkfifo -m 600 "$fingerprint_pipe"
sha256sum <"$fingerprint_pipe" | awk '{print $1}' >"$fingerprint_file" &
fingerprint_pid=$!
source_bytes=$(stream_recovery | tee "$fingerprint_pipe" | wc -c)
wait "$fingerprint_pid"
fingerprint_pid=
[[ "$source_bytes" =~ ^[1-9][0-9]*$ ]] || {
  echo "Android native recovery stream was empty" >&2
  exit 1
}
source_tree_sha=$(tr -d '\r\n' <"$fingerprint_file")
[[ "$source_tree_sha" =~ ^[a-f0-9]{64}$ ]] || {
  echo "Android native recovery fingerprint failed" >&2
  exit 1
}

result=$(stream_recovery |
  "$backup_tool" \
    backup-stream "$config" "$generation" "$source_tree_sha" \
    "$source_bytes" "$archive_root")
grep -qx 'backup=committed' <<<"$result"
committed_sha=$(awk -F= '$1 == "source_tree_sha256" {print $2}' <<<"$result")
[[ "$committed_sha" == "$source_tree_sha" ]] || {
  echo "committed Android native recovery fingerprint mismatch" >&2
  exit 1
}
printf '%s\n' "$result"
