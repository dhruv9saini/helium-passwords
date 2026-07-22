#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
worker="${repo_root}/scripts/chromiumer-worker.sh"
test_root=$(mktemp -d /tmp/helium-watchdog-scan.XXXXXX)
watcher_pids=()

cleanup() {
    local result=$?
    local pid
    for pid in "${watcher_pids[@]}"; do
        kill "${pid}" 2>/dev/null || true
    done
    find "${test_root}" -depth -delete 2>/dev/null || true
    return "${result}"
}
trap cleanup EXIT

# shellcheck source=../chromiumer-worker.sh
source "${worker}"

grep -Fq -- '-ignore_readdir_race' "${worker}"
find --version | grep -q 'GNU findutils'

# Exercise GNU find itself through a blocked wrapper. The wrapper refuses to
# run unless disk_usage_bytes supplies the narrow readdir-race option. A
# directory is deleted while the scan command is deliberately pending.
race_root="${test_root}/race-tree"
race_bin="${test_root}/race-bin"
mkdir -p "${race_root}/keep" "${race_root}/delete/child" "${race_bin}"
printf 'keep\n' >"${race_root}/keep/file"
printf 'delete\n' >"${race_root}/delete/child/file"
real_find=$(command -v find)
cat >"${race_bin}/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${WATCHDOG_TEST_SLOW_SCAN:-}" = 1 ]; then
    [ "$#" -eq 5 ] && [ "$2" = -xdev ] && \
        [ "$3" = -ignore_readdir_race ] && [ "$4" = -printf ] && \
        [ "$5" = '%b\n' ] || {
        printf 'unexpected disk scan arguments: %q ' "$@" >&2
        printf '\n' >&2
        exit 2
    }
    : >"${WATCHDOG_TEST_SCAN_STARTED}"
    while [ ! -e "${WATCHDOG_TEST_SCAN_RELEASE}" ]; do
        sleep 0.02
    done
fi
exec "${WATCHDOG_TEST_REAL_FIND}" "$@"
EOF
chmod 700 "${race_bin}/find"

race_started="${test_root}/race.started"
race_release="${test_root}/race.release"
(
    PATH="${race_bin}:${PATH}" \
    WATCHDOG_TEST_SLOW_SCAN=1 \
    WATCHDOG_TEST_REAL_FIND="${real_find}" \
    WATCHDOG_TEST_SCAN_STARTED="${race_started}" \
    WATCHDOG_TEST_SCAN_RELEASE="${race_release}" \
        disk_usage_bytes "${race_root}"
) >"${test_root}/race.bytes" 2>"${test_root}/race.error" &
race_pid=$!
for _attempt in $(seq 1 100); do
    [ -e "${race_started}" ] && break
    sleep 0.02
done
[ -e "${race_started}" ] || {
    echo 'slow GNU find fixture did not block' >&2
    exit 1
}
"${real_find}" "${race_root}/delete" -depth -delete
: >"${race_release}"
wait "${race_pid}"
[[ "$(<"${test_root}/race.bytes")" =~ ^[0-9]+$ ]]
if [ -s "${test_root}/race.error" ]; then
    cat "${test_root}/race.error" >&2
    echo 'transient deletion was not tolerated' >&2
    exit 1
fi

# The readdir-race option must not hide a real starting-point failure.
if disk_usage_bytes "${test_root}/missing-start" \
    >"${test_root}/missing.out" 2>"${test_root}/missing.error"; then
    echo 'missing disk scan root unexpectedly passed' >&2
    exit 1
fi

fake_bin="${test_root}/guard-bin"
mkdir "${fake_bin}"
cat >"${fake_bin}/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=${!#}
available=1000
if [ "${target}" = / ] && [ -e "${WATCHDOG_TEST_ROOT_LOW}" ]; then
    available=1
fi
printf 'Filesystem 1B-blocks Used Available Use%% Mounted\n'
printf 'fixture 2000 0 %s 0%% %s\n' "${available}" "${target}"
EOF
chmod 700 "${fake_bin}/df"
cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 4 ] && [ "$1" = --user ] && [ "$2" = --quiet ] && \
    [ "$3" = is-active ] && [ "$4" = helium-job-fixture.service ]; then
    [ -e "${WATCHDOG_TEST_ACTIVE}" ]
    exit
fi
if [ "$#" -eq 3 ] && [ "$1" = --user ] && [ "$2" = stop ] && \
    [ "$3" = helium-job-fixture.service ]; then
    : >"${WATCHDOG_TEST_STOPPED}"
    find "${WATCHDOG_TEST_ACTIVE}" -delete
    exit 0
fi
printf 'unexpected systemctl arguments: %s\n' "$*" >&2
exit 2
EOF
chmod 700 "${fake_bin}/systemctl"

wait_for_file() {
    local path=$1
    for _attempt in $(seq 1 120); do
        [ -e "${path}" ] && return 0
        sleep 0.05
    done
    echo "timed out waiting for ${path}" >&2
    return 1
}

