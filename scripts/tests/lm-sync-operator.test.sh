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
cat >"$test_root/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  is-active) exit 3 ;;
  daemon-reload) exit 0 ;;
  *) echo "unexpected systemctl invocation: $*" >&2; exit 2 ;;
esac
MOCK
chmod 0755 "$test_root/bin/systemctl"
cat >"$test_root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${CURL_LOG:?}"
printf '%s\n' "${CURL_RESPONSE:?}"
MOCK
chmod 0755 "$test_root/bin/curl"

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

if "$test_root/bin/helium-sync" tls-ca-init \
  --hostname lm.tail0168aa.ts.net --ip 100.100.105.47 \
  --output-dir "$test_root/legacy-ip-ca" >/dev/null 2>&1; then
  echo "tls-ca-init retained the Android-incompatible IP-constraint interface" >&2
  exit 1
fi
"$test_root/bin/helium-sync" tls-ca-init \
  --hostname lm.tail0168aa.ts.net \
  --output-dir "$test_root/offline-ca" >/dev/null
"$test_root/bin/helium-sync" tls-server-issue \
  --ca-cert "$test_root/offline-ca/ca-cert.pem" \
  --ca-key "$test_root/offline-ca/ca-key.pem" \
  --hostname lm.tail0168aa.ts.net --ip 100.100.105.47 \
  --output-dir "$test_root/issued-server" >/dev/null

release_root="$test_root/releases"
unit_root="$test_root/units"
stage="$test_root/release-stage"
mkdir -p "$stage" "$unit_root"
cp "$test_root/bin/helium-sync" "$stage/helium-sync"
cp "$test_root/bin/helium-sync" "$stage/helium-syncd"
go version -m "$stage/helium-sync" >"$stage/helium-sync.buildinfo"
go version -m "$stage/helium-syncd" >"$stage/helium-syncd.buildinfo"
cp "$repo_root/scripts/helium-sync-endpoint-health.sh" "$stage/helium-sync-endpoint-health"
cp "$repo_root/scripts/helium-sync-server-backup.sh" "$stage/helium-sync-server-backup"
cp "$repo_root/scripts/helium-sync-server-backup-control.sh" "$stage/helium-sync-server-backup-control"
cp "$repo_root/sysusers.d/helium-sync.conf" "$stage/helium-sync.conf"
for source_unit in helium-syncd.service helium-sync-server-backup.service \
  helium-sync-server-backup-archive.service helium-sync-server-backup.timer; do
  cp "$repo_root/systemd/$source_unit" "$stage/$source_unit"
done
hash() { sha256sum "$1" | awk '{print $1}'; }
cat >"$stage/source.env" <<EOF
schema_version=1
source_commit=1111111111111111111111111111111111111111
source_tree=2222222222222222222222222222222222222222
public_backbone_commit=3333333333333333333333333333333333333333
go_version=$(go version)
module_identity_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
build_command=go build -trimpath ./cmd/helium-sync ./cmd/helium-syncd
build_target=linux/amd64
built_at=2026-07-22T00:00:00-07:00
helium_sync_sha256=$(hash "$stage/helium-sync")
helium_sync_buildinfo_sha256=$(hash "$stage/helium-sync.buildinfo")
helium_syncd_sha256=$(hash "$stage/helium-syncd")
helium_syncd_buildinfo_sha256=$(hash "$stage/helium-syncd.buildinfo")
endpoint_health_sha256=$(hash "$stage/helium-sync-endpoint-health")
backup_sha256=$(hash "$stage/helium-sync-server-backup")
backup_control_sha256=$(hash "$stage/helium-sync-server-backup-control")
sysusers_sha256=$(hash "$stage/helium-sync.conf")
sync_unit_sha256=$(hash "$stage/helium-syncd.service")
backup_unit_sha256=$(hash "$stage/helium-sync-server-backup.service")
archive_unit_sha256=$(hash "$stage/helium-sync-server-backup-archive.service")
backup_timer_sha256=$(hash "$stage/helium-sync-server-backup.timer")
EOF
source_generation=$(hash "$stage/source.env")
mkdir -p "$release_root/generations"
mv "$stage" "$release_root/generations/$source_generation"
ln -s "generations/$source_generation" "$release_root/current"
for source_unit in helium-syncd.service helium-sync-server-backup.service \
  helium-sync-server-backup-archive.service helium-sync-server-backup.timer; do
  ln -s "$release_root/current/$source_unit" "$unit_root/$source_unit"
