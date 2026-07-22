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

output=$(HELIUM_SERVER_DATA_DIR="$test_root/server" \
  HELIUM_SERVER_SERVICE=none HELIUM_SYNC_CLI="$test_root/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" backup "$test_root/backup")
archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$output")
[ -s "$archive" ]
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

echo "server_backup_restore=passed"
