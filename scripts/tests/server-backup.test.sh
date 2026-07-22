#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-server-backup-test.XXXXXX)
restore_target="/tmp/helium-sync-restore.test-$$"
cleanup() {
  [ ! -e "$restore_target" ] || find "$restore_target" -depth -delete
  find "$test_root" -depth -delete
}
trap cleanup EXIT

go build -trimpath -o "$test_root/helium-sync" "$repo_root/cmd/helium-sync"
"$test_root/helium-sync" seed-init \
  --state-file "$test_root/seed/client.json" \
  --token-file "$test_root/seed/token" \
  --bootstrap-file "$test_root/bootstrap.json" >/dev/null
"$test_root/helium-sync" server-init \
  --data-dir "$test_root/server" \
  --devices-file "$test_root/server/devices.json" \
  --bootstrap-file "$test_root/bootstrap.json" >/dev/null

# Recovery recipients belong with d, never in the opaque server backup. This
# decoy proves the backup allowlist does not silently absorb misplaced recovery
# material from the server directory.
printf 'age1syntheticrecipientmuststayoutsidebackup\n' \
  >"$test_root/server/recovery-recipients.txt"
before=$(find "$test_root/server" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')

output=$(HELIUM_SERVER_DATA_DIR="$test_root/server" \
  HELIUM_SERVER_SERVICE=none HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" backup "$test_root/backup")
archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$output")
[ -s "$archive" ]
manifest=${archive%.tar.zst}.env
[[ $(stat -c %a "$test_root/backup") == 700 ]]
[[ $(stat -c %a "$test_root/backup/generations") == 700 ]]
[[ $(stat -c %a "$test_root/backup/.backup.lock") == 600 ]]
[[ $(stat -c %a "$archive") == 600 ]]
[[ $(stat -c %a "$manifest") == 600 ]]
after=$(find "$test_root/server" -type f -print0 | sort -z | \
  xargs -0 sha256sum | sha256sum | awk '{print $1}')
[[ "$after" == "$before" ]]
if tar --zstd -tf "$archive" | grep -Fq recovery-recipients.txt; then
  echo "opaque backup included recovery-recipient material" >&2
  exit 1
fi
HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" restore-drill \
  "$archive" "$restore_target" >/dev/null
[ -s "$restore_target/server/devices.json" ]

cp "$archive" "$test_root/corrupt.tar.zst"
cp "${archive%.tar.zst}.env" "$test_root/corrupt.env"
printf x >>"$test_root/corrupt.tar.zst"
if HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" restore-drill \
  "$test_root/corrupt.tar.zst" "/tmp/helium-sync-restore.corrupt-$$" \
  >/dev/null 2>&1; then
  echo "corrupt server backup passed restore" >&2
  exit 1
fi

original_manifest=$(cat "$manifest")
printf '%s\narchive_sha256=deadbeef\n' "$original_manifest" >"$manifest"
if HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" restore-drill \
  "$archive" "/tmp/helium-sync-restore.duplicate-$$" >/dev/null 2>&1; then
  echo "duplicate manifest field passed restore" >&2
  exit 1
fi
printf '%s\nunknown=value\n' "$original_manifest" >"$manifest"
if HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" restore-drill \
  "$archive" "/tmp/helium-sync-restore.unknown-$$" >/dev/null 2>&1; then
  echo "unknown manifest field passed restore" >&2
  exit 1
fi
printf '%s\n' "$original_manifest" | \
  sed 's/^archive_bytes=.*/archive_bytes=1/' >"$manifest"
if HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" restore-drill \
  "$archive" "/tmp/helium-sync-restore.bytes-$$" >/dev/null 2>&1; then
  echo "incorrect manifest byte count passed restore" >&2
  exit 1
fi
printf '%s\n' "$original_manifest" >"$manifest"

echo "server_backup_restore=passed"
