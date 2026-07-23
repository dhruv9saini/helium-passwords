#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
worker="${repo_root}/scripts/chromiumer-worker.sh"
test_root=$(mktemp -d /tmp/helium-watchdog-test.XXXXXX)

cleanup() {
    local result=$?
    if [ -f "${test_root}/command.pid" ]; then
        kill "$(cat "${test_root}/command.pid")" 2>/dev/null || true
    fi
    find "${test_root}" -depth -delete 2>/dev/null || true
    return "${result}"
}
trap cleanup EXIT

# shellcheck source=../chromiumer-worker.sh
source "${worker}"

many_files="${test_root}/many-files"
mkdir -p "${many_files}"
for directory in $(seq 1 80); do
    mkdir "${many_files}/${directory}"
    for file in $(seq 1 100); do
        printf 'first-generation-%s-%s\n' "${directory}" "${file}" \
            >"${many_files}/${directory}/${file}"
    done
done
first_bytes=$(disk_usage_bytes "${many_files}")

for directory in $(seq 81 160); do
    mkdir "${many_files}/${directory}"
    for file in $(seq 1 100); do
        printf 'second-generation-%s-%s\n' "${directory}" "${file}" \
            >"${many_files}/${directory}/${file}"
    done
done
second_bytes=$(
    ulimit -v $((64 * 1024))
    disk_usage_bytes "${many_files}"
)
[ "${second_bytes}" -gt "${first_bytes}" ] || {
    echo "streaming disk accounting missed a growing many-file tree" >&2
    exit 1
}

# Hard links are intentionally counted once per directory entry. This can stop
# a job early, but it cannot undercount the declared workspace budget.
printf 'hard-link-fixture\n' >"${many_files}/hard-link-source"
ln "${many_files}/hard-link-source" "${many_files}/hard-link-replica"
streamed_bytes=$(disk_usage_bytes "${many_files}")
du_bytes=$(du -sx -B1 "${many_files}" | awk '{ print $1 }')
[ "${streamed_bytes}" -ge "${du_bytes}" ] || {
    echo "streaming disk accounting undercounted allocated blocks" >&2
    exit 1
}

fake_bin="${test_root}/bin"
state_dir="${test_root}/state"
mkdir -p "${fake_bin}" "${state_dir}"
cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 4 ] && [ "$1" = --user ] && [ "$2" = --quiet ] && \
    [ "$3" = is-active ] && [ "$4" = helium-watch-fixture.service ] || {
    printf 'unexpected systemctl arguments: %s\n' "$*" >&2
    exit 2
}
count=0
[ ! -f "${WATCHDOG_TEST_COUNTER}" ] || count=$(cat "${WATCHDOG_TEST_COUNTER}")
count=$((count + 1))
printf '%s\n' "${count}" >"${WATCHDOG_TEST_COUNTER}"
[ "${count}" -le 3 ]
EOF
chmod 700 "${fake_bin}/systemctl"

cat >"${state_dir}/policy.env" <<EOF
started_at_epoch=$(date +%s)
EOF
printf 'watchdog_ready_at=%s\n' "$(date --iso-8601=seconds)" \
    >"${state_dir}/watchdog-ready.env"

set +e
PATH="${fake_bin}:${PATH}" \
WATCHDOG_TEST_COUNTER="${test_root}/watchdog-checks" \
timeout 10 "${worker}" run "${state_dir}" helium-watch-fixture.service 3 1 -- \
    sh -c 'printf "%s\n" "$$" >"$1"; exec sleep 30' sh \
    "${test_root}/command.pid"
run_result=$?
set -e
[ "${run_result}" -eq 125 ] || {
    echo "watchdog death did not fail the build wrapper: ${run_result}" >&2
    exit 1
}

grep -qx 'result=failure' "${state_dir}/terminal.env"
grep -qx 'exit_code=125' "${state_dir}/terminal.env"
grep -qx 'reason=health watchdog exited unexpectedly' \
    "${state_dir}/terminal.env"
grep -qx 'exit_code=125' "${state_dir}/result.env"
grep -qx 'reason=health watchdog exited unexpectedly' \
    "${state_dir}/watchdog-stop.env"
[ ! -e "${state_dir}/cancel.env" ]

command_pid=$(cat "${test_root}/command.pid")
for _attempt in $(seq 1 20); do
    kill -0 "${command_pid}" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "${command_pid}" 2>/dev/null; then
    echo "build command survived watchdog death" >&2
    exit 1
fi

cancel_state="${test_root}/cancel-state"
mkdir "${cancel_state}"
cat >"${cancel_state}/policy.env" <<EOF
started_at_epoch=$(date +%s)
EOF
printf 'watchdog_ready_at=%s\n' "$(date --iso-8601=seconds)" \
    >"${cancel_state}/watchdog-ready.env"
printf 'cancelled_at=%s\n' "$(date --iso-8601=seconds)" \
    >"${cancel_state}/cancel.env"
set +e
PATH="${fake_bin}:${PATH}" \
WATCHDOG_TEST_COUNTER="${test_root}/cancel-watchdog-checks" \
timeout 10 "${worker}" run "${cancel_state}" \
    helium-watch-fixture.service 3 1 -- \
    sh -c 'touch "$1"' sh "${test_root}/unexpected-command-start"
cancel_result=$?
set -e
[ "${cancel_result}" -eq 130 ]
grep -qx 'result=cancellation' "${cancel_state}/terminal.env"
grep -qx 'exit_code=130' "${cancel_state}/terminal.env"
grep -qx 'reason=cancelled through chromiumer-job.sh' \
    "${cancel_state}/terminal.env"
[ ! -e "${test_root}/unexpected-command-start" ]

printf 'chromiumer_watchdog=passed\n'
printf 'many_file_entries=%s\n' 16000
printf 'streamed_workspace_bytes=%s\n' "${streamed_bytes}"
printf 'terminal_exit_code=%s\n' 125
