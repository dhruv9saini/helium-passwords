#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
adb_bin=${ADB:-adb}
package=${CHROMIUM_ANDROID_PACKAGE:-computer.helium.sync}

usage() {
  cat >&2 <<'EOF'
usage: configure-android-chromium-sync.sh install ENROLLMENT-DIR PROFILE-BACKUP-CONFIG PROFILE-BACKUP-RECEIPT

Install one already-created oneplus enrollment into the native Chromium
profile at <dataDir>/app_chrome/Default/helium-sync.  The app is force-stopped,
the exact full app_chrome profile must already have two verified private
backup copies, and the prior enrollment is retained as a rollback generation.
EOF
}

[[ ${1:-} == install && $# -eq 4 ]] || { usage; exit 64; }
[[ "$package" == computer.helium.sync || "$package" == computer.helium.sync.test ]] || {
  echo "unsupported Android package" >&2
  exit 64
}
enrollment=$(realpath -e -- "$2")
backup_config=$(realpath -e -- "$3")
backup_receipt=$(realpath -e -- "$4")
[[ -d "$enrollment" && ! -L "$enrollment" ]] || { echo "enrollment must be a real directory" >&2; exit 1; }

mapfile -t enrollment_files < <(find "$enrollment" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[[ "${enrollment_files[*]}" == 'base_url client.json token' ]] || {
  echo "enrollment directory must contain exactly base_url, client.json, and token" >&2
  exit 1
}
for name in base_url client.json token; do
  [[ -f "$enrollment/$name" && ! -L "$enrollment/$name" && -s "$enrollment/$name" ]] || {
    echo "invalid enrollment file: $name" >&2
    exit 1
  }
done
[[ "$(stat -c %a "$enrollment/token")" =~ ^(400|600)$ ]] || { echo "token must have mode 0400 or 0600" >&2; exit 1; }
[[ "$(stat -c %a "$enrollment/client.json")" =~ ^(400|600)$ ]] || { echo "client.json must have mode 0400 or 0600" >&2; exit 1; }
base_url=$(tr -d '\r\n' <"$enrollment/base_url")
[[ "$base_url" =~ ^http://100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):44719/?$ &&
    ${BASH_REMATCH[1]} -ge 64 && ${BASH_REMATCH[1]} -le 127 &&
    ${BASH_REMATCH[2]} -le 255 && ${BASH_REMATCH[3]} -le 255 ]] || {
  echo "base_url must be lm's direct Tailnet HTTP endpoint" >&2
  exit 1
}
jq -e --arg package "$package" '
  .version == 2 and .device_id == "oneplus" and .role == "join" and
  (.phase == "pending" or .phase == "active") and
  (.revisions | type == "object") and
  (.sequence | type == "string" and test("^(0|[1-9][0-9]*)$"))
' "$enrollment/client.json" >/dev/null || {
  echo "client.json is not a oneplus join enrollment" >&2
  exit 1
}

data_dir=$("$adb_bin" shell "dumpsys package '$package'" | tr -d '\r' | sed -n 's/.*dataDir=//p' | head -n1)
[[ "$data_dir" =~ ^/data/(user/[0-9]+|data)/[A-Za-z0-9._]+$ ]] || {
  echo "could not resolve a safe installed package dataDir" >&2
  exit 1
}
uid=$("$adb_bin" shell "cmd package list packages -U '$package'" | tr -d '\r' | sed -n "s/^package:$package uid://p" | head -n1)
[[ "$uid" =~ ^[0-9]+$ ]] || { echo "could not resolve package uid" >&2; exit 1; }

backup_admission=$("$repo_root/scripts/profile-backup/helium-profile-backup.sh" \
  verify-receipt "$backup_config" "$backup_receipt" "$data_dir/app_chrome")
[[ "$(awk -F= '$1 == "profile_backup_admission" {print $2}' <<<"$backup_admission")" == verified ]] || exit 1
expected_tree_sha=$(awk -F= '$1 == "source_tree_sha256" {print $2}' <<<"$backup_admission")
[[ "$expected_tree_sha" =~ ^[a-f0-9]{64}$ ]] || { echo "backup admission omitted the source fingerprint" >&2; exit 1; }

"$adb_bin" shell "am force-stop '$package'"
if "$adb_bin" shell "pidof '$package'" | grep -q '[0-9]'; then
  echo "Android package is still running after force-stop" >&2
  exit 1
fi
current_tree_sha=$("$adb_bin" exec-out /debug_ramdisk/su -c \
  "cd '$data_dir' && /system/bin/tar -cf - app_chrome" | sha256sum | awk '{print $1}')
[[ "$current_tree_sha" == "$expected_tree_sha" ]] || {
  echo "Android app_chrome changed after its admitted backup" >&2
  exit 1
}

work_dir=$(mktemp -d)
bundle_name="helium-enrollment-$package-$$.tar"
cleanup() {
  rm -rf -- "$work_dir"
  "$adb_bin" shell "rm -f '/data/local/tmp/$bundle_name'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
tar --format=pax -C "$enrollment" -cf "$work_dir/enrollment.tar" base_url client.json token
"$adb_bin" push "$work_dir/enrollment.tar" "/data/local/tmp/$bundle_name" >/dev/null

"$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
DATA='"'"$data_dir"'"'
UID_NUMBER='"'"$uid"'"'
BUNDLE=/data/local/tmp/'"'"$bundle_name"'"'
TARGET=\"\$DATA/app_chrome/Default/helium-sync\"
INCOMING=\"\$DATA/app_chrome/Default/.helium-sync.incoming.\$\$\"
ROLLBACK_ROOT=\"\$DATA/app_chrome/Default/helium-sync-rollbacks\"
test ! -e \"\$INCOMING\"
mkdir -p \"\$DATA/app_chrome/Default\" \"\$ROLLBACK_ROOT\" \"\$INCOMING\"
/system/bin/tar -xf \"\$BUNDLE\" -C \"\$INCOMING\"
test -s \"\$INCOMING/base_url\"
test -s \"\$INCOMING/client.json\"
test -s \"\$INCOMING/token\"
chmod 0700 \"\$INCOMING\" \"\$ROLLBACK_ROOT\"
chmod 0600 \"\$INCOMING/base_url\" \"\$INCOMING/client.json\" \"\$INCOMING/token\"
chown -R \"\$UID_NUMBER:\$UID_NUMBER\" \"\$INCOMING\" \"\$ROLLBACK_ROOT\"
restorecon -R \"\$INCOMING\" \"\$ROLLBACK_ROOT\" >/dev/null 2>&1 || true
if [ -e \"\$TARGET\" ]; then
  STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
  test ! -e \"\$ROLLBACK_ROOT/\$STAMP\"
  mv \"\$TARGET\" \"\$ROLLBACK_ROOT/\$STAMP\"
fi
mv \"\$INCOMING\" \"\$TARGET\"
restorecon -R \"\$TARGET\" >/dev/null 2>&1 || true
"'

printf 'android_enrollment=installed\npackage=%s\nprofile_config=%s\nbackup_generation=%s\n' \
  "$package" "$data_dir/app_chrome/Default/helium-sync" \
  "$(awk -F= '$1 == "generation" {print $2}' <<<"$backup_admission")"
