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

validate_owner() {
    [[ "$1" =~ ^/[a-z0-9][a-z0-9_/-]{0,94}$ ]] || {
        echo "invalid job owner: $1" >&2
        exit 2
    }
}

validate_generation() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{7,127}$ ]] || {
        echo "invalid job generation: $1" >&2
        exit 2
    }
}

gib() {
    printf '%s\n' "$(( $1 * 1024 * 1024 * 1024 ))"
}

profile() {
    case "$1" in
        production)
            build_jobs=1
            cpu_quota=200%
            cpu_weight=10
            memory_high=4G
            memory_max=5G
            memory_swap_max=0
            tasks_max=1024
            min_mem_total_bytes=$(gib 7)
            min_mem_available_bytes=$(gib 2)
            watchdog_mem_floor_bytes=$(gib 1)
            wall_seconds=28800
            wall_class='standard'
            watchdog_interval=30
            watchdog_memory_high=64M
            watchdog_memory_max=128M
            watchdog_ready_seconds=600
            supervisor_interval=1
            ;;
        test)
            build_jobs=1
            cpu_quota=50%
            cpu_weight=10
            memory_high=128M
            memory_max=256M
            memory_swap_max=0
            tasks_max=32
            min_mem_total_bytes=$(gib 1)
            min_mem_available_bytes=$((256 * 1024 * 1024))
            watchdog_mem_floor_bytes=$((64 * 1024 * 1024))
            wall_seconds=120
            wall_class='test'
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

transient_descendant_disappearance() {
    local diagnostic=$1
    local root=$2
    [ -d "${root}" ] && [ -s "${diagnostic}" ] || return 1

    local line
    local prefix="find: '${root}/"
    local suffix="': No such file or directory"
    while IFS= read -r line; do
        [[ "${line}" == "${prefix}"*"${suffix}" ]] || return 1
    done <"${diagnostic}"
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

exact_value() {
    local file=$1
    local key=$2
    [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count += 1
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1 || value == "") {
                exit 1
            }
            print value
        }
    ' "${file}"
}

require_job_ownership() {
    local job=$1
    local owner=${2:-}
    local generation=${3:-}
    local lease="${state_root}/${job}/owner.env"
    [ -e "${lease}" ] || [ -L "${lease}" ] || return 0
    [ -f "${lease}" ] && [ ! -L "${lease}" ] || {
        echo "invalid job ownership record: ${job}" >&2
        exit 1
    }
    local expected_job expected_owner expected_generation
    expected_job=$(exact_value "${lease}" job)
    expected_owner=$(exact_value "${lease}" owner)
    expected_generation=$(exact_value "${lease}" generation)
    [ "${expected_job}" = "${job}" ] || {
        echo "job ownership record targets another job: ${job}" >&2
        exit 1
    }
    validate_owner "${expected_owner}"
    validate_generation "${expected_generation}"
    [ "${owner}" = "${expected_owner}" ] && \
        [ "${generation}" = "${expected_generation}" ] || {
        echo "job ownership mismatch: ${job}" >&2
        exit 1
    }
}

