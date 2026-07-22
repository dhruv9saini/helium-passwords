#!/usr/bin/env bash
set -euo pipefail

tls_root=${HELIUM_SYNC_TLS_ROOT:-/etc/helium-sync/tls}
tls_port=44719

: "${HELIUM_SYNC_LISTEN:?HELIUM_SYNC_LISTEN is required}"
: "${HELIUM_SYNC_TLS_HOSTNAME:?HELIUM_SYNC_TLS_HOSTNAME is required}"
: "${HELIUM_SYNC_TLS_IP:?HELIUM_SYNC_TLS_IP is required}"
[[ "$HELIUM_SYNC_LISTEN" == "$HELIUM_SYNC_TLS_IP:$tls_port" ]] || {
  echo "Helium Sync endpoint identity is inconsistent" >&2
  exit 1
}
[[ -f "$tls_root/current/ca-cert.pem" &&
   ! -L "$tls_root/current/ca-cert.pem" ]] || {
  echo "Helium Sync CA certificate is unavailable" >&2
  exit 1
}

response=$(curl --fail --silent --show-error --max-time 10 \
  --noproxy '*' --tlsv1.3 --tls-max 1.3 \
  --cacert "$tls_root/current/ca-cert.pem" \
  --resolve "$HELIUM_SYNC_TLS_HOSTNAME:$tls_port:$HELIUM_SYNC_TLS_IP" \
  "https://$HELIUM_SYNC_TLS_HOSTNAME:$tls_port/v2/health")
jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
  echo "Helium Sync direct TLS health response is invalid" >&2
  exit 1
}
