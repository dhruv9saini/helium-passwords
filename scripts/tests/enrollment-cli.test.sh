#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-enrollment-cli.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

go build -trimpath -o "$test_root/helium-sync" "$repo_root/cmd/helium-sync"

"$test_root/helium-sync" seed-init \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null
"$test_root/helium-sync" seed-public \
  --state-file "$test_root/d/client.json" \
  --output "$test_root/relay/seed-public" >/dev/null

jq -e '.device_id == "d" and (.active_key_id | length > 0) and
  (.token_sha256 | test("^[0-9a-f]{64}$")) and
  (has("keys") | not) and (has("token") | not)' \
  "$test_root/relay/bootstrap.json" >/dev/null

"$test_root/helium-sync" server-init \
  --data-dir "$test_root/server" \
  --devices-file "$test_root/server/devices.json" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null

"$test_root/helium-sync" join-request \
  --device da \
  --seed-public-file "$test_root/relay/seed-public" \
  --pending-file "$test_root/da/join.pending.json" \
  --request-file "$test_root/relay/da-join.json" \
  --auth-request-file "$test_root/relay/da-auth.json" \
  --token-file "$test_root/da/token" >/dev/null
"$test_root/helium-sync" seed-wrap \
  --state-file "$test_root/d/client.json" \
  --request-file "$test_root/relay/da-join.json" \
  --wrapped-file "$test_root/relay/da-wrapped.json"
"$test_root/helium-sync" server-enroll \
  --devices-file "$test_root/server/devices.json" \
  --auth-request-file "$test_root/relay/da-auth.json"

active_key=$(jq -er .active_key_id "$test_root/relay/bootstrap.json")
"$test_root/helium-sync" join-install \
  --state-file "$test_root/da/client.json" \
  --pending-file "$test_root/da/join.pending.json" \
  --wrapped-file "$test_root/relay/da-wrapped.json" \
  --required-key-id "$active_key" >/dev/null

jq -e '.device_id == "da" and .role == "join" and .phase == "pending" and
  (.local_seal_key | length > 0)' "$test_root/da/client.json" >/dev/null
jq -e '.devices | any(.id == "da" and .phase == "pending" and
  .scopes == ["pull"] and (.token_sha256 | length == 1))' \
  "$test_root/server/devices.json" >/dev/null

if grep -Fq -- "$(tr -d '\n' <"$test_root/da/token")" \
  "$test_root/server/devices.json"; then
  echo "server registry contains the plaintext device token" >&2
  exit 1
fi

if "$test_root/helium-sync" seed-init \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null 2>&1; then
  echo "seed-init replaced existing material" >&2
  exit 1
fi

echo "enrollment_cli=passed"
