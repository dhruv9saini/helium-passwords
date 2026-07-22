#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-lm-operator.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

mkdir -p "$test_root/bin"
cat >"$test_root/bin/tailscale" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2 $3" in
  "serve status --json") cat "${SERVE_STATUS_FIXTURE:?}" ;;
  "funnel status --json") cat "${FUNNEL_STATUS_FIXTURE:?}" ;;
  *) echo "unexpected tailscale invocation: $*" >&2; exit 2 ;;
esac
MOCK
chmod 0755 "$test_root/bin/tailscale"

cat >"$test_root/serve-good.json" <<'JSON'
{
  "TCP": {"443": {"HTTPS": true}},
  "Web": {
    "lm.example.ts.net:443": {
      "Handlers": {"/": {"Proxy": "http://127.0.0.1:44719"}}
    }
  }
}
JSON
printf '{}\n' >"$test_root/funnel-off.json"

PATH="$test_root/bin:$PATH" \
SERVE_STATUS_FIXTURE="$test_root/serve-good.json" \
FUNNEL_STATUS_FIXTURE="$test_root/funnel-off.json" \
  "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint >/dev/null

sed 's#127.0.0.1:44719#0.0.0.0:44719#' \
  "$test_root/serve-good.json" >"$test_root/serve-bad.json"
if PATH="$test_root/bin:$PATH" \
  SERVE_STATUS_FIXTURE="$test_root/serve-bad.json" \
  FUNNEL_STATUS_FIXTURE="$test_root/funnel-off.json" \
    "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint \
      >/dev/null 2>&1; then
  echo "endpoint gate accepted a non-loopback backend" >&2
  exit 1
fi

printf '%s\n' '{"AllowFunnel":{"lm.example.ts.net:443":true}}' \
  >"$test_root/funnel-on.json"
if PATH="$test_root/bin:$PATH" \
  SERVE_STATUS_FIXTURE="$test_root/serve-good.json" \
  FUNNEL_STATUS_FIXTURE="$test_root/funnel-on.json" \
    "$repo_root/scripts/install-lm-sync-service.sh" verify-endpoint \
      >/dev/null 2>&1; then
  echo "endpoint gate accepted public Funnel exposure" >&2
  exit 1
fi

unit="$repo_root/systemd/helium-syncd.service"
for directive in \
  'User=helium-sync' \
  'NoNewPrivileges=yes' \
  'ProtectSystem=strict' \
  'ProtectHome=yes' \
  'ProtectProc=invisible' \
  'IPAddressDeny=any' \
  'IPAddressAllow=localhost' \
  'CapabilityBoundingSet=' \
  'MemoryMax=256M' \
  'TasksMax=64'; do
  grep -Fqx "$directive" "$unit"
done

echo "lm_sync_operator=passed"
