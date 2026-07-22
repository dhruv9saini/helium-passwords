#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-lm-operator.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

mkdir -p "$test_root/bin"
go build -trimpath -o "$test_root/bin/helium-sync" "$repo_root/cmd/helium-sync"
cat >"$test_root/bin/tailscale" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "status --json ") cat "${TAILSCALE_STATUS_FIXTURE:?}" ;;
  "serve status --json") cat "${SERVE_STATUS_FIXTURE:?}" ;;
  "funnel status --json") cat "${FUNNEL_STATUS_FIXTURE:?}" ;;
  *) echo "unexpected tailscale invocation: $*" >&2; exit 2 ;;
esac
MOCK
chmod 0755 "$test_root/bin/tailscale"

cat >"$test_root/tailscale.json" <<'JSON'
{
  "BackendState": "Running",
  "Self": {
    "DNSName": "lm.tail0168aa.ts.net.",
    "TailscaleIPs": ["100.100.105.47", "fd7a:115c:a1e0::d001:6983"],
    "Online": true
  }
}
JSON
printf '{}\n' >"$test_root/serve-empty.json"
printf '{}\n' >"$test_root/funnel-empty.json"

"$test_root/bin/helium-sync" tls-ca-init \
  --hostname lm.tail0168aa.ts.net --ip 100.100.105.47 \
  --output-dir "$test_root/offline-ca" >/dev/null
"$test_root/bin/helium-sync" tls-server-issue \
  --ca-cert "$test_root/offline-ca/ca-cert.pem" \
  --ca-key "$test_root/offline-ca/ca-key.pem" \
  --hostname lm.tail0168aa.ts.net --ip 100.100.105.47 \
  --output-dir "$test_root/issued-server" >/dev/null

tls_root="$test_root/installed-tls"
generation=$(sha256sum "$test_root/issued-server/server-cert.pem" | awk '{print $1}')
mkdir -p "$tls_root/generations/$generation"
cp "$test_root/offline-ca/ca-cert.pem" "$tls_root/generations/$generation/ca-cert.pem"
cp "$test_root/issued-server/server-cert.pem" "$tls_root/generations/$generation/server-cert.pem"
cp "$test_root/issued-server/server-key.pem" "$tls_root/generations/$generation/server-key.pem"
chmod 0600 "$tls_root/generations/$generation/server-key.pem"
ln -s "generations/$generation" "$tls_root/current"
cat >"$test_root/endpoint.env" <<'ENV'
HELIUM_SYNC_LISTEN=100.100.105.47:44719
HELIUM_SYNC_TLS_HOSTNAME=lm.tail0168aa.ts.net
HELIUM_SYNC_TLS_IP=100.100.105.47
ENV

operator_env=(
  PATH="$test_root/bin:$PATH"
  HELIUM_SYNC_CLI="$test_root/bin/helium-sync"
  HELIUM_SYNC_TLS_ROOT="$tls_root"
  HELIUM_SYNC_ENDPOINT_ENV="$test_root/endpoint.env"
  TAILSCALE_STATUS_FIXTURE="$test_root/tailscale.json"
  SERVE_STATUS_FIXTURE="$test_root/serve-empty.json"
  FUNNEL_STATUS_FIXTURE="$test_root/funnel-empty.json"
)
env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null

cp "$test_root/offline-ca/ca-key.pem" "$tls_root/generations/$generation/ca-key.pem"
chmod 0600 "$tls_root/generations/$generation/ca-key.pem"
if env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a CA private key on lm" >&2
  exit 1
fi
rm "$tls_root/generations/$generation/ca-key.pem"

cp "$test_root/endpoint.env" "$test_root/endpoint.bad"
sed -i 's/100\.100\.105\.47:44719/100.100.105.48:44719/' "$test_root/endpoint.bad"
if env "${operator_env[@]}" HELIUM_SYNC_ENDPOINT_ENV="$test_root/endpoint.bad" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a stale Tailscale address" >&2
  exit 1
fi

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}}}' >"$test_root/serve-configured.json"
if env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/serve-configured.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a parallel Tailscale Serve configuration" >&2
  exit 1
fi

printf '%s\n' '{"AllowFunnel":{"lm.tail0168aa.ts.net:443":true}}' \
  >"$test_root/funnel-on.json"
if env "${operator_env[@]}" FUNNEL_STATUS_FIXTURE="$test_root/funnel-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted public Funnel exposure" >&2
  exit 1
fi

unit="$repo_root/systemd/helium-syncd.service"
for directive in \
  'User=helium-sync' \
  'EnvironmentFile=/etc/helium-sync/endpoint.env' \
  'NoNewPrivileges=yes' \
  'ProtectSystem=strict' \
  'ProtectHome=yes' \
  'ProtectProc=invisible' \
  'IPAddressDeny=any' \
  'IPAddressAllow=100.64.0.0/10' \
  'CapabilityBoundingSet=' \
  'ReadOnlyPaths=/etc/helium-sync' \
  'MemoryMax=256M' \
  'MemorySwapMax=0' \
  'TasksMax=64'; do
  grep -Fqx "$directive" "$unit"
done
grep -Fq 'ExecStartPre=/usr/local/libexec/helium-sync tls-server-verify' "$unit"
grep -Fq 'ExecStartPre=/usr/bin/test ! -e /etc/helium-sync/tls/current/ca-key.pem' "$unit"
grep -Fq -- '-tls-cert-file /etc/helium-sync/tls/current/server-cert.pem' "$unit"
grep -Fq -- '-listen ${HELIUM_SYNC_LISTEN}' "$unit"
if grep -Fq 'IPAddressAllow=localhost' "$unit"; then
  echo "direct TLS service still permits only the obsolete loopback proxy path" >&2
  exit 1
fi
if grep -Fq 'tailscale serve --bg' "$repo_root/scripts/install-lm-sync-service.sh"; then
  echo "operator still attempts external Tailscale Serve configuration" >&2
  exit 1
fi
grep -Fq 'perform_backup_drill >/dev/null' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'perform_registry_update server-enroll' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'perform_registry_update server-revoke' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'exec 8>/run/helium-sync-operator.lock' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'install-source|install-endpoint|initialize|backup-drill|enroll-device|revoke-device|enable|disable)' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq -- "--noproxy '*' --tlsv1.3 --tls-max 1.3" \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'port $tls_port already has a listener' \
  "$repo_root/scripts/install-lm-sync-service.sh"

backup_unit="$repo_root/systemd/helium-sync-server-backup.service"
for directive in \
  'NoNewPrivileges=yes' \
  'ProtectSystem=strict' \
  'ProtectHome=yes' \
  'ReadOnlyPaths=/var/lib/helium-sync' \
  'ReadWritePaths=/srv/nas/helium-sync-server' \
  'RestrictAddressFamilies=AF_UNIX' \
  'IPAddressDeny=any' \
  'CapabilityBoundingSet=' \
  'MemorySwapMax=0'; do
  grep -Fqx "$directive" "$backup_unit"
done
if grep -Fq '[ -s /srv/nas/helium-sync-server/last-restore-drill.env ]' \
  "$repo_root/scripts/install-lm-sync-service.sh"; then
  echo "activation still trusts a stale or unrelated restore receipt" >&2
  exit 1
fi

echo "lm_sync_operator=passed"
