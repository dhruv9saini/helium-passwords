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
    du -sx -B1 "$1" | awk '{ print $1 }'
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

    local required=(awk df du find flock install ionice journalctl nice realpath sha256sum stat systemctl systemd-run tar timeout)
    local tool
    for tool in "${required[@]}"; do
        command -v "${tool}" >/dev/null 2>&1 || {
            echo "preflight failed: missing tool: ${tool}" >&2
            return 1
        }
    done

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
        "${worker}" run "${state_dir}" -- "$@"; then
        echo "failed to create isolated build unit" >&2
        exit 1
    fi

    if ! systemd-run --user --unit="${watch_unit%.service}" --collect \
        --property="Description=Helium build health watchdog ${job}" \
        --property=CPUQuota=10% \
        --property=MemoryMax=64M \
        --property=TasksMax=16 \
        --property="RuntimeMaxSec=$((wall_seconds + 300))" \
        "${worker}" watch "${state_dir}" "${job_root}" "${unit}" \
        "${disk_budget_bytes}" "${root_floor_bytes}" \
        "${watchdog_mem_floor_bytes}" "${watchdog_interval}"; then
        systemctl --user stop "${unit}" >/dev/null 2>&1 || true
        echo "failed to create health watchdog; build stopped" >&2
        exit 1
    fi

    printf 'job=%s\nunit=%s\nwatch_unit=%s\nlogs=journalctl --user --unit=%s\nstate=%s\n' \
        "${job}" "${unit}" "${watch_unit}" "${unit}" "${state_dir}"
}

run_job() {
    local state_dir=$1
    shift
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
    set +e
    ionice -c 3 nice -n 15 "$@"
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
    local low_memory_count=0

    while systemctl --user --quiet is-active "${unit}"; do
        local available root_available used memory_available load failure
        available=$(df -PB1 "${work_dir}" | awk 'NR == 2 { print $4 }')
        root_available=$(df -PB1 / | awk 'NR == 2 { print $4 }')
        used=$(disk_usage_bytes "${work_dir}")
        memory_available=$(meminfo_bytes MemAvailable)
        load=$(cut -d' ' -f1-3 /proc/loadavg)
        failure=

        if [ "${used}" -gt "${max_bytes}" ]; then
            failure="job disk budget breached"
        elif [ "${root_available}" -lt "${root_floor}" ]; then
            failure="root free-space floor breached"
        elif [ "${memory_available}" -lt "${mem_floor}" ]; then
            low_memory_count=$((low_memory_count + 1))
            if [ "${low_memory_count}" -ge 2 ]; then
                failure="host available-memory floor breached"
            fi
        else
            low_memory_count=0
        fi

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
            printf 'status=%s\n' "${failure:-ok}"
        } >"${temp}"
        mv "${temp}" "${state_dir}/health.env"

        if [ -n "${failure}" ]; then
            printf 'watchdog_stopped_at=%s\nreason=%s\n' \
                "$(date --iso-8601=seconds)" "${failure}" \
                >"${state_dir}/watchdog-stop.env"
            systemctl --user stop "${unit}"
            exit 1
        fi
        sleep "${interval}"
    done
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
    printf 'job=%s\nunit_state=%s\nstate_dir=%s\nlogs=journalctl --user --unit=%s\n' \
        "${job}" "$(systemctl --user is-active "${unit}" 2>/dev/null || true)" \
        "${state_dir}" "${unit}"
    for file in policy.env health.env result.env terminal.env watchdog-stop.env cancel.env; do
        if [ -f "${state_dir}/${file}" ]; then
            printf -- '--- %s ---\n' "${file}"
            cat "${state_dir}/${file}"
        fi
    done
}

limits_job() {
    local job=$1
    validate_job "${job}"
    systemctl --user show "helium-job-${job}.service" \
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
