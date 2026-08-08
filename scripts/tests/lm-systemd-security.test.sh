#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-systemd-root.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

mkdir -p "$test_root/etc/systemd/system" \
  "$test_root/usr/local/libexec/helium-sync-releases/current" \
  "$test_root/usr/bin" "$test_root/usr/lib/systemd"
system_unit_dir=
while IFS= read -r candidate; do
  if [[ -f "$candidate/basic.target" ]]; then
    system_unit_dir=$candidate
    break
  fi
done < <(systemctl show --property=UnitPath --value | tr ' ' '\n')
if [[ -z "$system_unit_dir" ]]; then
  echo 'could not locate the systemd system unit directory' >&2
  exit 1
fi
cp -a "$system_unit_dir" "$test_root/usr/lib/systemd/system"
cp "$repo_root"/systemd/helium-syncd.service \
  "$repo_root"/systemd/helium-sync-server-backup.service \
  "$repo_root"/systemd/helium-sync-server-backup-archive.service \
  "$repo_root"/systemd/helium-sync-server-backup.timer \
  "$test_root/etc/systemd/system/"
for executable in helium-sync helium-syncd helium-sync-endpoint-health \
  helium-sync-server-backup helium-sync-server-backup-control; do
  printf '#!/bin/sh\n' \
    >"$test_root/usr/local/libexec/helium-sync-releases/current/$executable"
  chmod 0755 \
    "$test_root/usr/local/libexec/helium-sync-releases/current/$executable"
done
printf '#!/bin/sh\n' >"$test_root/usr/bin/test"
chmod 0755 "$test_root/usr/bin/test"

systemd-analyze verify --root="$test_root" \
  "$test_root/etc/systemd/system/helium-syncd.service" \
  "$test_root/etc/systemd/system/helium-sync-server-backup.service" \
  "$test_root/etc/systemd/system/helium-sync-server-backup-archive.service" \
  "$test_root/etc/systemd/system/helium-sync-server-backup.timer"
systemd-analyze security --offline=yes \
  "$repo_root/systemd/helium-syncd.service" \
  "$repo_root/systemd/helium-sync-server-backup.service" \
  "$repo_root/systemd/helium-sync-server-backup-archive.service" >/dev/null

controller="$repo_root/systemd/helium-sync-server-backup.service"
worker="$repo_root/systemd/helium-sync-server-backup-archive.service"
grep -Fqx 'InaccessiblePaths=/var/lib/helium-sync /srv/nas' "$controller"
grep -Fqx 'RestrictAddressFamilies=AF_UNIX' "$controller"
grep -Fqx 'CapabilityBoundingSet=' "$controller"
grep -Fqx 'User=helium-sync' "$worker"
grep -Fqx 'ReadOnlyPaths=/var/lib/helium-sync' "$worker"
grep -Fqx 'ReadWritePaths=/srv/nas/helium-sync-server' "$worker"
grep -Fqx 'RestrictAddressFamilies=AF_UNIX' "$worker"
grep -Fqx 'CapabilityBoundingSet=' "$worker"
if grep -Fq 'ConditionPath' "$controller" || grep -Fq 'ConditionPath' "$worker"; then
  echo 'backup units must fail instead of condition-skipping' >&2
  exit 1
fi

echo 'lm_systemd_security=passed'