run_guard_case() {
    local kind=$1
    local expected_reason=$2
    local maximum_milliseconds=$3
    local case_root="${test_root}/${kind}"
    local state_dir="${case_root}/state"
    local work_dir="${case_root}/work"
    local active="${case_root}/active"
    local stopped="${case_root}/stopped"
    local root_low="${case_root}/root-low"
    local memory_low="${case_root}/memory-low"
    local scan_started="${case_root}/scan-started"
    local scan_release="${case_root}/scan-release"
    local scan_pid_file="${case_root}/scan-pid"
    mkdir -p "${state_dir}" "${work_dir}"
    : >"${active}"

    (
        disk_usage_bytes() {
            printf '%s\n' "${BASHPID}" >"${scan_pid_file}"
            : >"${scan_started}"
            while [ ! -e "${scan_release}" ]; do
                sleep 0.05
            done
            printf '0\n'
        }
        meminfo_bytes() {
            [ "$1" = MemAvailable ]
            if [ -e "${memory_low}" ]; then
                printf '1\n'
            else
                printf '1000\n'
            fi
        }
        PATH="${fake_bin}:${PATH}" \
        WATCHDOG_TEST_ACTIVE="${active}" \
        WATCHDOG_TEST_STOPPED="${stopped}" \
        WATCHDOG_TEST_ROOT_LOW="${root_low}" \
            watch_job "${state_dir}" "${work_dir}" \
                helium-job-fixture.service 1000 100 100 30 1
    ) >"${case_root}/watch.out" 2>"${case_root}/watch.error" &
    local watcher_pid=$!
    watcher_pids+=("${watcher_pid}")
    wait_for_file "${scan_started}"

    local started_at finished_at elapsed
    started_at=$(date +%s%N)
    if [ "${kind}" = root ]; then
        : >"${root_low}"
    else
        : >"${memory_low}"
    fi
    wait_for_file "${state_dir}/watchdog-stop.env"
    finished_at=$(date +%s%N)
    elapsed=$(((finished_at - started_at) / 1000000))

    set +e
    wait "${watcher_pid}"
    local result=$?
    set -e
    [ "${result}" -eq 1 ]
    grep -Fqx "reason=${expected_reason}" "${state_dir}/watchdog-stop.env"
    [ -e "${stopped}" ]
    [ "${elapsed}" -le "${maximum_milliseconds}" ] || {
        echo "${kind} guard took ${elapsed}ms" >&2
        exit 1
    }
    local scan_pid
    scan_pid=$(<"${scan_pid_file}")
    if kill -0 "${scan_pid}" 2>/dev/null; then
        echo "${kind} scan survived watchdog stop" >&2
        exit 1
    fi
    printf '%s_guard_milliseconds=%s\n' "${kind}" "${elapsed}"
}

# Both guards fire while the disk scan remains blocked. Root is immediate;
# memory requires two consecutive fresh one-second samples.
run_guard_case root 'root free-space floor breached' 2500
run_guard_case memory 'host available-memory floor breached' 3500

run_scan_case() {
    local kind=$1
    local expected_reason=${2:-}
    local case_root="${test_root}/${kind}"
    local state_dir="${case_root}/state"
    local work_dir="${case_root}/work"
    local active="${case_root}/active"
    local stopped="${case_root}/stopped"
    local root_low="${case_root}/root-low"
    mkdir -p "${state_dir}" "${work_dir}"
    : >"${active}"

    (
        disk_usage_bytes() {
            case "${kind}" in
                healthy) printf '640\n' ;;
                silent-retry)
                    if [ ! -e "${case_root}/scan-attempted" ]; then
                        : >"${case_root}/scan-attempted"
                        return 7
                    fi
                    printf '640\n'
                    ;;
                silent-persistent) return 7 ;;
                disk-budget) printf '1001\n' ;;
                scan-error)
                    echo 'synthetic non-race find failure' >&2
                    return 7
                    ;;
            esac
        }
        meminfo_bytes() {
            [ "$1" = MemAvailable ]
            printf '1000\n'
        }
        PATH="${fake_bin}:${PATH}" \
        WATCHDOG_TEST_ACTIVE="${active}" \
        WATCHDOG_TEST_STOPPED="${stopped}" \
        WATCHDOG_TEST_ROOT_LOW="${root_low}" \
            watch_job "${state_dir}" "${work_dir}" \
                helium-job-fixture.service 1000 100 100 30 1
    ) >"${case_root}/watch.out" 2>"${case_root}/watch.error" &
    local watcher_pid=$!
    watcher_pids+=("${watcher_pid}")

    if [[ "${kind}" == healthy || "${kind}" == silent-retry ]]; then
        wait_for_file "${state_dir}/watchdog-ready.env"
        grep -Fqx 'workspace_bytes=640' "${state_dir}/health.env"
        grep -Fqx 'status=ok' "${state_dir}/health.env"
        if [ "${kind}" = silent-retry ]; then
            grep -Fqx 'exit_code=7' "${state_dir}/disk-scan-retry.env"
            grep -Fqx 'reason=silent disk usage scan failure' \
                "${state_dir}/disk-scan-retry.env"
        fi
        find "${active}" -delete
    else
        wait_for_file "${state_dir}/watchdog-stop.env"
        grep -Fqx "reason=${expected_reason}" \
            "${state_dir}/watchdog-stop.env"
        wait_for_file "${stopped}"
    fi

    set +e
    wait "${watcher_pid}"
    local result=$?
    set -e
    if [[ "${kind}" == healthy || "${kind}" == silent-retry ]]; then
        if [ "${result}" -ne 0 ]; then
            cat "${case_root}/watch.error" >&2
            echo "healthy watcher exited ${result}" >&2
            exit 1
        fi
    else
        if [ "${result}" -ne 1 ]; then
            cat "${case_root}/watch.error" >&2
            echo "${kind} watcher exited ${result}" >&2
            exit 1
        fi
    fi
}

run_scan_case healthy
run_scan_case silent-retry
run_scan_case silent-persistent \
    'disk usage scan repeatedly failed without diagnostics'
run_scan_case disk-budget 'job disk budget breached'
run_scan_case scan-error 'disk usage scan failed'
grep -Fq 'disk usage scan: synthetic non-race find failure' \
    "${test_root}/scan-error/watch.error"

printf 'chromiumer_watchdog_scan=passed\n'
printf 'transient_deletion=ignored_by_gnu_find\n'
