#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
installer=$repo_root/scripts/install-lm-disposable-sync-service.sh
service=$repo_root/systemd/helium-syncd-disposable.service
backup_service=$repo_root/systemd/helium-sync-server-backup-disposable.service

for directive in \
  'ConditionPathExists=%h/.local/state/helium-sync-disposable/SYNTHETIC_ONLY' \
  'ProtectSystem=strict' \
  'ProtectHome=tmpfs' \
  'BindReadOnlyPaths=%h/.local/share/helium-sync-disposable/bin' \
  'BindReadOnlyPaths=%h/.local/state/helium-sync-disposable/config' \
  'BindReadOnlyPaths=%h/.local/state/helium-sync-disposable/tls' \
  'BindPaths=%h/.local/state/helium-sync-disposable/server' \
  'NoNewPrivileges=yes' \
  'PrivateDevices=yes' \
  'IPAddressDeny=any' \
  'IPAddressAllow=100.64.0.0/10' \
  'MemoryMax=256M' \
  'MemorySwapMax=0' \
  'TasksMax=64' \
  'UMask=0077'; do
  grep -Fqx "$directive" "$service"
done

grep -Fq -- '-tls-cert-file %h/.local/state/helium-sync-disposable/tls/current/server-cert.pem' "$service"
grep -Fq -- '-listen ${HELIUM_SYNC_LISTEN}' "$service"
grep -Fqx 'Environment=HELIUM_SERVER_SERVICE_SCOPE=user' "$backup_service"
grep -Fqx 'BindPaths=/srv/nas/helium-sync-server-disposable' "$backup_service"
grep -Fq 'synthetic-only-v1' "$installer"
grep -Fq 'wait_live_endpoint' "$installer"
grep -Fq 'perform_backup_drill >/dev/null' "$installer"
grep -Fq 'systemctl --user enable --now "$service"' "$installer"
grep -Fq 'systemctl --user disable --now "$backup_timer" "$service"' "$installer"
grep -Fq 'service_scope=${HELIUM_SERVER_SERVICE_SCOPE:-system}' \
  "$repo_root/scripts/helium-sync-server-backup.sh"

if grep -Fq 'sudo ' "$installer"; then
  echo "disposable installer unexpectedly requires root" >&2
  exit 1
fi
if grep -Eq 'tailscale (serve|funnel) --bg' "$installer"; then
  echo "disposable installer attempts to configure a Tailscale proxy" >&2
  exit 1
fi

echo "lm_disposable_sync_operator=passed"
