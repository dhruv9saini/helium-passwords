#!/usr/bin/env bash
set -euo pipefail

: "${HELIUM_SYNC_LISTEN:?HELIUM_SYNC_LISTEN is required}"
IFS=.: read -r first second third fourth port extra <<<"$HELIUM_SYNC_LISTEN"
[[ -z "$extra" && "$first" == 100 && "$second" =~ ^[0-9]+$ &&
   "$second" -ge 64 && "$second" -le 127 &&
   "$third" =~ ^[0-9]+$ && "$third" -le 255 &&
   "$fourth" =~ ^[0-9]+$ && "$fourth" -le 255 &&
   "$port" == 44719 ]] || {
  echo "Helium Sync must listen on lm's Tailnet IPv4 port 44719" >&2
  exit 1
}

response=$(curl --fail --silent --show-error --max-time 10 \
  --noproxy '*' "http://$HELIUM_SYNC_LISTEN/v2/health")
jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
  echo "Helium Sync private Tailnet health response is invalid" >&2
  exit 1
}
