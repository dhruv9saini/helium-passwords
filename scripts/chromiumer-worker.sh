#!/usr/bin/env bash
set -euo pipefail

state_root=${HELIUM_CHROMIUMER_STATE_ROOT:-"${HOME}/.local/state/helium-builds"}
work_root=${HELIUM_CHROMIUMER_WORK_ROOT:-"${HOME}/helium-builds/work"}
root_floor_bytes=$((2 * 1024 * 1024 * 1024))

usage() {
    cat >&2 <<'EOF'
usage: chromiumer-worker.sh <command> [arguments]

Remote-only commands are invoked by scripts/chromiumer-job.sh on lm.
EOF
}

validate_job() {
    local job=$1
    [[ "${job}" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
        echo "invalid job id: ${job}" >&2
        exit 2
    }
}

gib() {
    printf '%s\n' "$(( $1 * 1024 * 1024 * 1024 ))"
}

profile() {
    case "$1" in
        production)
            build_jobs=2
            cpu_quota=200%
            cpu_weight=10
            memory_high=4G
            memory_max=5G
            tasks_max=256
            min_mem_total_bytes=$(gib 7)
            min_mem_available_bytes=$(gib 2)
            watchdog_mem_floor_bytes=$(gib 1)
            wall_seconds=28800
            watchdog_interval=30
            watchdog_memory_high=64M
            watchdog_memory_max=128M
            watchdog_ready_seconds=30
            supervisor_interval=1
            ;;
        test)
            build_jobs=1
            cpu_quota=50%
            cpu_weight=10
            memory_high=128M
            memory_max=256M
            tasks_max=32
            min_mem_total_bytes=$(gib 1)
            min_mem_available_bytes=$((256 * 1024 * 1024))
            watchdog_mem_floor_bytes=$((64 * 1024 * 1024))
            wall_seconds=120
            watchdog_interval=1
            watchdog_memory_high=64M
            watchdog_memory_max=128M
            watchdog_ready_seconds=10
            supervisor_interval=1
            ;;
        *)
            echo "unknown isolation profile: $1" >&2
            exit 2
            ;;
    esac
}

meminfo_bytes() {
    local field=$1
    awk -v field="${field}:" '$1 == field { print $2 * 1024; exit }' /proc/meminfo
}

disk_usage_bytes() {
    LC_ALL=C find "$1" -xdev -ignore_readdir_race -printf '%b\n' | \
        awk '{ blocks += $1 } END { printf "%.0f\n", blocks * 512 }'
}

required_build_available_bytes() {
    local budget=$1
    local used=$2
    local shares_root=$3
    [ "${used}" -le "${budget}" ] || return 1
    local required=$((budget - used))
    if [ "${shares_root}" = yes ]; then
        required=$((required + root_floor_bytes))
    fi
    printf '%s\n' "${required}"
}

require_worker_host() {
    [ "$(hostname -s)" = chromiumer ] || {
        echo "refusing to run outside chromiumer" >&2
        exit 1
    }
}

