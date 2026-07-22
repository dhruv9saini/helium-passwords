#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-central-service.XXXXXX)
restore_root=/tmp/helium-sync-restore.central-$$
daemon_pid=

stop_daemon() {
  if [[ -n "$daemon_pid" ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
  fi
}

cleanup() {
  stop_daemon
  [[ ! -e "$restore_root" ]] || find "$restore_root" -depth -delete
  find "$test_root" -depth -delete
}
trap cleanup EXIT INT TERM

mkdir -p "$test_root/bin" "$test_root/relay"
go build -trimpath -o "$test_root/bin/helium-sync" "$repo_root/cmd/helium-sync"
go build -trimpath -o "$test_root/bin/helium-syncd" "$repo_root/cmd/helium-syncd"

"$test_root/bin/helium-sync" seed-init \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null
"$test_root/bin/helium-sync" seed-public \
  --state-file "$test_root/d/client.json" \
  --output "$test_root/relay/seed-public" >/dev/null

# Recovery identities and plaintext seed state stay outside the server and its
# opaque backup. Both independent synthetic identities must restore the same
# authenticated d trust anchor.
"$test_root/bin/helium-sync" recovery-keygen \
  --output-dir "$test_root/recovery-a" >/dev/null
"$test_root/bin/helium-sync" recovery-keygen \
  --output-dir "$test_root/recovery-b" >/dev/null
cat "$test_root/recovery-a/recipient.txt" \
  "$test_root/recovery-b/recipient.txt" \
  >"$test_root/d/recovery-recipients.txt"
"$test_root/bin/helium-sync" recovery-export \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --recipients-file "$test_root/d/recovery-recipients.txt" \
  --output "$test_root/relay/d-recovery.age" >/dev/null
for recovery in a b; do
  "$test_root/bin/helium-sync" recovery-import \
    --input "$test_root/relay/d-recovery.age" \
    --identity-file "$test_root/recovery-$recovery/identity.txt" \
    --expected-seed-public-file "$test_root/relay/seed-public" \
    --output-dir "$test_root/restored-d-$recovery" >/dev/null
  cmp "$test_root/d/token" "$test_root/restored-d-$recovery/token"
done

"$test_root/bin/helium-sync" server-init \
  --data-dir "$test_root/server" \
  --devices-file "$test_root/server/devices.json" \
  --bootstrap-file "$test_root/relay/bootstrap.json" >/dev/null

pick_port() {
  local candidate
  for _ in {1..64}; do
    candidate=$(shuf -i 20000-45000 -n 1)
    if ! ss -ltnH "( sport = :$candidate )" | grep -q .; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "could not reserve a synthetic loopback port" >&2
  return 1
}
port=$(pick_port)
base_url=http://127.0.0.1:$port

start_daemon() {
  local server_dir=$1
  "$test_root/bin/helium-syncd" \
    -listen "127.0.0.1:$port" \
    -data-dir "$server_dir" \
    -devices-file "$server_dir/devices.json" \
    >"$test_root/daemon.log" 2>&1 &
  daemon_pid=$!
  for _ in {1..50}; do
    if curl --noproxy '*' --fail --silent --max-time 1 \
      "$base_url/v2/health" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      cat "$test_root/daemon.log" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "synthetic daemon did not become healthy" >&2
  return 1
}

printf '%s\n' '{"proof":"restore-only-plaintext"}' >"$test_root/payload.json"
start_daemon "$test_root/server"
"$test_root/bin/helium-sync" push \
  --url "$base_url" \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --kind passwords --key synthetic/server-restore \
  --payload-file "$test_root/payload.json" >/dev/null
stop_daemon

if grep -aFq restore-only-plaintext "$test_root/server/records.jsonl"; then
  echo "server journal contains synthetic plaintext" >&2
  exit 1
fi

backup_output=$(HELIUM_SERVER_DATA_DIR="$test_root/server" \
  HELIUM_SERVER_SERVICE=none HELIUM_SYNC_CLI="$test_root/bin/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" \
  backup "$test_root/server-backup")
archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$backup_output")
HELIUM_SERVER_DATA_DIR="$test_root/server" HELIUM_SERVER_SERVICE=none \
  HELIUM_SYNC_CLI="$test_root/bin/helium-sync" \
  "$repo_root/scripts/helium-sync-server-backup.sh" \
  restore-drill "$archive" "$restore_root" >/dev/null
restored_server=$restore_root/server

for forbidden in client.json token identity.txt recovery-recipients.txt; do
  if tar --zstd -tf "$archive" | grep -Eq "(^|/)$forbidden$"; then
    echo "opaque server backup contains client recovery material: $forbidden" >&2
    exit 1
  fi
done
if grep -aFq restore-only-plaintext "$restored_server/records.jsonl"; then
  echo "restored server journal contains synthetic plaintext" >&2
  exit 1
fi

start_daemon "$restored_server"
"$test_root/bin/helium-sync" latest \
  --url "$base_url" \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --kind passwords >"$test_root/restored-latest.json"
jq -e '.Records | length == 1 and
  .[0].Key == "synthetic/server-restore" and
  .[0].Payload.proof == "restore-only-plaintext"' \
  "$test_root/restored-latest.json" >/dev/null
stop_daemon

# A join receives its own credential and wrapped E2EE state. The server sees
# only the credential hash, admits it pull-only, and revocation affects exactly
# that identity.
"$test_root/bin/helium-sync" join-request \
  --device da \
  --seed-public-file "$test_root/relay/seed-public" \
  --pending-file "$test_root/da/join.pending.json" \
  --request-file "$test_root/relay/da-join.json" \
  --auth-request-file "$test_root/relay/da-auth.json" \
  --token-file "$test_root/da/token" >/dev/null
"$test_root/bin/helium-sync" seed-wrap \
  --state-file "$test_root/d/client.json" \
  --request-file "$test_root/relay/da-join.json" \
  --wrapped-file "$test_root/relay/da-wrapped.json" >/dev/null
"$test_root/bin/helium-sync" server-enroll \
  --devices-file "$restored_server/devices.json" \
  --auth-request-file "$test_root/relay/da-auth.json" >/dev/null
active_key=$(jq -er .active_key_id "$test_root/relay/bootstrap.json")
"$test_root/bin/helium-sync" join-install \
  --state-file "$test_root/da/client.json" \
  --pending-file "$test_root/da/join.pending.json" \
  --wrapped-file "$test_root/relay/da-wrapped.json" \
  --required-key-id "$active_key" >/dev/null

start_daemon "$restored_server"
"$test_root/bin/helium-sync" latest \
  --url "$base_url" \
  --state-file "$test_root/da/client.json" \
  --token-file "$test_root/da/token" \
  --kind passwords >"$test_root/da-latest.json"
jq -e '.Records[0].Payload.proof == "restore-only-plaintext"' \
  "$test_root/da-latest.json" >/dev/null
journal_before=$(sha256sum "$restored_server/records.jsonl" | awk '{print $1}')
if "$test_root/bin/helium-sync" push \
  --url "$base_url" \
  --state-file "$test_root/da/client.json" \
  --token-file "$test_root/da/token" \
  --kind passwords --key synthetic/blocked \
  --payload-file "$test_root/payload.json" >/dev/null 2>&1; then
  echo "pending join published before verified promotion" >&2
  exit 1
fi
journal_after=$(sha256sum "$restored_server/records.jsonl" | awk '{print $1}')
[[ "$journal_after" == "$journal_before" ]]
stop_daemon

"$test_root/bin/helium-sync" server-revoke \
  --devices-file "$restored_server/devices.json" --device da >/dev/null
start_daemon "$restored_server"
if "$test_root/bin/helium-sync" latest \
  --url "$base_url" \
  --state-file "$test_root/da/client.json" \
  --token-file "$test_root/da/token" \
  --kind passwords >/dev/null 2>&1; then
  echo "revoked synthetic device credential remained usable" >&2
  exit 1
fi
"$test_root/bin/helium-sync" latest \
  --url "$base_url" \
  --state-file "$test_root/d/client.json" \
  --token-file "$test_root/d/token" \
  --kind passwords >/dev/null
stop_daemon

if grep -Fq -- "$(tr -d '\n' <"$test_root/d/token")" \
  "$restored_server/devices.json" ||
   grep -Fq -- "$(tr -d '\n' <"$test_root/da/token")" \
  "$restored_server/devices.json"; then
  echo "server registry contains a plaintext bearer credential" >&2
  exit 1
fi

echo "central_service_readiness=passed"
