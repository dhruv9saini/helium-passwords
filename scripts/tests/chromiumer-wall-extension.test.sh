#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
worker="${repo_root}/scripts/chromiumer-worker.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-wall-extension.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT

# shellcheck source=../chromiumer-worker.sh
source "${worker}"
state_root="${test_root}/state"
mkdir -p "${state_root}/wall-extension-job" "${test_root}/bin"
export HELIUM_SYSTEMD_USER_CONTROL_ROOT="${test_root}/runtime-control"
export WALL_EXTENSION_RELOADED="${test_root}/reloaded"
export WALL_EXTENSION_ACTIVE="${test_root}/active"
touch "${WALL_EXTENSION_ACTIVE}"

cat >"${test_root}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2 ${3:-}" = '--user --quiet is-active' ]; then
    [ -e "${WALL_EXTENSION_ACTIVE}" ]
    exit
fi
if [ "$1 $2" = '--user daemon-reload' ]; then
    touch "${WALL_EXTENSION_RELOADED}"
    exit
fi
if [ "$1 $2" = '--user show' ]; then
    unit=$3
    property=${4#--property=}
    case "${unit}:${property}" in
        helium-job-wall-extension-job.service:InvocationID)
            printf '11111111111111111111111111111111\n' ;;
        helium-watch-wall-extension-job.service:InvocationID)
            printf '22222222222222222222222222222222\n' ;;
        helium-job-wall-extension-job.service:ActiveEnterTimestampMonotonic)
            printf '1001\n' ;;
        helium-watch-wall-extension-job.service:ActiveEnterTimestampMonotonic)
            printf '1002\n' ;;
        helium-job-wall-extension-job.service:RuntimeMaxUSec)
            if [ -e "${WALL_EXTENSION_RELOADED}" ]; then
                printf '2d\n'
            else
                printf '1d\n'
            fi
            ;;
        helium-watch-wall-extension-job.service:RuntimeMaxUSec)
            if [ -e "${WALL_EXTENSION_RELOADED}" ]; then
                printf '2d 5min\n'
            else
                printf '1d 5min\n'
            fi
            ;;
        *) exit 2 ;;
    esac
    exit
fi
exit 2
EOF
chmod 700 "${test_root}/bin/systemctl"
export PATH="${test_root}/bin:${PATH}"

cat >"${state_root}/wall-extension-job/stage.env" <<'EOF'
profile=production
EOF
cat >"${state_root}/wall-extension-job/policy.env" <<'EOF'
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
cat >"${state_root}/wall-extension-job/resume.env" <<'EOF'
command_mode=exact
parent_terminal_mode=retained-linux-final-link-three-gib-high-recovery
EOF
cat >"${state_root}/wall-extension-job/health.env" <<'EOF'
status=ok
EOF

extend_active_three_gib_wall wall-extension-job \
    >"${test_root}/extension.out"
grep -Fqx 'state=active' "${test_root}/extension.out"
grep -Fqx 'effective_wall_seconds=172800' \
    "${state_root}/wall-extension-job/wall-extension.env"
grep -Fqx \
    'unit_invocation_id=11111111111111111111111111111111' \
    "${state_root}/wall-extension-job/wall-extension.env"
grep -Fqx 'RuntimeMaxSec=172800' \
    "${test_root}/runtime-control/helium-job-wall-extension-job.service.d/50-helium-wall-extension.conf"
grep -Fqx 'RuntimeMaxSec=173100' \
    "${test_root}/runtime-control/helium-watch-wall-extension-job.service.d/50-helium-wall-extension.conf"

if (extend_active_three_gib_wall wall-extension-job) \
    >"${test_root}/second.out" 2>"${test_root}/second.error"; then
    echo "second wall extension unexpectedly succeeded" >&2
    exit 1
fi
grep -Fq 'disqualifying state' "${test_root}/second.error"

printf 'chromiumer wall extension tests passed\n'