done

tls_root="$test_root/installed-tls"
generation=$(sha256sum "$test_root/issued-server/server-cert.pem" | awk '{print $1}')
mkdir -p "$tls_root/generations/$generation"
cp "$test_root/offline-ca/ca-cert.pem" "$tls_root/generations/$generation/ca-cert.pem"
cp "$test_root/issued-server/server-cert.pem" "$tls_root/generations/$generation/server-cert.pem"
cp "$test_root/issued-server/server-key.pem" "$tls_root/generations/$generation/server-key.pem"
chmod 0600 "$tls_root/generations/$generation/server-key.pem"
cat >"$tls_root/generations/$generation/endpoint.env" <<'ENV'
HELIUM_SYNC_LISTEN=100.100.105.47:44719
HELIUM_SYNC_TLS_HOSTNAME=lm.tail0168aa.ts.net
HELIUM_SYNC_TLS_IP=100.100.105.47
ENV
cat >"$tls_root/generations/$generation/generation.env" <<EOF
schema_version=1
generation=$generation
hostname=lm.tail0168aa.ts.net
ip=100.100.105.47
listen=100.100.105.47:44719
source_generation=$source_generation
helium_sync_sha256=$(hash "$release_root/current/helium-sync")
ca_cert_sha256=$(hash "$tls_root/generations/$generation/ca-cert.pem")
server_cert_sha256=$(hash "$tls_root/generations/$generation/server-cert.pem")
server_key_sha256=$(hash "$tls_root/generations/$generation/server-key.pem")
endpoint_env_sha256=$(hash "$tls_root/generations/$generation/endpoint.env")
installed_at=2026-07-22T00:00:00-07:00
EOF
ln -s "generations/$generation" "$tls_root/current"

operator_env=(
  PATH="$test_root/bin:$PATH"
  HELIUM_SYNC_CLI="$release_root/current/helium-sync"
  HELIUM_SYNC_RELEASE_ROOT="$release_root"
  HELIUM_SYNC_UNIT_ROOT="$unit_root"
  HELIUM_SYNC_TLS_ROOT="$tls_root"
  HELIUM_SYNC_OPERATOR_LOCK="$test_root/operator.lock"
  TAILSCALE_STATUS_FIXTURE="$test_root/tailscale.json"
  SERVE_STATUS_FIXTURE="$test_root/serve-empty.json"
  FUNNEL_STATUS_FIXTURE="$test_root/funnel-empty.json"
)
run_operator() {
  unshare -Ur env "${operator_env[@]}" \
    "$repo_root/scripts/install-lm-sync-service.sh" "$@"
}
run_operator verify-endpoint >/dev/null
cp "$release_root/current/helium-sync-endpoint-health" "$test_root/health.good"
printf 'tamper\n' >>"$release_root/current/helium-sync-endpoint-health"
if run_operator verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a modified source generation" >&2
  exit 1
fi
cp "$test_root/health.good" "$release_root/current/helium-sync-endpoint-health"
env PATH="$test_root/bin:$PATH" HELIUM_SYNC_TLS_ROOT="$tls_root" \
  HELIUM_SYNC_LISTEN=100.100.105.47:44719 \
  HELIUM_SYNC_TLS_HOSTNAME=lm.tail0168aa.ts.net \
  HELIUM_SYNC_TLS_IP=100.100.105.47 CURL_LOG="$test_root/curl.log" \
  CURL_RESPONSE='{"ok":true}' \
  "$repo_root/scripts/helium-sync-endpoint-health.sh"
grep -Fq -- '--noproxy * --tlsv1.3 --tls-max 1.3' "$test_root/curl.log"
grep -Fq -- '--resolve lm.tail0168aa.ts.net:44719:100.100.105.47' \
  "$test_root/curl.log"

# Both rollback commands switch one generation symlink and preserve all old
# generation bytes. A user namespace supplies EUID 0 without touching lm.
cp -a "$release_root/generations/$source_generation" "$test_root/source-2"
sed -i 's/built_at=.*/built_at=2026-07-22T00:00:01-07:00/' \
  "$test_root/source-2/source.env"
