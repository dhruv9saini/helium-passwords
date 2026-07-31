#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-enrollment-cli.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

go build -trimpath -o "$test_root/helium-sync" "$repo_root/cmd/helium-sync"

"$test_root/helium-sync" seed-init \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null

jq -e '.version == 2 and .device_id == "d" and .role == "seed" and
  .phase == "active" and .revisions == {} and .sequence == "0"' \
  "$test_root/d/client.json" >/dev/null
jq -e '.device_id == "d" and
  (.token_sha256 | test("^[0-9a-f]{64}$")) and
  (has("token") | not)' "$test_root/relay/bootstrap.json" >/dev/null

"$test_root/helium-sync" server-init \
  --data-dir "$test_root/server" \
  --devices-file "$test_root/server/devices.json" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null

"$test_root/helium-sync" join-init \
  --device da \
  --state-file "$test_root/da/client.json" \
  --auth-request-file "$test_root/relay/da-auth.json" \
  --token-file "$test_root/da/token" >/dev/null
"$test_root/helium-sync" server-enroll \
  --devices-file "$test_root/server/devices.json" \
  --auth-request-file "$test_root/relay/da-auth.json" >/dev/null

jq -e '.version == 2 and .device_id == "da" and .role == "join" and
  .phase == "pending" and .revisions == {} and .sequence == "0"' \
  "$test_root/da/client.json" >/dev/null
jq -e '.devices | any(.id == "da" and .phase == "pending" and
  .scopes == ["pull"] and
  (.token_hashes | length == 1) and
  (.token_hashes[0] | length == 64))' \
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

for obsolete in recovery-keygen recovery-export seed-public seed-wrap; do
  if "$test_root/helium-sync" "$obsolete" >/dev/null 2>&1; then
    echo "obsolete trust-policy command remained available: $obsolete" >&2
    exit 1
  fi
done

echo "enrollment_cli=passed"
