#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-lm-operator.XXXXXX")
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
    "TailscaleIPs": ["100.100.105.47", "fd7a:115c:a1e0::d001:6983"],
    "Online": true
  }
}
JSON
cat >"$test_root/serve-file-browser.json" <<'JSON'
{
  "TCP": {"8080": {"HTTP": true}},
  "Web": {
    "lm.tail0168aa.ts.net:8080": {
      "Handlers": {"/": {"Proxy": "http://127.0.0.1:8080"}}
    }
  }
}
JSON

release_root="$test_root/releases"
unit_root="$test_root/units"
config_root="$test_root/config"
stage="$test_root/release-stage"
mkdir -p "$stage" "$unit_root" "$config_root"
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
built_at=2026-07-25T00:00:00-07:00
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
printf 'HELIUM_SYNC_LISTEN=100.100.105.47:44719\n' >"$config_root/endpoint.env"

operator_env=(
  PATH="$test_root/bin:$PATH"
  HELIUM_SYNC_CLI="$release_root/current/helium-sync"
  HELIUM_SYNC_RELEASE_ROOT="$release_root"
  HELIUM_SYNC_UNIT_ROOT="$unit_root"
  HELIUM_SYNC_CONFIG_ROOT="$config_root"
  HELIUM_SYNC_OPERATOR_LOCK="$test_root/operator.lock"
  TAILSCALE_STATUS_FIXTURE="$test_root/tailscale.json"
  SERVE_STATUS_FIXTURE="$test_root/serve-file-browser.json"
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

env PATH="$test_root/bin:$PATH" \
  HELIUM_SYNC_LISTEN=100.100.105.47:44719 \
  CURL_LOG="$test_root/curl.log" CURL_RESPONSE='{"ok":true}' \
  "$repo_root/scripts/helium-sync-endpoint-health.sh"
grep -Fq -- '--noproxy * http://100.100.105.47:44719/v2/health' \
  "$test_root/curl.log"

cp -a "$release_root/generations/$source_generation" "$test_root/source-2"
sed -i 's/built_at=.*/built_at=2026-07-25T00:00:01-07:00/' \
  "$test_root/source-2/source.env"
source_generation_2=$(hash "$test_root/source-2/source.env")
mv "$test_root/source-2" "$release_root/generations/$source_generation_2"
run_operator rollback-source "$source_generation_2" >/dev/null
[[ $(readlink "$release_root/current") == "generations/$source_generation_2" ]]
run_operator rollback-source "$source_generation" >/dev/null
[[ -d "$release_root/generations/$source_generation_2" ]]

cp "$config_root/endpoint.env" "$test_root/endpoint.good"
printf 'HELIUM_SYNC_LISTEN=100.100.105.48:44719\n' >"$config_root/endpoint.env"
if run_operator verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a stale Tailscale address" >&2
  exit 1
fi
cp "$test_root/endpoint.good" "$config_root/endpoint.env"

printf '%s\n' '{"AllowFunnel":{"lm:443":true}}' >"$test_root/funnel-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/funnel-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted public Funnel exposure" >&2
  exit 1
fi

printf '%s\n' '{"TCP":{"44719":{"HTTP":true}}}' >"$test_root/sync-serve-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/sync-serve-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a Tailscale Serve listener on the Sync port" >&2
  exit 1
fi

printf '%s\n' \
  '{"TCP":{"8081":{"HTTP":true}},"Web":{"lm:8081":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:44719"}}}}}' \
  >"$test_root/sync-web-proxy-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/sync-web-proxy-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted an alternate-port Web proxy to the Sync port" >&2
  exit 1
fi

printf '%s\n' \
  '{"TCP":{"8081":{"HTTP":true}},"Web":{"lm:8081":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:044719"}}}}}' \
  >"$test_root/sync-web-proxy-leading-zero-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/sync-web-proxy-leading-zero-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a leading-zero Web proxy target to the Sync port" >&2
  exit 1
fi

printf '%s\n' \
  '{"TCP":{"8082":{"TCPForward":"100.100.105.47:44719"}}}' \
  >"$test_root/sync-tcp-forward-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/sync-tcp-forward-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted an alternate-port TCP forward to the Sync port" >&2
  exit 1
fi

printf '%s\n' \
  '{"TCP":{"8082":{"TCPForward":"100.100.105.47:044719"}}}' \
  >"$test_root/sync-tcp-forward-leading-zero-on.json"
if unshare -Ur env "${operator_env[@]}" SERVE_STATUS_FIXTURE="$test_root/sync-tcp-forward-leading-zero-on.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a leading-zero TCP forward target to the Sync port" >&2
  exit 1
fi

for invalid_container in Foreground Services; do
  printf '{"%s":[]}\n' "$invalid_container" \
    >"$test_root/invalid-$invalid_container-container.json"
  if unshare -Ur env "${operator_env[@]}" \
    SERVE_STATUS_FIXTURE="$test_root/invalid-$invalid_container-container.json" \
    "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
    echo "endpoint gate accepted a non-object $invalid_container container" >&2
    exit 1
  fi
done

for null_child_container in Foreground Services; do
  printf '{"%s":{"child":null}}\n' "$null_child_container" \
    >"$test_root/null-$null_child_container-child.json"
  if unshare -Ur env "${operator_env[@]}" \
    SERVE_STATUS_FIXTURE="$test_root/null-$null_child_container-child.json" \
    "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
    echo "endpoint gate accepted a null $null_child_container child config" >&2
    exit 1
  fi
done

printf '%s\n' '{"Services":{"svc":{"Services":{"nested":"invalid"}}}}' \
  >"$test_root/non-object-descended-service.json"
if unshare -Ur env "${operator_env[@]}" \
  SERVE_STATUS_FIXTURE="$test_root/non-object-descended-service.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null 2>&1; then
  echo "endpoint gate accepted a non-object descended Services config" >&2
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
  'ReadOnlyPaths=/etc/helium-sync/endpoint.env' \
  'MemoryMax=256M' \
  'MemorySwapMax=0' \
  'TasksMax=64'; do
  grep -Fqx "$directive" "$unit"
done
grep -Fq 'ExecStartPost=/usr/local/libexec/helium-sync-releases/current/helium-sync-endpoint-health' "$unit"
grep -Fq -- '-listen ${HELIUM_SYNC_LISTEN}' "$unit"
if grep -Eqi 'tls|https|ciphertext|ca-cert' "$unit"; then
  echo "production unit retained an inner encryption layer" >&2
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
if grep -Eqi 'tls|https|ciphertext|age1|recovery recipient' \
  "$repo_root/scripts/install-lm-sync-service.sh"; then
  echo "production operator retained obsolete trust-policy machinery" >&2
  exit 1
fi

echo "lm_sync_operator=passed"