require_contained_path() {
    local path=$1
    local root=$2
    case "${path}" in
        "${root}"/*) ;;
        *)
            echo "path is outside ${root}: ${path}" >&2
            exit 1
            ;;
    esac
}

preflight() {
    local profile_name=$1
    local disk_budget_gib=$2
    local probe_path=${3:-"${work_root}"}
    local accounted_path=${4:-}
    [[ "${disk_budget_gib}" =~ ^[1-9][0-9]*$ ]] || {
        echo "preflight failed: disk budget must be a positive whole number of GiB" >&2
        return 1
    }
    local disk_budget_bytes
    disk_budget_bytes=$(gib "${disk_budget_gib}")
    profile "${profile_name}"
    require_worker_host

    local required=(awk df find flock grep install ionice journalctl ln nice realpath sed sha256sum stat systemctl systemd-run tar timeout)
    local tool
    for tool in "${required[@]}"; do
        command -v "${tool}" >/dev/null 2>&1 || {
            echo "preflight failed: missing tool: ${tool}" >&2
            return 1
        }
    done
    find --version 2>/dev/null | grep -q 'GNU findutils' || {
        echo "preflight failed: GNU findutils is required" >&2
        return 1
    }

    [ "$(systemctl --user is-system-running)" = running ] || {
        echo "preflight failed: user systemd manager is not running" >&2
        return 1
    }

    local controller
    for controller in cpu io memory pids; do
        grep -qw "${controller}" /sys/fs/cgroup/cgroup.controllers || {
            echo "preflight failed: cgroup v2 controller unavailable: ${controller}" >&2
            return 1
        }
    done

    mkdir -p "${probe_path}"
    probe_path=$(realpath -e "${probe_path}")
    require_contained_path "${probe_path}" "$(realpath -e "${HOME}")"

    local available workspace_bytes remaining_bytes required_space shares_root
    local root_available probe_device root_device memory_total memory_available
    available=$(df -PB1 "${probe_path}" | awk 'NR == 2 { print $4 }')
    workspace_bytes=0
    if [ -n "${accounted_path}" ]; then
        accounted_path=$(realpath -e "${accounted_path}")
        require_contained_path "${accounted_path}" "$(realpath -e "${work_root}")"
        workspace_bytes=$(disk_usage_bytes "${accounted_path}")
    fi
    [ "${workspace_bytes}" -le "${disk_budget_bytes}" ] || {
        echo "preflight failed: workspace_bytes=${workspace_bytes}, disk_budget_bytes=${disk_budget_bytes}" >&2
        return 1
    }
    remaining_bytes=$((disk_budget_bytes - workspace_bytes))
    root_available=$(df -PB1 / | awk 'NR == 2 { print $4 }')
    probe_device=$(stat -c %d "${probe_path}")
    root_device=$(stat -c %d /)
    shares_root=no
    if [ "${probe_device}" = "${root_device}" ]; then
        shares_root=yes
    fi
    required_space=$(required_build_available_bytes \
        "${disk_budget_bytes}" "${workspace_bytes}" "${shares_root}")
    memory_total=$(meminfo_bytes MemTotal)
    memory_available=$(meminfo_bytes MemAvailable)

    [ "${available}" -ge "${required_space}" ] || {
        echo "preflight failed: build_available_bytes=${available}, required_bytes=${required_space}, disk_budget_remaining_bytes=${remaining_bytes}, build_shares_root=${shares_root}" >&2
        return 1
    }
    if [ "${shares_root}" = no ]; then
        [ "${root_available}" -ge "${root_floor_bytes}" ] || {
            echo "preflight failed: root_available_bytes=${root_available}, root_floor_bytes=${root_floor_bytes}" >&2
            return 1
        }
    fi
    [ "${memory_total}" -ge "${min_mem_total_bytes}" ] || {
        echo "preflight failed: memory_total_bytes=${memory_total}, required_bytes=${min_mem_total_bytes}" >&2
        return 1
    }
    [ "${memory_available}" -ge "${min_mem_available_bytes}" ] || {
        echo "preflight failed: memory_available_bytes=${memory_available}, required_bytes=${min_mem_available_bytes}" >&2
        return 1
    }

    if systemctl --user --quiet is-active 'helium-job-*.service'; then
        echo "preflight failed: another Helium build is active" >&2
        return 1
    fi

    printf 'preflight=ok\nprofile=%s\ndisk_budget_gib=%s\nbuild_available_bytes=%s\nworkspace_bytes=%s\ndisk_budget_bytes=%s\ndisk_budget_remaining_bytes=%s\nbuild_shares_root=%s\nrequired_build_available_bytes=%s\nroot_available_bytes=%s\nroot_floor_bytes=%s\nmemory_total_bytes=%s\nmemory_available_bytes=%s\n' \
        "${profile_name}" "${disk_budget_gib}" "${available}" \
        "${workspace_bytes}" "${disk_budget_bytes}" "${remaining_bytes}" \
        "${shares_root}" "${required_space}" \
        "${root_available}" "${root_floor_bytes}" \
        "${memory_total}" "${memory_available}"
}

stage_init() {
    local job=$1
    local disk_budget_gib=$2
    validate_job "${job}"
    preflight production "${disk_budget_gib}" "${work_root}"

    local state_dir="${state_root}/${job}"
    local job_root="${work_root}/${job}"
    [ ! -e "${state_dir}" ] && [ ! -e "${job_root}" ] || {
        echo "job already exists: ${job}" >&2
        exit 1
    }
    mkdir -p "${state_dir}" "${job_root}"
    printf 'profile=production\ndisk_budget_gib=%s\ndisk_budget_bytes=%s\nstaged_at=%s\n' \
        "${disk_budget_gib}" "$(gib "${disk_budget_gib}")" \
        "$(date --iso-8601=seconds)" >"${state_dir}/stage.env"
}

stage_finish() {
    local job=$1
    local expected_sha=$2
    validate_job "${job}"

    local state_dir="${state_root}/${job}"
    local job_root="${work_root}/${job}"
    local archive="${state_dir}/source.tar"
    local source_dir="${job_root}/source"
    [ -f "${archive}" ] && [ -f "${state_dir}/source.manifest.incoming" ] || {
        echo "incomplete source transfer for ${job}" >&2
        exit 1
    }
    [ ! -e "${source_dir}" ] || {
        echo "source already materialized for ${job}" >&2
        exit 1
    }
    printf '%s  %s\n' "${expected_sha}" "${archive}" | sha256sum --check --status || {
        echo "source archive checksum mismatch" >&2
        exit 1
    }

    mkdir "${source_dir}"
    tar -xf "${archive}" -C "${source_dir}"
    mv "${state_dir}/source.manifest.incoming" "${state_dir}/source.manifest"
    find "${archive}" -delete
    printf 'source_dir=%s\nsource_archive_sha256=%s\n' "${source_dir}" "${expected_sha}"
}

stage_abort() {
    local job=$1
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    local job_root="${work_root}/${job}"
    [ ! -e "${state_dir}/policy.env" ] && [ ! -e "${state_dir}/source.manifest" ] || {
        echo "refusing to remove a completed or started stage" >&2
        exit 1
    }
    if [ -d "${job_root}" ]; then
        require_contained_path "$(realpath -e "${job_root}")" "$(realpath -e "${work_root}")"
        find "${job_root}" -depth -delete
    fi
    if [ -d "${state_dir}" ]; then
        require_contained_path "$(realpath -e "${state_dir}")" "$(realpath -e "${state_root}")"
        find "${state_dir}" -depth -delete
    fi
}

resume_stage() {
    local source_job=$1
    local destination_job=$2
    validate_job "${source_job}"
    validate_job "${destination_job}"
    [ "${source_job}" != "${destination_job}" ] || {
        echo "resume source and destination jobs must differ" >&2
        exit 2
    }
    require_worker_host

    local source_state="${state_root}/${source_job}"
    local source_root="${work_root}/${source_job}"
    local destination_state="${state_root}/${destination_job}"
    local destination_root="${work_root}/${destination_job}"
    [ -d "${source_root}/source" ] && \
        [ -f "${source_state}/stage.env" ] && \
        [ -f "${source_state}/source.manifest" ] && \
        [ -f "${source_state}/terminal.env" ] || {
        echo "resume source is not a retained terminal job: ${source_job}" >&2
        exit 1
    }
    local source_result source_reason
    if grep -qx 'result=timeout' "${source_state}/terminal.env"; then
        source_result=timeout
        source_reason="systemd stopped the job at its wall-time limit"
    elif grep -qx 'result=failure' "${source_state}/terminal.env" && \
        grep -qx 'exit_code=125' "${source_state}/terminal.env" && \
        grep -qx 'reason=health watchdog failed before readiness' \
            "${source_state}/terminal.env" && \
        grep -qx 'reason=health watchdog failed before readiness' \
            "${source_state}/watchdog-stop.env" 2>/dev/null && \
        [ ! -e "${source_state}/watchdog-ready.env" ]; then
        source_result=failure
        source_reason="health watchdog failed before readiness"
    else
        echo "resume source is not a resumable retained terminal job: ${source_job}" >&2
        exit 1
    fi
    [ -f "${source_state}/artifact-returned.env" ] || {
        echo "resume source evidence has not been returned: ${source_job}" >&2
        exit 1
    }
    [ ! -e "${destination_state}" ] && [ ! -e "${destination_root}" ] || {
        echo "resume destination already exists: ${destination_job}" >&2
        exit 1
    }

    local disk_budget_gib disk_budget_bytes workspace_bytes
    disk_budget_gib=$(awk -F= '$1 == "disk_budget_gib" { print $2 }' \
        "${source_state}/stage.env")
    disk_budget_bytes=$(awk -F= '$1 == "disk_budget_bytes" { print $2 }' \
        "${source_state}/stage.env")
    [[ "${disk_budget_gib}" =~ ^[1-9][0-9]*$ ]] && \
        [ "${disk_budget_bytes}" = "$(gib "${disk_budget_gib}")" ] || {
        echo "invalid staged disk budget for ${source_job}" >&2
        exit 1
    }
    preflight production "${disk_budget_gib}" "${source_root}" "${source_root}"
    workspace_bytes=$(disk_usage_bytes "${source_root}")

    local moved=false
    cleanup_resume_stage() {
        local result=$?
        if [ "${result}" -ne 0 ]; then
            if [ "${moved}" = true ] && [ -d "${destination_root}" ] && \
                [ ! -e "${source_root}" ]; then
                mv "${destination_root}" "${source_root}"
            fi
            if [ -d "${destination_state}" ]; then
                require_contained_path "$(realpath -e "${destination_state}")" \
                    "$(realpath -e "${state_root}")"
                find "${destination_state}" -depth -delete
            fi
        fi
        return "${result}"
    }
    trap cleanup_resume_stage EXIT

    mkdir "${destination_state}"
    cp "${source_state}/stage.env" "${destination_state}/stage.env"
    cp "${source_state}/source.manifest" "${destination_state}/source.manifest"
    mv "${source_root}" "${destination_root}"
    moved=true

    local resumed_at manifest_sha
    resumed_at=$(date --iso-8601=seconds)
    manifest_sha=$(sha256sum "${destination_state}/source.manifest" | \
        awk '{ print $1 }')
    {
        printf 'resumed_from_job=%s\n' "${source_job}"
        printf 'resumed_from_result=%s\n' "${source_result}"
        printf 'resumed_from_reason=%s\n' "${source_reason}"
        printf 'resumed_at=%s\n' "${resumed_at}"
        printf 'source_manifest_sha256=%s\n' "${manifest_sha}"
        printf 'workspace_bytes=%s\n' "${workspace_bytes}"
        printf 'disk_budget_bytes=%s\n' "${disk_budget_bytes}"
    } >"${destination_state}/resume.env"
    {
        printf 'resumed_to_job=%s\n' "${destination_job}"
        printf 'resumed_at=%s\n' "${resumed_at}"
        printf 'source_manifest_sha256=%s\n' "${manifest_sha}"
    } >"${source_state}/resumed-to.env"

    trap - EXIT
    printf 'resume_source_job=%s\nresume_destination_job=%s\nsource_dir=%s\nworkspace_bytes=%s\ndisk_budget_bytes=%s\nsource_manifest_sha256=%s\n' \
        "${source_job}" "${destination_job}" \
        "${destination_root}/source" "${workspace_bytes}" \
        "${disk_budget_bytes}" "${manifest_sha}"
}

test_prepare() {
    local job=$1
    validate_job "${job}"
    local disk_budget_gib=1
    preflight test "${disk_budget_gib}" "${work_root}"
    local state_dir="${state_root}/${job}"
    local test_dir="${work_root}/${job}/test"
    [ ! -e "${state_dir}" ] && [ ! -e "${work_root}/${job}" ] || {
        echo "job already exists: ${job}" >&2
        exit 1
    }
    mkdir -p "${state_dir}" "${test_dir}"
    printf 'profile=test\ndisk_budget_gib=%s\ndisk_budget_bytes=%s\nstaged_at=%s\n' \
        "${disk_budget_gib}" "$(gib "${disk_budget_gib}")" \
        "$(date --iso-8601=seconds)" >"${state_dir}/stage.env"
    printf '%s\n' "${test_dir}"
}

write_policy() {
    local state_dir=$1
    local profile_name=$2
    local work_dir=$3
    local disk_budget_bytes=$4
    shift 4
    local command_text
    printf -v command_text '%q ' "$@"
    local temp="${state_dir}/policy.env.tmp"
    {
        printf 'profile=%s\n' "${profile_name}"
        printf 'host=%s\n' "$(hostname -s)"
        printf 'work_dir=%s\n' "${work_dir}"
        printf 'build_jobs=%s\n' "${build_jobs}"
        printf 'cpu_quota=%s\n' "${cpu_quota}"
        printf 'cpu_weight=%s\n' "${cpu_weight}"
        printf 'memory_high=%s\n' "${memory_high}"
        printf 'memory_max=%s\n' "${memory_max}"
        printf 'memory_swap_max=0\n'
        printf 'io_weight=10\n'
        printf 'io_scheduling_class=idle\n'
        printf 'nice=15\n'
        printf 'tasks_max=%s\n' "${tasks_max}"
        printf 'disk_budget_bytes=%s\n' "${disk_budget_bytes}"
        printf 'root_floor_bytes=%s\n' "${root_floor_bytes}"
        printf 'watchdog_mem_floor_bytes=%s\n' "${watchdog_mem_floor_bytes}"
        printf 'watchdog_memory_high=%s\n' "${watchdog_memory_high}"
        printf 'watchdog_memory_max=%s\n' "${watchdog_memory_max}"
        printf 'watchdog_ready_seconds=%s\n' "${watchdog_ready_seconds}"
        printf 'supervisor_interval=%s\n' "${supervisor_interval}"
        printf 'wall_seconds=%s\n' "${wall_seconds}"
        printf 'command=%s\n' "${command_text}"
        printf 'started_at_epoch=%s\n' "$(date +%s)"
        printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${temp}"
    mv "${temp}" "${state_dir}/policy.env"
}

start_job() {
    local profile_name=$1
    local job=$2
    local work_dir=$3
    shift 3
    [ "${1:-}" = -- ] || {
        usage
        exit 2
    }
    shift
    [ "$#" -gt 0 ] || {
        echo "missing job command" >&2
        exit 2
    }
    validate_job "${job}"
    profile "${profile_name}"

    work_dir=$(realpath -e "${work_dir}")
    require_contained_path "${work_dir}" "$(realpath -e "${work_root}")"
    local job_root="${work_root}/${job}"
    job_root=$(realpath -e "${job_root}")
    require_contained_path "${job_root}" "$(realpath -e "${work_root}")"

    local state_dir="${state_root}/${job}"
    [ -f "${state_dir}/stage.env" ] || {
        echo "job is not staged: ${job}" >&2
        exit 1
    }
    local disk_budget_gib disk_budget_bytes
    disk_budget_gib=$(awk -F= '$1 == "disk_budget_gib" { print $2 }' \
        "${state_dir}/stage.env")
    disk_budget_bytes=$(awk -F= '$1 == "disk_budget_bytes" { print $2 }' \
        "${state_dir}/stage.env")
    [[ "${disk_budget_gib}" =~ ^[1-9][0-9]*$ ]] && \
        [ "${disk_budget_bytes}" = "$(gib "${disk_budget_gib}")" ] || {
        echo "invalid staged disk budget for ${job}" >&2
        exit 1
    }
    preflight "${profile_name}" "${disk_budget_gib}" "${job_root}" "${job_root}"
    [ ! -e "${state_dir}/policy.env" ] && [ ! -e "${state_dir}/result.env" ] || {
        echo "job has already been started: ${job}" >&2
        exit 1
    }

    mkdir -p "${state_root}"
    exec 9>"${state_root}/start.lock"
    flock -n 9 || {
        echo "another start operation is in progress" >&2
        exit 1
    }
    if systemctl --user --quiet is-active 'helium-job-*.service'; then
        echo "another Helium build is active" >&2
        exit 1
    fi

    local worker="${state_dir}/worker.sh"
    local unit="helium-job-${job}.service"
    local watch_unit="helium-watch-${job}.service"
    mkdir -p "${job_root}/cache" "${job_root}/tmp"
    install -m 700 "$0" "${worker}"
    write_policy "${state_dir}" "${profile_name}" "${work_dir}" \
        "${disk_budget_bytes}" "$@"

    if ! systemd-run --user --unit="${unit%.service}" --collect \
        --property="Description=Isolated Helium build ${job}" \
        --property="WorkingDirectory=${work_dir}" \
        --property="CPUQuota=${cpu_quota}" \
        --property="CPUWeight=${cpu_weight}" \
        --property="MemoryHigh=${memory_high}" \
        --property="MemoryMax=${memory_max}" \
        --property=MemorySwapMax=0 \
        --property=IOWeight=10 \
        --property=IOSchedulingClass=idle \
        --property=Nice=15 \
        --property="TasksMax=${tasks_max}" \
        --property="RuntimeMaxSec=${wall_seconds}" \
        --property=KillMode=control-group \
        --property=OOMPolicy=stop \
        --property=StandardOutput=journal \
        --property=StandardError=journal \
        --setenv="HELIUM_BUILD_JOBS=${build_jobs}" \
        --setenv="AUTONINJA_JOBS=${build_jobs}" \
        --setenv="NINJA_JOBS=${build_jobs}" \
        --setenv="GCLIENT_JOBS=${build_jobs}" \
        --setenv="XDG_CACHE_HOME=${job_root}/cache" \
        --setenv="CCACHE_DIR=${job_root}/cache/ccache" \
        --setenv="GIT_CACHE_PATH=${job_root}/cache/git" \
        --setenv="TMPDIR=${job_root}/tmp" \
        "${worker}" run "${state_dir}" "${watch_unit}" \
        "${watchdog_ready_seconds}" "${supervisor_interval}" -- "$@"; then
        echo "failed to create isolated build unit" >&2
        exit 1
    fi

    if ! systemd-run --user --unit="${watch_unit%.service}" --collect \
        --property="Description=Helium build health watchdog ${job}" \
        --property=CPUQuota=10% \
        --property=CPUWeight=10 \
        --property="MemoryHigh=${watchdog_memory_high}" \
        --property="MemoryMax=${watchdog_memory_max}" \
        --property=MemorySwapMax=0 \
        --property=IOWeight=10 \
        --property=IOSchedulingClass=idle \
        --property=Nice=15 \
        --property=TasksMax=16 \
        --property=KillMode=control-group \
        --property=OOMPolicy=stop \
        --property="RuntimeMaxSec=$((wall_seconds + 300))" \
        "${worker}" watch "${state_dir}" "${job_root}" "${unit}" \
            "${disk_budget_bytes}" "${root_floor_bytes}" \
            "${watchdog_mem_floor_bytes}" "${watchdog_interval}" \
            "${supervisor_interval}"; then
        record_watchdog_stop "${state_dir}" "health watchdog failed to start"
        systemctl --user stop "${unit}" >/dev/null 2>&1 || true
        echo "failed to create health watchdog; build stopped" >&2
        exit 1
    fi

    printf 'job=%s\nunit=%s\nwatch_unit=%s\nlogs=journalctl --user --unit=%s\nstate=%s\n' \
        "${job}" "${unit}" "${watch_unit}" "${unit}" "${state_dir}"
}

run_job() {
    local state_dir=$1
    local watch_unit=$2
    local ready_seconds=$3
    local check_interval=$4
    shift 4
    [ "${1:-}" = -- ] || exit 2
    shift
    terminal_from_signal() {
        trap - TERM INT
        local result reason exit_code
        if [ -f "${state_dir}/cancel.env" ]; then
            result=cancellation
            reason="cancelled through chromiumer-job.sh"
            exit_code=130
        elif [ -f "${state_dir}/watchdog-stop.env" ]; then
            result=failure
            reason=$(awk -F= '$1 == "reason" { print substr($0, 8); exit }' \
                "${state_dir}/watchdog-stop.env")
            exit_code=1
        else
            result=timeout
            reason="systemd stopped the job at its wall-time limit"
            exit_code=124
        fi
        write_terminal "${state_dir}" "${result}" "${exit_code}" "${reason}"
        exit "${exit_code}"
    }
    trap terminal_from_signal TERM INT

    printf 'job_started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'job_pid=%s\n' "$$"

    local ready_deadline=$((SECONDS + ready_seconds))
    while [ "${SECONDS}" -lt "${ready_deadline}" ]; do
        if [ -f "${state_dir}/cancel.env" ]; then
            stop_for_watchdog_loss "${state_dir}" "" \
                "health watchdog failed before readiness"
        fi
        if [ -f "${state_dir}/watchdog-ready.env" ] && \
            systemctl --user --quiet is-active "${watch_unit}"; then
            break
        fi
        sleep "${check_interval}"
    done
    if [ ! -f "${state_dir}/watchdog-ready.env" ] || \
        ! systemctl --user --quiet is-active "${watch_unit}"; then
        stop_for_watchdog_loss "${state_dir}" "" \
            "health watchdog failed before readiness"
    fi

    set +e
    ionice -c 3 nice -n 15 "$@" &
    local command_pid=$!
    set -e

    while kill -0 "${command_pid}" 2>/dev/null; do
        if ! systemctl --user --quiet is-active "${watch_unit}"; then
            stop_for_watchdog_loss "${state_dir}" "${command_pid}" \
                "health watchdog exited unexpectedly"
        fi
        sleep "${check_interval}"
    done

    set +e
    wait "${command_pid}"
    local result=$?
    set -e
    trap - TERM INT
    if [ "${result}" -eq 0 ]; then
        write_terminal "${state_dir}" success "${result}" "build command completed"
    else
        write_terminal "${state_dir}" failure "${result}" "build command exited non-zero"
    fi
    printf 'job_finished_at=%s\nexit_code=%s\n' "$(date --iso-8601=seconds)" "${result}"
    exit "${result}"
}

stop_for_watchdog_loss() {
    local state_dir=$1
    local command_pid=$2
    local default_reason=$3
    [ -z "${command_pid}" ] || kill -TERM "${command_pid}" 2>/dev/null || true

    if [ -f "${state_dir}/cancel.env" ]; then
        write_terminal "${state_dir}" cancellation 130 \
            "cancelled through chromiumer-job.sh"
        exit 130
    fi
    if [ -f "${state_dir}/watchdog-stop.env" ]; then
        local reason
        reason=$(awk -F= '$1 == "reason" { print substr($0, 8); exit }' \
            "${state_dir}/watchdog-stop.env")
        write_terminal "${state_dir}" failure 1 "${reason}"
        exit 1
    fi

    record_watchdog_stop "${state_dir}" "${default_reason}"
    write_terminal "${state_dir}" failure 125 "${default_reason}"
    exit 125
}

record_watchdog_stop() {
    local state_dir=$1
    local reason=$2
    local target="${state_dir}/watchdog-stop.env"
    [ ! -e "${target}" ] || return 0

    local temp="${target}.tmp.$$"
    printf 'watchdog_stopped_at=%s\nreason=%s\n' \
        "$(date --iso-8601=seconds)" "${reason}" >"${temp}"
    ln "${temp}" "${target}" 2>/dev/null || true
    find "${temp}" -delete
}

write_terminal() {
    local state_dir=$1
    local result=$2
    local exit_code=$3
    local reason=$4
    [ ! -e "${state_dir}/terminal.env" ] || return 0
    local started finished duration temp
    started=$(awk -F= '$1 == "started_at_epoch" { print $2; exit }' \
        "${state_dir}/policy.env")
    finished=$(date +%s)
    duration=$((finished - started))
    [ "${duration}" -ge 0 ] || duration=0

    temp="${state_dir}/result.env.tmp"
    {
        printf 'exit_code=%s\n' "${exit_code}"
        printf 'finished_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${temp}"
    mv "${temp}" "${state_dir}/result.env"

    temp="${state_dir}/terminal.env.tmp"
    {
        printf 'state=terminal\n'
        printf 'result=%s\n' "${result}"
        printf 'exit_code=%s\n' "${exit_code}"
        printf 'started_at_epoch=%s\n' "${started}"
        printf 'finished_at_epoch=%s\n' "${finished}"
        printf 'duration_seconds=%s\n' "${duration}"
        printf 'reason=%s\n' "${reason}"
    } >"${temp}"
    mv "${temp}" "${state_dir}/terminal.env"
}

watch_job() {
    local state_dir=$1
    local work_dir=$2
    local unit=$3
    local max_bytes=$4
    local root_floor=$5
    local mem_floor=$6
    local interval=$7
    local check_interval=$8
    local low_memory_count=0
    local scan_retry_count=0
    [[ "${interval}" =~ ^[1-9][0-9]*$ ]] && \
        [[ "${check_interval}" =~ ^[1-9][0-9]*$ ]] || exit 2

    local scan_result="${state_dir}/disk-usage.result.$$"
    local scan_error="${state_dir}/disk-usage.error.$$"
    local scan_status="${state_dir}/disk-usage.status.$$"
    local scan_status_temp="${scan_status}.tmp"
    local scan_retry="${state_dir}/disk-scan-retry.env"
    local scan_retry_error="${state_dir}/disk-scan-first-error.log"
    local scan_pid=''
    local next_scan_at=0

    cleanup_scan() {
        trap - EXIT TERM INT
        if [ -n "${scan_pid}" ] && kill -0 "${scan_pid}" 2>/dev/null; then
            kill -TERM "${scan_pid}" 2>/dev/null || true
            wait "${scan_pid}" 2>/dev/null || true
        fi
        find "${scan_result}" "${scan_error}" "${scan_status}" \
            "${scan_status_temp}" -delete 2>/dev/null || true
    }
    trap cleanup_scan EXIT
    trap 'exit 143' TERM INT

    start_scan() {
        find "${scan_result}" "${scan_error}" "${scan_status}" \
            "${scan_status_temp}" -delete 2>/dev/null || true
        (
            set +e
            disk_usage_bytes "${work_dir}" >"${scan_result}" 2>"${scan_error}"
            local result=$?
            printf '%s\n' "${result}" >"${scan_status_temp}"
            mv "${scan_status_temp}" "${scan_status}"
            exit "${result}"
        ) &
        scan_pid=$!
    }

    fail_watchdog() {
        local reason=$1
        record_watchdog_stop "${state_dir}" "${reason}"
        systemctl --user stop "${unit}" >/dev/null 2>&1 || true
        exit 1
    }

    report_scan_error() {
        [ ! -s "${scan_error}" ] || \
            sed 's/^/disk usage scan: /' "${scan_error}" >&2
    }

    record_scan_retry() {
        local result=$1
        local reason=$2
        [ "${scan_retry_count}" -eq 0 ] || return 1
        scan_retry_count=1

        local retry_temp="${scan_retry}.tmp"
        local retry_error_temp="${scan_retry_error}.tmp"
        install -m 600 "${scan_error}" "${retry_error_temp}"
        {
            printf 'retried_at=%s\n' "$(date --iso-8601=seconds)"
            printf 'exit_code=%s\n' "${result}"
            printf 'reason=%s\n' "${reason}"
            printf 'first_diagnostic=disk-scan-first-error.log\n'
        } >"${retry_temp}"
        mv "${retry_error_temp}" "${scan_retry_error}"
        mv "${retry_temp}" "${scan_retry}"
        find "${scan_result}" "${scan_error}" "${scan_status}" \
            -delete 2>/dev/null || true
        scan_pid=
        next_scan_at=${SECONDS}
    }

    while systemctl --user --quiet is-active "${unit}"; do
        local available root_available memory_available load used result
        if ! available=$(df -PB1 "${work_dir}" | awk 'NR == 2 { print $4 }') || \
            [[ ! "${available}" =~ ^[0-9]+$ ]]; then
            fail_watchdog "build filesystem availability check failed"
        fi
        if ! root_available=$(df -PB1 / | awk 'NR == 2 { print $4 }') || \
            [[ ! "${root_available}" =~ ^[0-9]+$ ]]; then
            fail_watchdog "root filesystem availability check failed"
        fi
        if ! memory_available=$(meminfo_bytes MemAvailable) || \
            [[ ! "${memory_available}" =~ ^[0-9]+$ ]]; then
            fail_watchdog "host available-memory check failed"
        fi

        if [ "${root_available}" -lt "${root_floor}" ]; then
            fail_watchdog "root free-space floor breached"
        fi
        if [ "${memory_available}" -lt "${mem_floor}" ]; then
            low_memory_count=$((low_memory_count + 1))
            if [ "${low_memory_count}" -ge 2 ]; then
                fail_watchdog "host available-memory floor breached"
            fi
        else
            low_memory_count=0
        fi

        if [ -z "${scan_pid}" ] && [ "${SECONDS}" -ge "${next_scan_at}" ]; then
            start_scan
        fi

        if [ ! -e "${state_dir}/watchdog-ready.env" ]; then
            printf 'watchdog_ready_at=%s\ninitial_disk_scan=running\n' \
                "$(date --iso-8601=seconds)" \
                >"${state_dir}/watchdog-ready.env.tmp"
            mv "${state_dir}/watchdog-ready.env.tmp" \
                "${state_dir}/watchdog-ready.env"
        fi

        if [ -n "${scan_pid}" ] && [ ! -f "${scan_status}" ] && \
            ! kill -0 "${scan_pid}" 2>/dev/null; then
            local wait_result
            if wait "${scan_pid}" 2>/dev/null; then
                wait_result=0
            else
                wait_result=$?
            fi
            report_scan_error
            if record_scan_retry "${wait_result}" \
                "disk usage scan exited before publishing status"; then
                continue
            fi
            fail_watchdog "disk usage scan repeatedly failed"
        fi
        if [ -n "${scan_pid}" ] && [ -f "${scan_status}" ]; then
            result=$(<"${scan_status}")
            if wait "${scan_pid}"; then
                [ "${result}" = 0 ] || fail_watchdog \
                    "disk usage scan status was inconsistent"
            else
                local wait_result=$?
                [ "${result}" = "${wait_result}" ] || fail_watchdog \
                    "disk usage scan status was inconsistent"
                report_scan_error
                if record_scan_retry "${result}" \
                    "disk usage scan failure"; then
                    continue
                fi
                fail_watchdog "disk usage scan repeatedly failed"
            fi
            scan_pid=
            scan_retry_count=0
            used=$(<"${scan_result}")
            [[ "${used}" =~ ^[0-9]+$ ]] || fail_watchdog \
                "disk usage scan produced invalid output"
            if [ "${used}" -gt "${max_bytes}" ]; then
                fail_watchdog "job disk budget breached"
            fi

            load=$(cut -d' ' -f1-3 /proc/loadavg)
            local temp="${state_dir}/health.env.tmp"
            {
                printf 'checked_at=%s\n' "$(date --iso-8601=seconds)"
                printf 'unit=%s\n' "${unit}"
                printf 'build_available_bytes=%s\n' "${available}"
                printf 'root_available_bytes=%s\n' "${root_available}"
                printf 'workspace_bytes=%s\n' "${used}"
                printf 'disk_budget_bytes=%s\n' "${max_bytes}"
                printf 'root_floor_bytes=%s\n' "${root_floor}"
                printf 'memory_available_bytes=%s\n' "${memory_available}"
                printf 'load_average=%s\n' "${load}"
                printf 'status=ok\n'
            } >"${temp}"
            mv "${temp}" "${state_dir}/health.env"

            find "${scan_result}" "${scan_error}" "${scan_status}" -delete
            next_scan_at=$((SECONDS + interval))
        fi
        sleep "${check_interval}"
    done
    cleanup_scan
}

status_job() {
    local job=$1
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    local unit="helium-job-${job}.service"
    [ -d "${state_dir}" ] || {
        echo "unknown job: ${job}" >&2
        exit 1
    }
    local watch_unit="helium-watch-${job}.service"
    printf 'job=%s\nunit_state=%s\nwatch_unit_state=%s\nstate_dir=%s\nlogs=journalctl --user --unit=%s\n' \
        "${job}" "$(systemctl --user is-active "${unit}" 2>/dev/null || true)" \
        "$(systemctl --user is-active "${watch_unit}" 2>/dev/null || true)" \
        "${state_dir}" "${unit}"
    for file in policy.env resume.env resumed-to.env watchdog-ready.env \
        health.env disk-scan-retry.env result.env terminal.env \
        watchdog-stop.env cancel.env; do
        if [ -f "${state_dir}/${file}" ]; then
            printf -- '--- %s ---\n' "${file}"
            cat "${state_dir}/${file}"
        fi
    done
    if [ -f "${state_dir}/disk-scan-first-error.log" ]; then
        printf '%s\n' '--- disk-scan-first-error.log ---'
        sed 's/^/disk usage scan: /' \
            "${state_dir}/disk-scan-first-error.log"
    fi
}

limits_job() {
    local job=$1
    validate_job "${job}"
    printf '%s\n' '--- build unit ---'
    systemctl --user show "helium-job-${job}.service" \
        -p ActiveState -p CPUQuotaPerSecUSec -p CPUWeight \
        -p MemoryHigh -p MemoryMax -p MemorySwapMax -p IOWeight \
        -p IOSchedulingClass -p Nice -p TasksMax -p RuntimeMaxUSec
    printf '%s\n' '--- watchdog unit ---'
    systemctl --user show "helium-watch-${job}.service" \
        -p ActiveState -p CPUQuotaPerSecUSec -p CPUWeight \
        -p MemoryHigh -p MemoryMax -p MemorySwapMax -p IOWeight \
        -p IOSchedulingClass -p Nice -p TasksMax -p RuntimeMaxUSec
}

logs_job() {
    local job=$1
    local lines=${2:-80}
    validate_job "${job}"
    [[ "${lines}" =~ ^[1-9][0-9]{0,3}$ ]] || exit 2
    journalctl --user --unit="helium-job-${job}.service" \
        --no-pager --output=cat --lines="${lines}"
}

cancel_job() {
    local job=$1
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    [ -d "${state_dir}" ] || {
        echo "unknown job: ${job}" >&2
        exit 1
    }
    if [ -f "${state_dir}/terminal.env" ]; then
        echo "job is already terminal: ${job}" >&2
        exit 1
    fi
    systemctl --user --quiet is-active "helium-job-${job}.service" || {
        echo "job is not active and has no terminal state: ${job}" >&2
        exit 1
    }
    printf 'cancelled_at=%s\n' "$(date --iso-8601=seconds)" >"${state_dir}/cancel.env"
    systemctl --user stop "helium-watch-${job}.service" >/dev/null 2>&1 || true
    systemctl --user stop "helium-job-${job}.service" >/dev/null 2>&1 || true
    printf 'cancelled=%s\n' "${job}"
}

terminal_job() {
    local job=$1
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    local unit="helium-job-${job}.service"
    [ -d "${state_dir}" ] || {
        echo "unknown job: ${job}" >&2
        exit 1
    }
    if [ -f "${state_dir}/terminal.env" ]; then
        cat "${state_dir}/terminal.env"
    elif systemctl --user --quiet is-active "${unit}"; then
        printf 'state=running\n'
    elif [ -f "${state_dir}/policy.env" ]; then
        printf 'state=finishing\n'
    else
        printf 'state=staged\n'
    fi
}

source_info() {
    local job=$1
    validate_job "${job}"
    local manifest="${state_root}/${job}/source.manifest"
    [ -f "${manifest}" ] || {
        echo "job has no completed source manifest: ${job}" >&2
        exit 1
    }
    awk -F= '$1 == "repository" || $1 == "commit" || $1 == "tree" ||
        $1 == "helium_submodule" || $1 == "chromium_version" ||
        $1 == "HELIUM_ANDROID_CHROMIUM_COMMIT" ||
        $1 == "HELIUM_ANDROID_CORE_COMMIT" ||
        $1 == "HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" { print }' "${manifest}"
}

artifact_info() {
    local job=$1
    local relative=$2
    validate_job "${job}"
    [[ "${relative}" != /* && "${relative}" != *..* ]] || {
        echo "artifact path must be a contained relative path" >&2
        exit 2
    }
    local source_root="${work_root}/${job}/source"
    local artifact
    artifact=$(realpath -e "${source_root}/${relative}")
    require_contained_path "${artifact}" "$(realpath -e "${source_root}")"
    [ -f "${artifact}" ] || {
        echo "artifact must be one regular file; package directories first" >&2
        exit 1
    }
    printf 'path=%s\nsha256=%s\nsize_bytes=%s\n' \
        "${artifact}" "$(sha256sum "${artifact}" | awk '{ print $1 }')" \
        "$(stat -c %s "${artifact}")"
}

mark_returned() {
    local job=$1
    local sha=$2
    validate_job "${job}"
    printf 'returned_at=%s\nsha256=%s\n' "$(date --iso-8601=seconds)" "${sha}" \
        >"${state_root}/${job}/artifact-returned.env"
}

cleanup_job() {
    local job=$1
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    local job_root="${work_root}/${job}"
    ! systemctl --user --quiet is-active "helium-job-${job}.service" || {
        echo "refusing cleanup while job is active" >&2
        exit 1
    }
    if ! grep -qx 'profile=test' "${state_dir}/stage.env" 2>/dev/null && \
        [ ! -f "${state_dir}/artifact-returned.env" ]; then
        echo "refusing cleanup until an artifact return receipt exists" >&2
        exit 1
    fi
    if [ -d "${job_root}" ]; then
        require_contained_path "$(realpath -e "${job_root}")" "$(realpath -e "${work_root}")"
        find "${job_root}" -depth -delete
    fi
    printf 'workspace_cleaned_at=%s\n' "$(date --iso-8601=seconds)" \
        >"${state_dir}/cleanup.env"
    printf 'workspace_cleaned=%s\nstate_retained=%s\n' "${job_root}" "${state_dir}"
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

command=${1:-}
shift || true
case "${command}" in
    preflight) preflight "$@" ;;
    stage-init) stage_init "$@" ;;
    stage-finish) stage_finish "$@" ;;
    stage-abort) stage_abort "$@" ;;
    resume-stage) resume_stage "$@" ;;
    test-prepare) test_prepare "$@" ;;
    start) start_job "$@" ;;
    run) run_job "$@" ;;
    watch) watch_job "$@" ;;
    status) status_job "$@" ;;
    limits) limits_job "$@" ;;
    logs) logs_job "$@" ;;
    cancel) cancel_job "$@" ;;
    terminal) terminal_job "$@" ;;
    source-info) source_info "$@" ;;
    artifact-info) artifact_info "$@" ;;
    mark-returned) mark_returned "$@" ;;
    cleanup) cleanup_job "$@" ;;
    *) usage; exit 2 ;;
esac
