#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-unit-terminal.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/bin"

cat >"${test_root}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${UNIT_TEST_PHASE:-absent}" in
  absent)
    printf 'LoadState=not-found\nActiveState=inactive\nSubState=dead\nResult=success\nExecMainCode=exited\nExecMainStatus=0\nExecMainStartTimestampMonotonic=0\nExecMainExitTimestampMonotonic=0\n'
    ;;
  running)
    printf 'LoadState=loaded\nActiveState=active\nSubState=running\nResult=success\nExecMainCode=exited\nExecMainStatus=0\nExecMainStartTimestampMonotonic=1000000\nExecMainExitTimestampMonotonic=0\n'
    ;;
  success)
    printf 'LoadState=loaded\nActiveState=active\nSubState=exited\nResult=success\nExecMainCode=exited\nExecMainStatus=0\nExecMainStartTimestampMonotonic=1000000\nExecMainExitTimestampMonotonic=62000000\n'
    ;;
  failure)
    printf 'LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainCode=exited\nExecMainStatus=7\nExecMainStartTimestampMonotonic=1000000\nExecMainExitTimestampMonotonic=3000000\n'
    ;;
esac
EOF
chmod 700 "${test_root}/bin/systemctl"
export PATH="${test_root}/bin:${PATH}"
export HELIUM_UNIT_TERMINAL_STATE_ROOT="${test_root}/state"
monitor="${repo_root}/scripts/chromiumer-unit-terminal.sh"

export UNIT_TEST_PHASE=absent
"${monitor}" arm retained-success >/dev/null
[ "$("${monitor}" terminal retained-success)" = state=staged ]
export UNIT_TEST_PHASE=running
[ "$("${monitor}" terminal retained-success)" = state=running ]
export UNIT_TEST_PHASE=success
success=$("${monitor}" terminal retained-success)
grep -Fqx 'state=terminal' <<<"${success}"
grep -Fqx 'result=success' <<<"${success}"
grep -Fqx 'exit_code=0' <<<"${success}"
grep -Fqx 'duration_seconds=61' <<<"${success}"

export UNIT_TEST_PHASE=absent
"${monitor}" arm retained-failure >/dev/null
export UNIT_TEST_PHASE=failure
failure=$("${monitor}" terminal retained-failure)
grep -Fqx 'state=terminal' <<<"${failure}"
grep -Fqx 'result=failure' <<<"${failure}"
grep -Fqx 'exit_code=7' <<<"${failure}"
grep -Fqx 'duration_seconds=2' <<<"${failure}"
[ "$(stat -c %a "${test_root}/state/retained-failure.env")" = 600 ]

echo 'chromiumer retained unit terminal monitor simulations passed'
