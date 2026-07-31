#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "$repo_root/.profile-backup-test.XXXXXX")
cleanup() {
  [[ -z "${holder_pid:-}" ]] || kill "$holder_pid" >/dev/null 2>&1 || true
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/profile/Default/Sessions" "$test_root/bin" \
  "$test_root/nas" "$test_root/peer" "$test_root/restore-root" \
  "$test_root/receipts"
chmod 700 "$test_root/restore-root"
: >"$test_root/restore-root/.helium-disposable-profile-restore-root"
printf 'synthetic-session-state\n' >"$test_root/profile/Default/Sessions/Tabs_fixture"
printf 'synthetic-preferences\n' >"$test_root/profile/Default/Preferences"

cat >"$test_root/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '/synthetic-separate-nas\n'
EOF

cat >"$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -F) [[ "$2" == none ]]; shift 2 ;;
    -o)
      case "$2" in
        GlobalKnownHostsFile=*|UserKnownHostsFile=*)
          [[ "${2#*=}" == "$PROFILE_TEST_SSH_KNOWN_HOSTS" ]]
          ;;
      esac
      shift 2
      ;;
    -i) [[ "$2" == "$PROFILE_TEST_SSH_IDENTITY" ]]; shift 2 ;;
    -l) [[ "$2" == d ]]; shift 2 ;;
    *) echo "unexpected SSH option: $1" >&2; exit 1 ;;
  esac
done
remote_alias=$1
shift
[[ "$remote_alias" == fixture-peer ]]
command_text=$1
if [[ "$command_text" == "uname -n " ]]; then
  printf '%s\n' "${PROFILE_TEST_REMOTE_HOST:-fixture-peer}"
  exit
