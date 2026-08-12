#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tool=$repo_root/scripts/profile-backup/helium-encrypted-cookie-backup.sh
temporary=$(mktemp -d)
cleanup() { find "$temporary" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$temporary/source/default/Default" "$temporary/restores"
printf 'helium-cookie-backup-disposable-v1\n' \
  >"$temporary/source/default/.helium-cookie-backup-disposable-v1"
printf 'synthetic-cookie-store\n' >"$temporary/source/default/Default/Cookies"
printf 'helium-disposable-profile-restore-root\n' \
  >"$temporary/restores/.helium-disposable-profile-restore-root"
printf 'fixture-restic-password\n' >"$temporary/password"
chmod 0600 "$temporary/password"

cat >"$temporary/config" <<EOF
version=1
source_device=fixture
profile_id=default
source_path=$temporary/source/default
repository=$temporary/repository
password_file=$temporary/password
keep_last=2
keep_daily=2
keep_weekly=2
EOF
chmod 0600 "$temporary/config"

"$tool" init "$temporary/config" >"$temporary/init.env"
grep -Fqx 'repository=initialized' "$temporary/init.env"
"$tool" backup "$temporary/config" >"$temporary/backup.env"
grep -Fqx 'backup=verified' "$temporary/backup.env"
snapshot=$(awk -F= '$1 == "snapshot" {print $2}' "$temporary/backup.env")
[[ "$snapshot" =~ ^[0-9a-f]{64}$ ]]
"$tool" check "$temporary/config" >"$temporary/check.env"
grep -Fqx 'integrity=verified' "$temporary/check.env"
grep -Fqx 'snapshots=1' "$temporary/check.env"

target=$temporary/restores/drill-cookie-restic
restore_receipt=$temporary/restores/c3-restore.env
"$tool" restore "$temporary/config" "$snapshot" "$target" "$restore_receipt" \
  >"$temporary/restore.env"
grep -Fqx 'restore=verified' "$temporary/restore.env"
grep -Fqx 'mechanism=encrypted-restic-profile' "$restore_receipt"
grep -Fqx "snapshot=$snapshot" "$restore_receipt"
grep -Eq '^repository_config_sha256=[0-9a-f]{64}$' "$restore_receipt"
grep -Eq '^restored_tree_sha256=[0-9a-f]{64}$' "$restore_receipt"
cmp "$temporary/source/default/Default/Cookies" "$target/Default/Cookies"
grep -Fqx 'helium-cookie-backup-disposable-v1' \
  "$target/.helium-cookie-backup-disposable-v1"

"$tool" retention "$temporary/config" >"$temporary/retention.out"
grep -Fqx 'retention=verified' "$temporary/retention.out"

if "$tool" restore "$temporary/config" "$snapshot" "$target" \
  "$temporary/restores/repeated.env" \
  >/dev/null 2>&1; then
  echo 'encrypted restore replaced an existing target' >&2
  exit 1
fi

echo 'encrypted_cookie_backup=passed'
