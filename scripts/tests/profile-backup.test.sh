#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source_root=$(mktemp -d "$repo_root/.profile-backup-source.XXXXXX")
tmp_destination=$(mktemp -d /tmp/helium-profile-backup-a.XXXXXX)
shm_destination=$(mktemp -d /dev/shm/helium-profile-backup-b.XXXXXX)
cleanup() {
  [[ -z "${holder_pid:-}" ]] || kill "$holder_pid" >/dev/null 2>&1 || true
  find "$source_root" "$tmp_destination" "$shm_destination" -depth -delete
}
trap cleanup EXIT

mkdir -p "$source_root/profile/Default/Sessions" "$source_root/bin" \
  "$source_root/restore-root"
chmod 700 "$source_root/restore-root"
: >"$source_root/restore-root/.helium-disposable-profile-restore-root"
printf 'synthetic-session-state\n' >"$source_root/profile/Default/Sessions/Tabs_fixture"
printf 'synthetic-preferences\n' >"$source_root/profile/Default/Preferences"

cat >"$source_root/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode= output= input=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --recipients-file|--identity) shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
case "$mode" in
  encrypt) openssl enc -aes-256-cbc -pbkdf2 -pass pass:synthetic-profile-test -out "$output" ;;
  decrypt) openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:synthetic-profile-test -in "$input" ;;
  *) exit 64 ;;
esac
EOF
chmod 700 "$source_root/bin/age"
PATH="$source_root/bin:$PATH"
export PATH
printf 'AGE-SECRET-KEY-1SYNTHETIC-A\n' >"$source_root/identity-a.txt"
printf 'AGE-SECRET-KEY-1SYNTHETIC-B\n' >"$source_root/identity-b.txt"
printf 'age1synthetic-recipient-a\nage1synthetic-recipient-b\n' >"$source_root/recipients.txt"
chmod 600 "$source_root/identity-a.txt" "$source_root/identity-b.txt" \
  "$source_root/recipients.txt"

config=$source_root/profile-backup.conf
cat >"$config" <<EOF
version=1
source_device=fixture
profile_id=default
source_path=$source_root/profile
age_recipients=$source_root/recipients.txt
age_identity=$source_root/identity-a.txt
retention_keep=2
destination_reserve_bytes=1
destination=copy-a|$tmp_destination
destination=copy-b|$shm_destination
EOF
chmod 600 "$config"

tool=$repo_root/scripts/profile-backup/helium-profile-backup.sh
preflight=$($tool preflight "$config")
grep -qx 'preflight=ok' <<<"$preflight"
generation1=20260722T120000Z-1111111111111111
generation2=20260722T120100Z-2222222222222222
generation3=20260722T120200Z-3333333333333333
backup1=$($tool backup "$config" "$generation1")
receipt=$(awk -F= '$1 == "receipt" {print substr($0,9)}' <<<"$backup1")
test -f "$receipt"
$tool status "$config" "$generation1" | grep -qx 'status=healthy'
$tool verify-receipt "$config" "$receipt" | grep -qx 'profile_backup_admission=verified'

restore=$source_root/restore-root/drill-profile
$tool restore-to-disposable "$config" "$generation1" "$restore" | \
  grep -qx 'restore=disposable-only'
cmp "$source_root/profile/Default/Preferences" "$restore/Default/Preferences"
test -f "$restore/.helium-profile-restore-receipt.env"
if $tool restore-to-disposable "$config" "$generation1" "$restore" >/dev/null 2>&1; then
  echo 'restore overwrote an existing destination' >&2
  exit 1
fi

$tool backup "$config" "$generation2" >/dev/null
$tool backup "$config" "$generation3" >/dev/null
$tool retention-apply "$config" | grep -qx "retired_generation=$generation1"
test -f "$tmp_destination/helium-profile-backups/fixture/default/retired/$generation1/$generation1.tar.zst.age"
test -f "$shm_destination/helium-profile-backups/fixture/default/retired/$generation1/$generation1.tar.zst.age"

cipher="$tmp_destination/helium-profile-backups/fixture/default/generations/$generation2.tar.zst.age"
printf tamper >>"$cipher"
if $tool status "$config" "$generation2" >/dev/null 2>&1; then
  echo 'tampered profile backup passed status' >&2
  exit 1
fi
$tool quarantine "$config" copy-a "$generation2" checksum-failed | \
  grep -qx "quarantined=$generation2"
test ! -e "$cipher"

( exec 9<"$source_root/profile/Default/Preferences"; sleep 30 ) &
holder_pid=$!
if $tool preflight "$config" >/dev/null 2>&1; then
  echo 'open source profile passed preflight' >&2
  exit 1
fi
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=

same_fs_config=$source_root/same-filesystem.conf
sed "s#destination=copy-b|$shm_destination#destination=copy-b|$tmp_destination#" \
  "$config" >"$same_fs_config"
chmod 600 "$same_fs_config"
if $tool preflight "$same_fs_config" >/dev/null 2>&1; then
  echo 'same-filesystem backup destinations passed preflight' >&2
  exit 1
fi

printf 'profile_backup=passed\n'
