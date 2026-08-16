#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
worker="${repo_root}/scripts/chromiumer-worker.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-link-memory-relief.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT

# shellcheck source=../chromiumer-worker.sh
source "${worker}"
state_root="${test_root}/state"
job=link-memory-job
state="${state_root}/${job}"
unit="helium-job-${job}.service"
control_group="/user.slice/user-1000.slice/user@1000.service/app.slice/${unit}"
export HELIUM_CGROUP_ROOT="${test_root}/cgroup"
export HELIUM_MEMINFO_PATH="${test_root}/meminfo"
export LINK_MEMORY_ACTIVE="${test_root}/active"
export LINK_MEMORY_EFFECTIVE="${test_root}/effective"
mkdir -p "${state}" "${test_root}/bin" \
    "${HELIUM_CGROUP_ROOT}${control_group}"
touch "${LINK_MEMORY_ACTIVE}"

cat >"${test_root}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2 ${3:-}" = '--user --quiet is-active' ]; then
    [ -e "${LINK_MEMORY_ACTIVE}" ]
    exit
fi
if [ "$1 $2" = '--user set-property' ]; then
    [ "$3" = --runtime ] && [ "$5" = MemoryHigh=3328M ]
    touch "${LINK_MEMORY_EFFECTIVE}"
    exit
fi
if [ "$1 $2" = '--user show' ]; then
    unit=$3
    property=${4#--property=}
    case "${unit}:${property}" in
        helium-job-link-memory-job.service:InvocationID)
            printf '11111111111111111111111111111111\n' ;;
        helium-watch-link-memory-job.service:InvocationID)
            printf '22222222222222222222222222222222\n' ;;
        helium-job-link-memory-job.service:ActiveEnterTimestampMonotonic)
            printf '1001\n' ;;
        helium-watch-link-memory-job.service:ActiveEnterTimestampMonotonic)
            printf '1002\n' ;;
        helium-job-link-memory-job.service:RuntimeMaxUSec) printf '2d\n' ;;
        helium-watch-link-memory-job.service:RuntimeMaxUSec) printf '2d 5min\n' ;;
        helium-job-link-memory-job.service:MemoryHigh)
            if [ -e "${LINK_MEMORY_EFFECTIVE}" ]; then
                printf '3489660928\n'
            else
                printf '3221225472\n'
            fi
            ;;
        helium-job-link-memory-job.service:MemoryMax) printf '6442450944\n' ;;
        helium-job-link-memory-job.service:MemorySwapMax) printf '3221225472\n' ;;
        helium-job-link-memory-job.service:ControlGroup)
            printf '/user.slice/user-1000.slice/user@1000.service/app.slice/helium-job-link-memory-job.service\n' ;;
        *) exit 2 ;;
    esac
    exit
fi
exit 2
EOF
chmod 700 "${test_root}/bin/systemctl"
export PATH="${test_root}/bin:${PATH}"

cat >"${state}/stage.env" <<'EOF'
profile=production
EOF
cat >"${state}/policy.env" <<'EOF'
profile=production
build_jobs=1
source_build_jobs=1
memory_high=3G
memory_max=6G
memory_swap_max=3G
wall_seconds=86400
wall_class=extended-linux-three-gib-high-link
command=scripts/chromiumer-nix.sh run -- env HELIUM_LINUX_PHASE=retained CCC_OVERRIDE_OPTIONS=#\ +-Wl\,--threads=1 bash scripts/build-chromiumer-linux.sh
EOF
cat >"${state}/resume.env" <<'EOF'
command_mode=exact
parent_terminal_mode=retained-linux-final-link-three-gib-high-recovery
EOF
cat >"${state}/health.env" <<'EOF'
status=ok
EOF
cat >"${state}/wall-extension.env" <<'EOF'
unit_invocation_id=11111111111111111111111111111111
watch_invocation_id=22222222222222222222222222222222
unit_active_enter_monotonic=1001
watch_active_enter_monotonic=1002
EOF
cat >"${HELIUM_CGROUP_ROOT}${control_group}/memory.current" <<'EOF'
3289000000
EOF
cat >"${HELIUM_CGROUP_ROOT}${control_group}/memory.events" <<'EOF'
low 0
high 100
max 0
oom 0
oom_kill 0
oom_group_kill 0
EOF
cat >"${HELIUM_MEMINFO_PATH}" <<'EOF'
MemAvailable:    1600000 kB
EOF

relieve_active_three_gib_link_memory "${job}" >"${test_root}/relief.out"
grep -Fqx 'state=active' "${test_root}/relief.out"
grep -Fqx 'effective_memory_high_bytes=3489660928' \
    "${state}/link-memory-relief.env"
grep -Fqx 'memory_high_events_before=100' \
    "${state}/link-memory-relief.env"
grep -Fqx 'unit_invocation_id=11111111111111111111111111111111' \
    "${state}/link-memory-relief.env"

if (relieve_active_three_gib_link_memory "${job}") \
    >"${test_root}/second.out" 2>"${test_root}/second.error"; then
    echo "second link memory relief unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'disqualifying state' "${test_root}/second.error"

find "${state}/link-memory-relief.env" "${LINK_MEMORY_EFFECTIVE}" -delete
cat >"${HELIUM_MEMINFO_PATH}" <<'EOF'
MemAvailable:    1300000 kB
EOF
if (relieve_active_three_gib_link_memory "${job}") \
    >"${test_root}/low.out" 2>"${test_root}/low.error"; then
    echo "low-memory link relief unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'lacks safe live pressure evidence' "${test_root}/low.error"

printf 'chromiumer link memory relief tests passed\n'
