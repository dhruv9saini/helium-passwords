#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-backup-control.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT
mkdir -p "$test_root/runtime"

cat >"$test_root/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_SYSTEMD_STATE:?}
command_name=${1:-}
shift
if [[ "$command_name" == show ]]; then
  service=${1:-}
else
  service=${*: -1}
fi
printf '%s %s\n' "$command_name" "$service" >>"$state/calls"
case "$command_name" in
  is-active)
    [[ $(cat "$state/$service.active") == true ]]
    ;;
  stop)
    [[ ! -e "$state/$service.stop-fail" ]] || exit 1
    printf false >"$state/$service.active"
    ;;
  start)
    [[ ! -e "$state/$service.start-fail" ]] || exit 1
    if [[ "$service" == helium-sync-server-backup-archive.service ]]; then
      printf false >"$state/$service.active"
      [[ ! -e "$state/archive-result-fail" ]] || printf failure >"$state/archive.result"
    else
      printf true >"$state/$service.active"
    fi
    ;;
  show)
    cat "$state/archive.result"
    ;;
  *) exit 2 ;;
esac
MOCK
chmod 0755 "$test_root/systemctl"

reset_state() {
  find "$test_root/runtime" -mindepth 1 -delete
  : >"$test_root/runtime/calls"
  printf true >"$test_root/runtime/helium-syncd.service.active"
  printf false >"$test_root/runtime/helium-sync-server-backup-archive.service.active"
  printf success >"$test_root/runtime/archive.result"
  rm -f "$test_root/restart-required" "$test_root/operator.lock"
}

run_control() {
  unshare -Ur env \
    FAKE_SYSTEMD_STATE="$test_root/runtime" \
    HELIUM_BACKUP_SYSTEMCTL="$test_root/systemctl" \
    HELIUM_BACKUP_OPERATOR_LOCK="$test_root/operator.lock" \
    HELIUM_BACKUP_RESTART_MARKER="$test_root/restart-required" \
    "$repo_root/scripts/helium-sync-server-backup-control.sh" "$@"
}

reset_state
run_control run >/dev/null
[[ $(cat "$test_root/runtime/helium-syncd.service.active") == true ]]
[[ ! -e "$test_root/restart-required" ]]
cat >"$test_root/expected" <<'EOF'
is-active helium-syncd.service
stop helium-syncd.service
is-active helium-syncd.service
start helium-sync-server-backup-archive.service
show helium-sync-server-backup-archive.service
stop helium-sync-server-backup-archive.service
is-active helium-sync-server-backup-archive.service
start helium-syncd.service
is-active helium-syncd.service
EOF
cmp "$test_root/expected" "$test_root/runtime/calls"

reset_state
printf false >"$test_root/runtime/helium-syncd.service.active"
if run_control run >/dev/null 2>&1; then
  echo "backup controller accepted an inactive daemon" >&2
  exit 1
fi
[[ ! -e "$test_root/restart-required" ]]
[[ $(wc -l <"$test_root/runtime/calls") -eq 1 ]]

reset_state
touch "$test_root/runtime/archive-result-fail"
if run_control run >/dev/null 2>&1; then
  echo "backup controller accepted a failed archive worker" >&2
  exit 1
fi
[[ $(cat "$test_root/runtime/helium-syncd.service.active") == true ]]
[[ ! -e "$test_root/restart-required" ]]

# This is the durable recovery path after a controller SIGKILL: the marker and
# independently active archive worker survive. The worker must stop first.
reset_state
printf 'restart-helium-syncd-v1\n' >"$test_root/restart-required"
chmod 0600 "$test_root/restart-required"
printf true >"$test_root/runtime/helium-sync-server-backup-archive.service.active"
printf false >"$test_root/runtime/helium-syncd.service.active"
touch "$test_root/runtime/helium-syncd.service.start-fail"
if run_control resume >/dev/null 2>&1; then
  echo "backup controller accepted a failed daemon restart" >&2
  exit 1
fi
[[ -e "$test_root/restart-required" ]]
[[ $(cat "$test_root/runtime/helium-sync-server-backup-archive.service.active") == false ]]
[[ $(cat "$test_root/runtime/helium-syncd.service.active") == false ]]
rm "$test_root/runtime/helium-syncd.service.start-fail"
: >"$test_root/runtime/calls"
run_control resume >/dev/null
[[ ! -e "$test_root/restart-required" ]]
[[ $(sed -n '1p' "$test_root/runtime/calls") == \
  'stop helium-sync-server-backup-archive.service' ]]

reset_state
printf 'wrong\n' >"$test_root/restart-required"
chmod 0600 "$test_root/restart-required"
if run_control resume >/dev/null 2>&1; then
  echo "backup controller accepted an invalid restart marker" >&2
  exit 1
fi
[[ $(cat "$test_root/runtime/helium-syncd.service.active") == true ]]

echo 'server_backup_control=passed'