source_generation_2=$(hash "$test_root/source-2/source.env")
mv "$test_root/source-2" "$release_root/generations/$source_generation_2"
unshare -Ur env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" rollback-source \
  "$source_generation_2" >/dev/null
[[ $(readlink "$release_root/current") == "generations/$source_generation_2" ]]
unshare -Ur env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" rollback-source \
  "$source_generation" >/dev/null
[[ -d "$release_root/generations/$source_generation_2" ]]

generation_2=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cp -a "$tls_root/generations/$generation" "$tls_root/generations/$generation_2"
sed -i "s/^generation=.*/generation=$generation_2/" \
  "$tls_root/generations/$generation_2/generation.env"
unshare -Ur env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" rollback-endpoint \
  "$generation_2" >/dev/null
[[ $(readlink "$tls_root/current") == "generations/$generation_2" ]]
unshare -Ur env "${operator_env[@]}" \
  "$repo_root/scripts/install-lm-sync-service.sh" rollback-endpoint \
  "$generation" >/dev/null
[[ -d "$tls_root/generations/$generation_2" ]]

cp "$test_root/offline-ca/ca-key.pem" "$tls_root/generations/$generation/ca-key.pem"
chmod 0600 "$tls_root/generations/$generation/ca-key.pem"
if run_operator verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a CA private key on lm" >&2
  exit 1
fi
rm "$tls_root/generations/$generation/ca-key.pem"

cp "$tls_root/current/endpoint.env" "$test_root/endpoint.good"
sed -i 's/100\.100\.105\.47:44719/100.100.105.48:44719/' \
  "$tls_root/current/endpoint.env"
if run_operator verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a stale Tailscale address" >&2
  exit 1
fi
cp "$test_root/endpoint.good" "$tls_root/current/endpoint.env"

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}}}' >"$test_root/serve-configured.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/serve-configured.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a parallel Tailscale Serve configuration" >&2
  exit 1
fi

printf '%s\n' '{"AllowFunnel":{"lm.tail0168aa.ts.net:443":true}}' \
  >"$test_root/funnel-on.json"
if unshare -Ur env "${operator_env[@]}" FUNNEL_STATUS_FIXTURE="$test_root/funnel-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted public Funnel exposure" >&2
  exit 1
fi

unit="$repo_root/systemd/helium-syncd.service"
grep -Fq 'mktemp -d /var/tmp/helium-sync-release.XXXXXX' \
  "$repo_root/scripts/install-lm-sync-service.sh"
for directive in \
  'User=helium-sync' \
  'EnvironmentFile=/etc/helium-sync/tls/current/endpoint.env' \
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
grep -Fq 'ExecStartPre=/usr/local/libexec/helium-sync-releases/current/helium-sync tls-server-verify' "$unit"
grep -Fq 'ExecStartPost=/usr/local/libexec/helium-sync-releases/current/helium-sync-endpoint-health' "$unit"
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
grep -Fq 'exec 8>"$operator_lock"' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'install-source|rollback-source|install-endpoint|rollback-endpoint|initialize|backup-drill|enroll-device|revoke-device|verify-endpoint|verify-live-endpoint|enable|disable|status)' \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq -- "--noproxy '*' --tlsv1.3 --tls-max 1.3" \
  "$repo_root/scripts/install-lm-sync-service.sh"
grep -Fq 'port $tls_port already has a listener' \
  "$repo_root/scripts/install-lm-sync-service.sh"

backup_unit="$repo_root/systemd/helium-sync-server-backup-archive.service"
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
controller_unit="$repo_root/systemd/helium-sync-server-backup.service"
for directive in \
  'InaccessiblePaths=/var/lib/helium-sync /srv/nas' \
  'RestrictAddressFamilies=AF_UNIX' \
  'CapabilityBoundingSet=' \
  'MemoryMax=64M' \
  'TimeoutStartSec=20min'; do
  grep -Fqx "$directive" "$controller_unit"
done
if grep -Fq 'ConditionPath' "$controller_unit" || grep -Fq 'ConditionPath' "$backup_unit"; then
  echo "backup units still permit a clean condition skip" >&2
  exit 1
fi
if grep -Fq '[ -s /srv/nas/helium-sync-server/last-restore-drill.env ]' \
  "$repo_root/scripts/install-lm-sync-service.sh"; then
  echo "activation still trusts a stale or unrelated restore receipt" >&2
  exit 1
fi

echo "lm_sync_operator=passed"