fi
command_text=${command_text//\/synthetic\/peer-profile-backups/${PROFILE_TEST_PEER_ROOT}}
bash -c "$command_text"
EOF

cat >"$test_root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
[[ "$1" == -e ]]
[[ "$2" == *"-F none"* ]]
[[ "$2" == *"-o BatchMode=yes"* ]]
[[ "$2" == *"-o IdentitiesOnly=yes"* ]]
[[ "$2" == *"-o StrictHostKeyChecking=yes"* ]]
[[ "$2" == *"-o GlobalKnownHostsFile=${PROFILE_TEST_SSH_KNOWN_HOSTS}"* ]]
[[ "$2" == *"-o UserKnownHostsFile=${PROFILE_TEST_SSH_KNOWN_HOSTS}"* ]]
[[ "$2" == *"-i ${PROFILE_TEST_SSH_IDENTITY}"* ]]
count=${#arguments[@]}
source_file=${arguments[count-2]}
target_file=${arguments[count-1]}
if [[ "$source_file" == fixture-peer:* ]]; then
  source_file=${source_file#fixture-peer:}
  source_file=${source_file/\/synthetic\/peer-profile-backups/${PROFILE_TEST_PEER_ROOT}}
else
  [[ "$target_file" == fixture-peer:* ]]
  target_file=${target_file#fixture-peer:}
  target_file=${target_file/\/synthetic\/peer-profile-backups/${PROFILE_TEST_PEER_ROOT}}
fi
cat "$source_file" >"$target_file"
chmod 600 "$target_file"
EOF

chmod 700 "$test_root/bin/findmnt" \
  "$test_root/bin/ssh" "$test_root/bin/rsync"
PATH="$test_root/bin:$PATH"
export PATH

printf 'SYNTHETIC-SSH-PRIVATE-KEY\n' >"$test_root/ssh-identity"
printf 'fixture-peer ssh-ed25519 SYNTHETIC\n' >"$test_root/known-hosts"
chmod 600 "$test_root/ssh-identity" "$test_root/known-hosts"
export PROFILE_TEST_SSH_IDENTITY="$test_root/ssh-identity"
export PROFILE_TEST_SSH_KNOWN_HOSTS="$test_root/known-hosts"
export PROFILE_TEST_PEER_ROOT="$test_root/peer"

local_host=$(uname -n | cut -d. -f1)
config=$test_root/profile-backup.conf
cat >"$config" <<EOF
version=3
source_device=fixture
profile_id=default
source_path=$test_root/profile
ssh_user=d
ssh_identity=$test_root/ssh-identity
ssh_known_hosts=$test_root/known-hosts
retention_keep=2
destination_reserve_bytes=1
destination=nas-copy|nas|local|$local_host|-|$test_root/nas
destination=fixture-peer-copy|device|ssh|fixture-peer|fixture-peer|/synthetic/peer-profile-backups
EOF
chmod 600 "$config"

tool=$repo_root/scripts/profile-backup/helium-profile-backup.sh
# Pipeline assertions must consume complete command output. With pipefail,
# grep -q can close early and turn a successful multi-line producer into 141.
preflight=$("$tool" preflight "$config")
grep -qx 'preflight=ok' <<<"$preflight"
grep -Eq '^topology_sha256=[a-f0-9]{64}$' <<<"$preflight"

empty_config=$test_root/empty-profile-backup.conf
sed 's/profile_id=default/profile_id=empty/' "$config" >"$empty_config"
chmod 600 "$empty_config"
mkdir -p "$test_root/nas/fixture/empty/generations" \
  "$test_root/peer/fixture/empty/generations"
"$tool" retention-apply "$empty_config" |
  grep -x 'retention=unchanged' >/dev/null

generation1=20260722T120000Z-1111111111111111
generation2=20260722T120100Z-2222222222222222
generation3=20260722T120200Z-3333333333333333
generation4=20260722T120300Z-4444444444444444
backup1=$("$tool" backup "$config" "$generation1")
grep -qx 'backup=committed' <<<"$backup1"
grep -qx 'receipt_destination=nas-copy' <<<"$backup1"
"$tool" status "$config" "$generation1" |
  grep -x 'status=healthy' >/dev/null

receipt=$test_root/receipts/$generation1.env
"$tool" receipt-export "$config" nas-copy "$generation1" "$receipt" |
  grep -Fx "receipt_exported=$receipt" >/dev/null
[[ -f "$receipt" && "$(stat -c %a "$receipt")" == 600 ]]
"$tool" verify-receipt "$config" "$receipt" |
  grep -x 'profile_backup_admission=verified' >/dev/null

for root in "$test_root/nas" "$test_root/peer"; do
  generation_dir=$root/fixture/default/generations/$generation1
  [[ -f "$generation_dir/profile.tar.zst" ]]
  [[ -f "$generation_dir/receipt.env" ]]
  [[ "$(find "$generation_dir" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]]
done
if find "$test_root" -type f -name '*.age' |
  grep . >/dev/null; then
  echo 'obsolete age archive was staged during profile backup' >&2
  exit 1
fi

restore=$test_root/restore-root/drill-profile
"$tool" restore-to-disposable "$config" fixture-peer-copy \
  "$generation1" "$restore" |
  grep -x 'restore=disposable-only' >/dev/null
cmp "$test_root/profile/Default/Preferences" "$restore/Default/Preferences"
grep -qx 'source_destination=fixture-peer-copy' \
  "$restore/.helium-profile-restore-receipt.env"

nas_restore=$test_root/restore-root/drill-profile-nas
"$tool" restore-to-disposable "$config" nas-copy \
  "$generation1" "$nas_restore" |
  grep -x 'restore=disposable-only' >/dev/null
cmp "$test_root/profile/Default/Preferences" \
  "$nas_restore/Default/Preferences"
cmp "$restore/Default/Preferences" "$nas_restore/Default/Preferences"
grep -qx 'source_destination=nas-copy' \
  "$nas_restore/.helium-profile-restore-receipt.env"

if "$tool" restore-to-disposable "$config" nas-copy \
  "$generation1" "$restore" >/dev/null 2>&1; then
  echo 'restore overwrote an existing destination' >&2
  exit 1
fi

"$tool" backup "$config" "$generation2" >/dev/null
"$tool" backup "$config" "$generation3" >/dev/null
"$tool" retention-apply "$config" |
  grep -x "retired_generation=$generation1" >/dev/null
for root in "$test_root/nas" "$test_root/peer"; do
  [[ -f "$root/fixture/default/retired/$generation1/profile.tar.zst" ]]
  [[ -f "$root/fixture/default/retired/$generation1/receipt.env" ]]
done

archive=$test_root/nas/fixture/default/generations/$generation2/profile.tar.zst
printf tamper >>"$archive"
if "$tool" status "$config" "$generation2" >/dev/null 2>&1; then
  echo 'tampered profile backup passed status' >&2
  exit 1
fi
"$tool" quarantine "$config" nas-copy "$generation2" checksum-failed |
  grep -x "quarantined=$generation2" >/dev/null
[[ ! -e "$test_root/nas/fixture/default/generations/$generation2" ]]
find "$test_root/nas/fixture/default/quarantine" \
  -maxdepth 1 -type d -name "$generation2.*.checksum-failed" |
  grep . >/dev/null
if "$tool" retention-apply "$config" >/dev/null 2>&1; then
  echo 'retention proceeded across disagreeing destination inventories' >&2
  exit 1
fi

stream_hash=$(tar -C "$test_root" -cf - profile | sha256sum | awk '{print $1}')
stream_bytes=$(tar -C "$test_root" -cf - profile | wc -c)
tar -C "$test_root" -cf - profile |
  "$tool" backup-stream "$config" "$generation4" \
    "$stream_hash" "$stream_bytes" profile |
  grep -x 'backup=committed' >/dev/null
"$tool" status "$config" "$generation4" |
  grep -x 'status=healthy' >/dev/null
grep -qx 'source_fingerprint_kind=tar-stream-v1' \
  "$test_root/nas/fixture/default/generations/$generation4/receipt.env"
stream_restore=$test_root/restore-root/drill-stream-profile
"$tool" restore-to-disposable "$config" fixture-peer-copy \
  "$generation4" "$stream_restore" |
  grep -x 'restore=disposable-only' >/dev/null
cmp "$test_root/profile/Default/Preferences" \
  "$stream_restore/Default/Preferences"
if tar -C "$test_root" -cf - profile |
  "$tool" backup-stream "$config" 20260722T120400Z-5555555555555555 \
    "$(printf wrong | sha256sum | awk '{print $1}')" \
    "$stream_bytes" profile >/dev/null 2>&1; then
  echo 'changed backup stream passed its expected fingerprint' >&2
  exit 1
fi

( exec 9<"$test_root/profile/Default/Preferences"; sleep 600 ) &
holder_pid=$!
for _ in {1..50}; do
  [[ $(readlink -f "/proc/$holder_pid/fd/9" 2>/dev/null || true) == \
    "$test_root/profile/Default/Preferences" ]] && break
  sleep 0.1
done
[[ $(readlink -f "/proc/$holder_pid/fd/9" 2>/dev/null || true) == \
  "$test_root/profile/Default/Preferences" ]]
if "$tool" preflight "$config" >/dev/null 2>&1; then
  echo 'open source profile passed preflight' >&2
  exit 1
fi
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=

wrong_host_config=$test_root/wrong-host.conf
sed 's/fixture-peer|fixture-peer|/wrong-peer|fixture-peer|/' \
  "$config" >"$wrong_host_config"
chmod 600 "$wrong_host_config"
if PROFILE_TEST_REMOTE_HOST=fixture-peer \
  "$tool" preflight "$wrong_host_config" >/dev/null 2>&1; then
  echo 'wrong authenticated destination host was accepted' >&2
  exit 1
fi

same_host_config=$test_root/same-host.conf
sed "s/destination=fixture-peer-copy|device|ssh|fixture-peer|fixture-peer|/destination=fixture-peer-copy|device|ssh|$local_host|fixture-peer|/" \
  "$config" >"$same_host_config"
chmod 600 "$same_host_config"
if "$tool" status "$same_host_config" "$generation4" >/dev/null 2>&1; then
  echo 'same-host destinations passed topology validation' >&2
  exit 1
fi

chmod 644 "$test_root/ssh-identity"
if "$tool" preflight "$config" >/dev/null 2>&1; then
  echo 'loose SSH identity mode passed preflight' >&2
  exit 1
fi

printf 'profile_backup=passed\n'