claim_job_ownership() {
    local job=$1
    local owner=$2
    local generation=$3
    validate_job "${job}"
    validate_owner "${owner}"
    validate_generation "${generation}"
    local state_dir="${state_root}/${job}"
    [ -d "${state_dir}" ] && [ ! -L "${state_dir}" ] || {
        echo "unknown or unsafe job state: ${job}" >&2
        exit 1
    }
    local lease="${state_dir}/owner.env"
    if [ -e "${lease}" ]; then
        require_job_ownership "${job}" "${owner}" "${generation}"
        printf 'claimed=%s\nexisting=true\nowner=%s\ngeneration=%s\n' \
            "${job}" "${owner}" "${generation}"
        return
    fi
    local temp="${lease}.tmp.$$"
    {
        printf 'job=%s\n' "${job}"
        printf 'owner=%s\n' "${owner}"
        printf 'generation=%s\n' "${generation}"
        printf 'claimed_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${temp}"
    mv "${temp}" "${lease}"
    printf 'claimed=%s\nexisting=false\nowner=%s\ngeneration=%s\n' \
        "${job}" "${owner}" "${generation}"
}

command_text() {
    local text
    printf -v text '%q ' "$@"
    printf '%s\n' "${text}"
}

continuation_command_mode() {
    local parent_command=$1
    local requested_command=$2
    if [ "${requested_command}" = "${parent_command}" ]; then
        printf 'exact\n'
        return
    fi

    local marker='AUTONINJA_JOBS=2 '
    local suffix=${parent_command#*"${marker}"}
    if [ "${suffix}" != "${parent_command}" ] && \
        [[ "${suffix}" != *"${marker}"* ]] && \
        [ "${requested_command}" = \
            "${parent_command/"${marker}"/AUTONINJA_JOBS=1 }" ]; then
        printf 'reduced-parallelism\n'
        return
    fi

    marker='CHROMIUM_ANDROID_PHASE=all '
    suffix=${parent_command#*"${marker}"}
    if [ "${suffix}" != "${parent_command}" ] && \
        [[ "${suffix}" != *"${marker}"* ]] && \
        [ "${requested_command}" = \
            "${parent_command/"${marker}"/CHROMIUM_ANDROID_PHASE=build }" ]; then
        printf 'retained-build\n'
        return
    fi

    marker='HELIUM_LINUX_PHASE=fresh '
    suffix=${parent_command#*"${marker}"}
    [ "${suffix}" != "${parent_command}" ] && \
        [[ "${suffix}" != *"${marker}"* ]] && \
        [ "${requested_command}" = \
            "${parent_command/"${marker}"/HELIUM_LINUX_PHASE=retained }" ] ||
        return 1
    printf 'retained-linux-build\n'
}

workspace_owner() {
    local job=$1
    validate_job "${job}"
    local stage="${state_root}/${job}/stage.env"
    [ -f "${stage}" ] || return 1

    local count owner
    count=$(awk '$0 ~ /^workspace_owner=/ { count += 1 } END { print count + 0 }' \
        "${stage}")
    case "${count}" in
        0) owner=${job} ;;
        1) owner=$(exact_value "${stage}" workspace_owner) ;;
        *) return 1 ;;
    esac
    validate_job "${owner}"
    printf '%s\n' "${owner}"
}

validate_source_manifest() {
    local manifest=$1
    local value
    for key in repository origin commit tree helium_submodule chromium_version \
        archive_sha256 transferred_at transferred_from; do
        value=$(exact_value "${manifest}" "${key}") || {
            echo "incomplete source provenance: missing or duplicate ${key}" >&2
            return 1
        }
        case "${key}" in
            commit|tree|helium_submodule)
                [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || {
                    echo "invalid source provenance: ${key}" >&2
                    return 1
                }
                ;;
            archive_sha256)
                [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || {
                    echo "invalid source provenance: ${key}" >&2
                    return 1
                }
                ;;
        esac
    done
}

continuation_parent() {
    local job=$1
    local resume="${state_root}/${job}/resume.env"
    [ -f "${resume}" ] || return 1
    local parent
    parent=$(exact_value "${resume}" parent_job)
    validate_job "${parent}"
    printf '%s\n' "${parent}"
}

source_build_jobs() {
    local job=$1
    validate_job "${job}"
    local resume="${state_root}/${job}/resume.env"
    local value parent
    if [ -f "${resume}" ] && grep -q '^source_build_jobs=' "${resume}"; then
        value=$(exact_value "${resume}" source_build_jobs) || return 1
    elif [ -f "${resume}" ]; then
        parent=$(continuation_parent "${job}") || return 1
        value=$(exact_value "${state_root}/${parent}/policy.env" build_jobs) ||
            return 1
    else
        value=$(exact_value "${state_root}/${job}/policy.env" build_jobs) ||
            return 1
    fi
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "${value}"
}

retained_linux_swap_recovery_parent() {
    local parent=$1
    local requested_command=$2
    local parent_state="${state_root}/${parent}"
    local terminal="${parent_state}/terminal.env"
    local watchdog_stop="${parent_state}/watchdog-stop.env"
    local policy="${parent_state}/policy.env"
    local resume="${parent_state}/resume.env"
    local marker='HELIUM_LINUX_PHASE=retained '
    local suffix

    [ -f "${resume}" ] && [ ! -L "${resume}" ] && \
        [ -f "${watchdog_stop}" ] && [ ! -L "${watchdog_stop}" ] ||
        return 1
    [ "$(exact_value "${terminal}" state)" = terminal ] && \
        [ "$(exact_value "${terminal}" result)" = failure ] && \
        [ "$(exact_value "${terminal}" exit_code)" = 1 ] && \
        [ "$(exact_value "${terminal}" reason)" = \
            "host available-memory floor breached" ] && \
        [ "$(exact_value "${watchdog_stop}" reason)" = \
            "host available-memory floor breached" ] || return 1
    [ "$(exact_value "${policy}" profile)" = production ] && \
        [ "$(exact_value "${policy}" command)" = "${requested_command}" ] && \
        [ "$(exact_value "${policy}" build_jobs)" = 1 ] && \
        [ "$(source_build_jobs "${parent}")" = 1 ] && \
        [ "$(exact_value "${policy}" memory_high)" = 4G ] && \
        [ "$(exact_value "${policy}" memory_max)" = 5G ] && \
        [ "$(exact_value "${policy}" memory_swap_max)" = 0 ] && \
        [ "$(exact_value "${policy}" wall_seconds)" = 28800 ] && \
        [ "$(exact_value "${policy}" wall_class)" = standard ] && \
        [ "$(exact_value "${resume}" command_mode)" = exact ] && \
        [ "$(exact_value "${resume}" parent_terminal_mode)" = timeout ] ||
        return 1

    suffix=${requested_command#*"${marker}"}
    [ "${suffix}" != "${requested_command}" ] && \
        [[ "${suffix}" != *"${marker}"* ]]
}

validate_continuation_state() {
    local child=$1
    shift
    validate_job "${child}"
    local child_state="${state_root}/${child}"
    local parent owner manifest_sha actual_sha parent_command requested_command
    local command_mode expected_source_build_jobs
    [ -d "${child_state}" ] && [ ! -L "${child_state}" ] || return 1
    parent=$(continuation_parent "${child}") || return 1
    owner=$(workspace_owner "${child}") || return 1
    parent_command=$(exact_value \
        "${state_root}/${parent}/policy.env" command) || return 1
    requested_command=$(command_text "$@")
    command_mode=$(continuation_command_mode \
        "${parent_command}" "${requested_command}") || return 1
    [ "$(exact_value "${child_state}/resume.env" workspace_owner)" = \
        "${owner}" ] && \
        [ "$(exact_value "${child_state}/resume.env" command)" = \
            "${requested_command}" ] && \
        [ "$(exact_value "${child_state}/resume.env" parent_command)" = \
            "${parent_command}" ] && \
        [ "$(exact_value "${child_state}/resume.env" command_mode)" = \
            "${command_mode}" ] && \
        [ "$(exact_value "${state_root}/${parent}/continued-by.env" child_job)" = \
            "${child}" ] && \
        [ "$(exact_value "${state_root}/${parent}/continued-by.env" workspace_owner)" = \
            "${owner}" ] || return 1
    expected_source_build_jobs=$(source_build_jobs "${parent}") || return 1
    [ "$(exact_value "${child_state}/resume.env" source_build_jobs)" = \
        "${expected_source_build_jobs}" ] || return 1

    manifest_sha=$(exact_value "${child_state}/resume.env" \
        source_manifest_sha256) || return 1
    [[ "${manifest_sha}" =~ ^[0-9a-f]{64}$ ]] || return 1
    validate_source_manifest "${child_state}/source.manifest" || return 1
    validate_source_manifest "${state_root}/${owner}/source.manifest" || return 1
    actual_sha=$(sha256sum "${child_state}/source.manifest" |
        awk '{ print $1 }')
    [ "${actual_sha}" = "${manifest_sha}" ] && \
        cmp --silent "${child_state}/source.manifest" \
            "${state_root}/${owner}/source.manifest" || return 1
    local parent_terminal_mode
    parent_terminal_mode=$(exact_value "${child_state}/resume.env" \
        parent_terminal_mode) || return 1
    if [ -e "${state_root}/${parent}/watchdog-stop.env" ]; then
        [ "${parent_terminal_mode}" = retained-linux-final-link-swap-recovery ] && \
            retained_linux_swap_recovery_parent \
                "${parent}" "${requested_command}" || return 1
    else
        [ "${parent_terminal_mode}" != \
            retained-linux-final-link-swap-recovery ] || return 1
    fi
    [ ! -e "${state_root}/${parent}/cancel.env" ] && \
        [ ! -e "${state_root}/${parent}/cleanup.env" ] && \
        [ ! -e "${state_root}/${owner}/workspace-cleaned-by.env" ] || return 1

    continuation_state_parent=${parent}
    continuation_state_owner=${owner}
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

    local required=(awk cmp df find flock grep install ionice journalctl ln nice
        realpath sed sha256sum stat systemctl systemd-run tar timeout)
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
    printf 'profile=production\ndisk_budget_gib=%s\ndisk_budget_bytes=%s\nworkspace_owner=%s\nstaged_at=%s\n' \
        "${disk_budget_gib}" "$(gib "${disk_budget_gib}")" "${job}" \
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
    printf 'profile=test\ndisk_budget_gib=%s\ndisk_budget_bytes=%s\nworkspace_owner=%s\nstaged_at=%s\n' \
        "${disk_budget_gib}" "$(gib "${disk_budget_gib}")" "${job}" \
        "$(date --iso-8601=seconds)" >"${state_dir}/stage.env"
    printf '%s\n' "${test_dir}"
}

validate_resume_parent() {
    local parent=$1
    local child=$2
    shift 2
    validate_job "${parent}"
    validate_job "${child}"
    [ "${parent}" != "${child}" ] || {
        echo "continuation job id must differ from its parent" >&2
        return 1
    }

    local parent_state="${state_root}/${parent}"
    local terminal="${parent_state}/terminal.env"
    local stage="${parent_state}/stage.env"
    local policy="${parent_state}/policy.env"
    [ -d "${parent_state}" ] && [ ! -L "${parent_state}" ] || {
        echo "unknown continuation parent: ${parent}" >&2
        return 1
    }
    [ "$(exact_value "${stage}" profile)" = production ] && \
        [ "$(exact_value "${policy}" profile)" = production ] || {
        echo "only production jobs can be continued" >&2
        return 1
    }

    local expected_command requested_command command_mode
    expected_command=$(exact_value "${policy}" command)
    requested_command=$(command_text "$@")
    command_mode=$(continuation_command_mode \
        "${expected_command}" "${requested_command}") || {
        echo "continuation command must match its parent, only reduce AUTONINJA_JOBS from 2 to 1, change CHROMIUM_ANDROID_PHASE from all to build, or change HELIUM_LINUX_PHASE from fresh to retained" >&2
        return 1
    }

    local terminal_mode=timeout
    if [ "$(exact_value "${terminal}" state)" = terminal ] && \
        [ "$(exact_value "${terminal}" result)" = timeout ] && \
        [ "$(exact_value "${terminal}" exit_code)" = 124 ] && \
        [ "$(exact_value "${terminal}" reason)" = \
            "systemd stopped the job at its wall-time limit" ]; then
        :
    elif retained_linux_swap_recovery_parent \
        "${parent}" "${requested_command}"; then
        [ "${command_mode}" = exact ] || {
            echo "retained Linux swap recovery requires the exact parent command" >&2
            return 1
        }
        terminal_mode=retained-linux-final-link-swap-recovery
    else
        [ "$(exact_value "${terminal}" state)" = terminal ] && \
            [ "$(exact_value "${terminal}" result)" = failure ] && \
            [ "$(exact_value "${terminal}" exit_code)" = 1 ] && \
            [ "$(exact_value "${terminal}" reason)" = \
                "build command exited non-zero" ] && \
            [ -f "${parent_state}/resume.env" ] || {
            echo "continuation parent is neither an exact timeout nor an admitted entry-gate failure" >&2
            return 1
        }

        local finished_at ready_at ready_epoch current_jobs source_jobs
        local parent_command_mode parent_terminal_mode elapsed
        current_jobs=$(exact_value "${policy}" build_jobs) || return 1
        source_jobs=$(source_build_jobs "${parent}") || return 1
        parent_command_mode=$(exact_value \
            "${parent_state}/resume.env" command_mode) || return 1
        parent_terminal_mode=$(exact_value \
            "${parent_state}/resume.env" parent_terminal_mode) || return 1
        finished_at=$(exact_value "${terminal}" finished_at_epoch) || return 1
        ready_at=$(exact_value "${parent_state}/watchdog-ready.env" \
            watchdog_ready_at) || return 1
        [[ "${finished_at}" =~ ^[0-9]+$ ]] || return 1
        ready_epoch=$(date --date="${ready_at}" +%s) || return 1
        [ "${finished_at}" -ge "${ready_epoch}" ] || return 1
        elapsed=$((finished_at - ready_epoch))

        if [ "${command_mode}" = retained-build ] && \
            [ "${parent_command_mode}" = exact ] && \
            [ "${parent_terminal_mode}" = timeout ] && \
            [ "${current_jobs}" = 1 ] && [ "${source_jobs}" = 1 ] && \
            [ "${elapsed}" -le 30 ]; then
            terminal_mode=retained-build-retry
        else
            terminal_mode=source-policy-retry
            [ "${parent_command_mode}" = reduced-parallelism ] && \
                [ "${current_jobs}" = 1 ] && [ "${source_jobs}" = 2 ] || {
                echo "failed continuation is not an admitted source-policy or retained-build entry-gate failure" >&2
                return 1
            }
            [ "${elapsed}" -le 5 ] || {
                echo "failed continuation advanced beyond the source-policy entry gate" >&2
                return 1
            }
        fi
    fi
    local staged_budget_gib staged_budget_bytes policy_budget_bytes
    staged_budget_gib=$(exact_value "${stage}" disk_budget_gib)
    staged_budget_bytes=$(exact_value "${stage}" disk_budget_bytes)
    policy_budget_bytes=$(exact_value "${policy}" disk_budget_bytes)
    [[ "${staged_budget_gib}" =~ ^[1-9][0-9]*$ ]] && \
        [ "${staged_budget_bytes}" = "$(gib "${staged_budget_gib}")" ] && \
        [ "${policy_budget_bytes}" = "${staged_budget_bytes}" ] || {
        echo "continuation parent has inconsistent disk-budget provenance" >&2
        return 1
    }

    local owner
    owner=$(workspace_owner "${parent}") || {
        echo "continuation parent has invalid workspace ownership" >&2
        return 1
    }
    [ "${child}" != "${owner}" ] || {
        echo "continuation job id conflicts with workspace owner" >&2
        return 1
    }
    local owner_state="${state_root}/${owner}"
    local job_root="${work_root}/${owner}"
    local source_dir="${job_root}/source"
    [ -d "${job_root}" ] && [ ! -L "${job_root}" ] && \
        [ -d "${source_dir}" ] && [ ! -L "${source_dir}" ] || {
        echo "continuation workspace is missing or unsafe" >&2
        return 1
    }
    job_root=$(realpath -e "${job_root}")
    source_dir=$(realpath -e "${source_dir}")
    require_contained_path "${job_root}" "$(realpath -e "${work_root}")"
    require_contained_path "${source_dir}" "${job_root}"

    validate_source_manifest "${parent_state}/source.manifest" || return 1
    [ -d "${owner_state}" ] && [ ! -L "${owner_state}" ] && \
        validate_source_manifest "${owner_state}/source.manifest" && \
        cmp --silent "${parent_state}/source.manifest" \
            "${owner_state}/source.manifest" || {
        echo "continuation source provenance differs from its workspace owner" >&2
        return 1
    }
    for forbidden in watchdog-stop.env cancel.env cleanup.env continued-by.env; do
        if [ "${forbidden}" = watchdog-stop.env ] && \
            [ "${terminal_mode}" = \
                retained-linux-final-link-swap-recovery ]; then
            continue
        fi
        [ ! -e "${parent_state}/${forbidden}" ] || {
            echo "continuation parent has disqualifying state: ${forbidden}" >&2
            return 1
        }
    done
    [ ! -e "${owner_state}/workspace-cleaned-by.env" ] || {
        echo "continuation workspace was already cleaned" >&2
        return 1
    }
    ! systemctl --user --quiet is-active "helium-job-${parent}.service" && \
        ! systemctl --user --quiet is-active "helium-watch-${parent}.service" || {
        echo "continuation parent is still active" >&2
        return 1
    }
    [ ! -e "${state_root}/${child}" ] && \
        [ ! -e "${work_root}/${child}" ] || {
        echo "continuation job already exists: ${child}" >&2
        return 1
    }

    resume_owner=${owner}
    resume_budget_gib=${staged_budget_gib}
    resume_budget_bytes=${staged_budget_bytes}
    resume_command=${requested_command}
    resume_parent_command=${expected_command}
    resume_command_mode=${command_mode}
    resume_source_build_jobs=$(source_build_jobs "${parent}")
    resume_terminal_mode=${terminal_mode}
}

resume_init() {
    local parent=$1
    local child=$2
    shift 2
    [ "${1:-}" = -- ] || {
        usage
        exit 2
    }
    shift
    [ "$#" -gt 0 ] || {
        echo "missing continuation command" >&2
        exit 2
    }
    validate_job "${parent}"
    validate_job "${child}"

    local child_state="${state_root}/${child}"
    if [ -d "${child_state}" ]; then
        if ! validate_continuation_state "${child}" "$@"; then
            echo "continuation job conflicts with existing state: ${child}" >&2
            exit 1
        fi
        [ "${continuation_state_parent}" = "${parent}" ] || {
            echo "continuation job conflicts with existing state: ${child}" >&2
            exit 1
        }
        printf 'continuation=%s\nparent_job=%s\nworkspace_owner=%s\nexisting=true\n' \
            "${child}" "${parent}" "${continuation_state_owner}"
        return
    fi

    mkdir -p "${state_root}"
    exec 9>"${state_root}/start.lock"
    flock -n 9 || {
        echo "another start operation is in progress" >&2
        exit 1
    }
    if ! validate_resume_parent "${parent}" "${child}" "$@"; then
        exit 1
    fi
    if ! preflight production "${resume_budget_gib}" \
        "${work_root}/${resume_owner}" "${work_root}/${resume_owner}"; then
        exit 1
    fi

    local parent_state="${state_root}/${parent}"
    local source_sha
    source_sha=$(sha256sum "${parent_state}/source.manifest" | awk '{ print $1 }')
    mkdir "${child_state}"
    install -m 600 "${parent_state}/source.manifest" \
        "${child_state}/source.manifest"
    {
        printf 'profile=production\n'
        printf 'disk_budget_gib=%s\n' "${resume_budget_gib}"
        printf 'disk_budget_bytes=%s\n' "${resume_budget_bytes}"
        printf 'workspace_owner=%s\n' "${resume_owner}"
        printf 'staged_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${child_state}/stage.env"
    {
        printf 'parent_job=%s\n' "${parent}"
        printf 'workspace_owner=%s\n' "${resume_owner}"
        printf 'source_manifest_sha256=%s\n' "${source_sha}"
        printf 'parent_command=%s\n' "${resume_parent_command}"
        printf 'command=%s\n' "${resume_command}"
        printf 'command_mode=%s\n' "${resume_command_mode}"
        printf 'source_build_jobs=%s\n' "${resume_source_build_jobs}"
        printf 'parent_terminal_mode=%s\n' "${resume_terminal_mode}"
        printf 'admitted_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${child_state}/resume.env"

    local claim="${parent_state}/continued-by.env"
    local claim_temp="${claim}.tmp.$$"
    {
        printf 'child_job=%s\n' "${child}"
        printf 'workspace_owner=%s\n' "${resume_owner}"
        printf 'claimed_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${claim_temp}"
    if ! ln "${claim_temp}" "${claim}" 2>/dev/null; then
        find "${claim_temp}" -delete
        find "${child_state}" -depth -delete
        echo "continuation parent was claimed concurrently" >&2
        exit 1
    fi
    find "${claim_temp}" -delete
    printf 'continuation=%s\nparent_job=%s\nworkspace_owner=%s\nexisting=false\n' \
        "${child}" "${parent}" "${resume_owner}"
}

resume_abort() {
    local child=$1
    validate_job "${child}"
    local child_state="${state_root}/${child}"
    local parent
    parent=$(continuation_parent "${child}") || {
        echo "job is not an admitted continuation: ${child}" >&2
        exit 1
    }

    exec 9>"${state_root}/start.lock"
    flock -n 9 || {
        echo "another start operation is in progress" >&2
        exit 1
    }
    for started in policy.env result.env terminal.env; do
        [ ! -e "${child_state}/${started}" ] || {
            echo "refusing to abandon a started continuation" >&2
            exit 1
        }
    done
    ! systemctl --user --quiet is-active "helium-job-${child}.service" && \
        ! systemctl --user --quiet is-active "helium-watch-${child}.service" || {
        echo "refusing to abandon an active continuation" >&2
        exit 1
    }
    [ "$(exact_value "${state_root}/${parent}/continued-by.env" child_job)" = \
        "${child}" ] || {
        echo "continuation ownership claim is inconsistent" >&2
        exit 1
    }
    find "${state_root}/${parent}/continued-by.env" -delete
    find "${child_state}" -depth -delete
    printf 'continuation_abandoned=%s\nparent_job=%s\n' "${child}" "${parent}"
}

write_policy() {
    local state_dir=$1
    local profile_name=$2
    local work_dir=$3
    local disk_budget_bytes=$4
    local owner=$5
    local parent=$6
    local source_jobs=$7
    shift 7
    local command_text
    printf -v command_text '%q ' "$@"
    local temp="${state_dir}/policy.env.tmp"
    {
        printf 'profile=%s\n' "${profile_name}"
        printf 'host=%s\n' "$(hostname -s)"
        printf 'work_dir=%s\n' "${work_dir}"
        printf 'workspace_owner=%s\n' "${owner}"
        if [ -n "${parent}" ]; then
            printf 'parent_job=%s\n' "${parent}"
        fi
        printf 'build_jobs=%s\n' "${build_jobs}"
        printf 'source_build_jobs=%s\n' "${source_jobs}"
        printf 'cpu_quota=%s\n' "${cpu_quota}"
        printf 'cpu_weight=%s\n' "${cpu_weight}"
        printf 'memory_high=%s\n' "${memory_high}"
        printf 'memory_max=%s\n' "${memory_max}"
        printf 'memory_swap_max=%s\n' "${memory_swap_max}"
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
        printf 'wall_class=%s\n' "${wall_class}"
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
    local owner
    owner=$(workspace_owner "${job}") || {
        echo "job has invalid workspace ownership: ${job}" >&2
        exit 1
    }
    local job_root="${work_root}/${owner}"
    job_root=$(realpath -e "${job_root}")
    require_contained_path "${job_root}" "$(realpath -e "${work_root}")"
    require_contained_path "${work_dir}" "${job_root}"

    local state_dir="${state_root}/${job}"
    [ -f "${state_dir}/stage.env" ] || {
        echo "job is not staged: ${job}" >&2
        exit 1
    }
    local disk_budget_gib disk_budget_bytes parent='' source_jobs
    disk_budget_gib=$(exact_value "${state_dir}/stage.env" disk_budget_gib)
    disk_budget_bytes=$(exact_value "${state_dir}/stage.env" disk_budget_bytes)
    [[ "${disk_budget_gib}" =~ ^[1-9][0-9]*$ ]] && \
        [ "${disk_budget_bytes}" = "$(gib "${disk_budget_gib}")" ] || {
        echo "invalid staged disk budget for ${job}" >&2
        exit 1
    }
    if [ -f "${state_dir}/resume.env" ]; then
        if ! validate_continuation_state "${job}" "$@"; then
            echo "continuation admission is inconsistent" >&2
            exit 1
        fi
        parent=${continuation_state_parent}
        source_jobs=$(exact_value "${state_dir}/resume.env" \
            source_build_jobs)
        local continuation_mode parent_mode parent_terminal parent_wall
        local continuation_terminal_mode
        continuation_mode=$(exact_value "${state_dir}/resume.env" command_mode)
        continuation_terminal_mode=$(exact_value \
            "${state_dir}/resume.env" parent_terminal_mode)
        if [ "${continuation_terminal_mode}" = \
            retained-linux-final-link-swap-recovery ]; then
            memory_high=5G
            memory_max=6G
            memory_swap_max=2G
        fi
        if [ "${continuation_mode}" = exact ] && \
            [ -f "${state_root}/${parent}/resume.env" ]; then
            parent_mode=$(exact_value \
                "${state_root}/${parent}/resume.env" command_mode)
            parent_terminal="${state_root}/${parent}/terminal.env"
            parent_wall=$(exact_value \
                "${state_root}/${parent}/policy.env" wall_seconds)
            if [ "${parent_mode}" = retained-linux-build ] && \
                [ "${parent_wall}" = 28800 ] && \
                [ "$(exact_value "${parent_terminal}" result)" = timeout ] && \
                [ "$(exact_value "${parent_terminal}" exit_code)" = 124 ] && \
                [ "$(exact_value "${parent_terminal}" duration_seconds)" = 28800 ]; then
                wall_seconds=86400
                wall_class=extended-linux-final-link
            fi
        fi
        [ "${continuation_state_owner}" = "${owner}" ] || {
            echo "continuation workspace owner changed" >&2
            exit 1
        }
    else
        source_jobs=${build_jobs}
    fi
    local admitted_wall_seconds=${wall_seconds}
    local admitted_wall_class=${wall_class}
    local admitted_memory_high=${memory_high}
    local admitted_memory_max=${memory_max}
    local admitted_memory_swap_max=${memory_swap_max}
    if ! preflight "${profile_name}" "${disk_budget_gib}" \
        "${job_root}" "${job_root}"; then
        exit 1
    fi
    # preflight reloads the base isolation profile. Restore the continuation
    # wall class admitted from immutable parent receipts before policy and unit
    # creation.
    wall_seconds=${admitted_wall_seconds}
    wall_class=${admitted_wall_class}
    memory_high=${admitted_memory_high}
    memory_max=${admitted_memory_max}
    memory_swap_max=${admitted_memory_swap_max}
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
        "${disk_budget_bytes}" "${owner}" "${parent}" "${source_jobs}" "$@"

    if ! systemd-run --user --unit="${unit%.service}" --collect \
        --property="Description=Isolated Helium build ${job}" \
        --property="WorkingDirectory=${work_dir}" \
        --property="CPUQuota=${cpu_quota}" \
        --property="CPUWeight=${cpu_weight}" \
        --property="MemoryHigh=${memory_high}" \
        --property="MemoryMax=${memory_max}" \
        --property="MemorySwapMax=${memory_swap_max}" \
        --property=IOWeight=10 \
        --property=IOSchedulingClass=idle \
        --property=Nice=15 \
        --property="TasksMax=${tasks_max}" \
        --property="RuntimeMaxSec=${wall_seconds}" \
        --property=KillMode=control-group \
        --property=OOMPolicy=stop \
        --property=StandardOutput=journal \
        --property=StandardError=journal \
        --setenv="HELIUM_BUILD_JOBS=${source_jobs}" \
        --setenv="AUTONINJA_JOBS=${build_jobs}" \
        --setenv="NINJA_JOBS=${build_jobs}" \
        --setenv="GCLIENT_JOBS=${build_jobs}" \
        --setenv="XDG_CACHE_HOME=${job_root}/cache" \
        --setenv="CCACHE_DIR=${job_root}/cache/ccache" \
        --setenv="GIT_CACHE_PATH=${job_root}/cache/git" \
        --setenv="TMPDIR=${job_root}/tmp" \
        "${worker}" run "${state_dir}" "${watch_unit}" \
        "${watchdog_ready_seconds}" "${supervisor_interval}" -- "$@"; then
        write_terminal "${state_dir}" failure 125 \
            "failed to create isolated build unit"
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
        write_terminal "${state_dir}" failure 125 \
            "health watchdog failed to start"
        echo "failed to create health watchdog; build stopped" >&2
        exit 1
    fi

    printf 'job=%s\nunit=%s\nwatch_unit=%s\nlogs=journalctl --user --unit=%s\nstate=%s\n' \
        "${job}" "${unit}" "${watch_unit}" "${unit}" "${state_dir}"
}

resume_start() {
    local child=$1
    shift
    [ "${1:-}" = -- ] || {
        usage
        exit 2
    }
    shift
    [ "$#" -gt 0 ] || {
        echo "missing continuation command" >&2
        exit 2
    }
    validate_job "${child}"
    local child_state="${state_root}/${child}"
    local parent owner
    if ! validate_continuation_state "${child}" "$@"; then
        echo "continuation admission is inconsistent" >&2
        exit 1
    fi
    parent=${continuation_state_parent}
    owner=${continuation_state_owner}

    if [ -f "${child_state}/policy.env" ]; then
        [ "$(exact_value "${child_state}/policy.env" command)" = \
            "$(command_text "$@")" ] && \
            [ "$(exact_value "${child_state}/policy.env" workspace_owner)" = \
                "${owner}" ] && \
            [ "$(exact_value "${child_state}/policy.env" parent_job)" = \
                "${parent}" ] || {
            echo "started continuation conflicts with requested command" >&2
            exit 1
        }
        if systemctl --user --quiet is-active \
            "helium-job-${child}.service" || \
            [ -f "${child_state}/terminal.env" ]; then
            printf 'job=%s\nparent_job=%s\nworkspace_owner=%s\nexisting=true\n' \
                "${child}" "${parent}" "${owner}"
            return
        fi
        echo "started continuation has neither an active unit nor terminal state" >&2
        exit 1
    fi

    start_job production "${child}" "${work_root}/${owner}/source" -- "$@" || \
        exit 1
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
            if [ "${result}" -eq 1 ] && \
                [ -f "${state_dir}/watchdog-ready.env" ] && \
                transient_descendant_disappearance \
                    "${scan_error}" "${work_dir}"; then
                result=0
                : >"${scan_error}"
            fi
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
        if [ "${HELIUM_WATCH_EXITED_IS_TERMINAL:-false}" = true ] &&
            [ "$(systemctl --user show "${unit}" -p SubState --value)" = exited ]; then
            break
        fi
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

            if [ ! -e "${state_dir}/watchdog-ready.env" ]; then
                printf 'watchdog_ready_at=%s\n' "$(date --iso-8601=seconds)" \
                    >"${state_dir}/watchdog-ready.env.tmp"
                mv "${state_dir}/watchdog-ready.env.tmp" \
                    "${state_dir}/watchdog-ready.env"
            fi
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
    for file in stage.env resume.env policy.env continued-by.env \
        watchdog-ready.env health.env disk-scan-retry.env result.env \
        terminal.env watchdog-stop.env cancel.env artifact-returned.env \
        cleanup.env workspace-cleaned-by.env; do
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
    local owner=${2:-}
    local generation=${3:-}
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    require_job_ownership "${job}" "${owner}" "${generation}"
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
    validate_source_manifest "${manifest}"
    awk -F= '$1 == "repository" || $1 == "commit" || $1 == "tree" ||
        $1 == "helium_submodule" || $1 == "chromium_version" ||
        $1 == "HELIUM_ANDROID_CHROMIUM_COMMIT" ||
        $1 == "HELIUM_ANDROID_CORE_COMMIT" ||
        $1 == "HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" { print }' "${manifest}"
    local owner parent
    owner=$(workspace_owner "${job}") || {
        echo "job has invalid workspace ownership: ${job}" >&2
        exit 1
    }
    printf 'workspace_owner=%s\n' "${owner}"
    if parent=$(continuation_parent "${job}" 2>/dev/null); then
        printf 'parent_job=%s\n' "${parent}"
    fi
}

artifact_info() {
    local job=$1
    local relative=$2
    local owner_id=${3:-}
    local generation=${4:-}
    validate_job "${job}"
    require_job_ownership "${job}" "${owner_id}" "${generation}"
    [[ "${relative}" != /* && "${relative}" != *..* ]] || {
        echo "artifact path must be a contained relative path" >&2
        exit 2
    }
    local owner
    owner=$(workspace_owner "${job}") || {
        echo "job has invalid workspace ownership: ${job}" >&2
        exit 1
    }
    local source_root="${work_root}/${owner}/source"
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
    local owner=${3:-}
    local generation=${4:-}
    validate_job "${job}"
    require_job_ownership "${job}" "${owner}" "${generation}"
    printf 'returned_at=%s\nsha256=%s\n' "$(date --iso-8601=seconds)" "${sha}" \
        >"${state_root}/${job}/artifact-returned.env"
}

cleanup_job() {
    local job=$1
    local owner_id=${2:-}
    local generation=${3:-}
    validate_job "${job}"
    local state_dir="${state_root}/${job}"
    require_job_ownership "${job}" "${owner_id}" "${generation}"
    local owner
    owner=$(workspace_owner "${job}") || {
        echo "job has invalid workspace ownership: ${job}" >&2
        exit 1
    }
    local owner_state="${state_root}/${owner}"
    local job_root="${work_root}/${owner}"
    ! systemctl --user --quiet is-active "helium-job-${job}.service" || {
        echo "refusing cleanup while job is active" >&2
        exit 1
    }
    [ ! -e "${state_dir}/continued-by.env" ] || {
        echo "refusing cleanup from a segment that has a continuation" >&2
        exit 1
    }
    if ! grep -qx 'profile=test' "${state_dir}/stage.env" 2>/dev/null && \
        [ ! -f "${state_dir}/artifact-returned.env" ]; then
        echo "refusing cleanup until an artifact return receipt exists" >&2
        exit 1
    fi
    [ ! -e "${owner_state}/workspace-cleaned-by.env" ] || {
        echo "workspace was already cleaned" >&2
        exit 1
    }
    [ -d "${job_root}" ] && [ ! -L "${job_root}" ] || {
        echo "workspace owner is missing or unsafe" >&2
        exit 1
    }

    exec 9>"${state_root}/start.lock"
    flock -n 9 || {
        echo "another start or cleanup operation is in progress" >&2
        exit 1
    }
    ! systemctl --user --quiet is-active 'helium-job-*.service' || {
        echo "refusing cleanup while a Helium build is active" >&2
        exit 1
    }
    if [ -d "${job_root}" ]; then
        require_contained_path "$(realpath -e "${job_root}")" "$(realpath -e "${work_root}")"
        find "${job_root}" -depth -delete
    fi
    printf 'workspace_cleaned_at=%s\n' "$(date --iso-8601=seconds)" \
        >"${state_dir}/cleanup.env"
    {
        printf 'cleaned_by_job=%s\n' "${job}"
        printf 'workspace_owner=%s\n' "${owner}"
        printf 'workspace_cleaned_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${owner_state}/workspace-cleaned-by.env"
    printf 'workspace_cleaned=%s\nworkspace_owner=%s\nstate_retained=%s\n' \
        "${job_root}" "${owner}" "${state_dir}"
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
    resume-init) resume_init "$@" ;;
    resume-start) resume_start "$@" ;;
    resume-abort) resume_abort "$@" ;;
    start) start_job "$@" ;;
    run) run_job "$@" ;;
    watch) watch_job "$@" ;;
    status) status_job "$@" ;;
    limits) limits_job "$@" ;;
    logs) logs_job "$@" ;;
    claim) claim_job_ownership "$@" ;;
    cancel) cancel_job "$@" ;;
    terminal) terminal_job "$@" ;;
    source-info) source_info "$@" ;;
    artifact-info) artifact_info "$@" ;;
    mark-returned) mark_returned "$@" ;;
    cleanup) cleanup_job "$@" ;;
    *) usage; exit 2 ;;
esac
