#!/usr/bin/env bash
set -euo pipefail
umask 077

state_root=${HELIUM_UNIT_TERMINAL_STATE_ROOT:-"${HOME}/.local/state/helium-unit-terminal"}

usage() {
    echo "usage: chromiumer-unit-terminal <arm|terminal|status> <job-id>" >&2
}

validate_job() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
        echo "invalid job id: $1" >&2
        exit 2
    }
}

state_path() {
    printf '%s/%s.env\n' "${state_root}" "$1"
}

unit_name() {
    printf 'helium-job-%s.service\n' "$1"
}

exact_value() {
    local file=$1 key=$2
    awk -F= -v key="${key}" '
        $1 == key {count += 1; value=substr($0, length(key) + 2)}
        END {if (count == 1 && value != "") print value; else exit 1}
    ' "${file}"
}

load_state() {
    local job=$1 file
    file=$(state_path "${job}")
    [ -f "${file}" ] && [ ! -L "${file}" ] &&
        [ "$(stat -c %a "${file}")" = 600 ] || {
        echo "missing protected unit monitor state: ${job}" >&2
        exit 1
    }
    [ "$(exact_value "${file}" schema)" = helium-unit-terminal-v1 ] &&
        [ "$(exact_value "${file}" job)" = "${job}" ] &&
        [ "$(exact_value "${file}" unit)" = "$(unit_name "${job}")" ] &&
        [[ "$(exact_value "${file}" status)" =~ ^(armed|running|terminal)$ ]] || {
        echo "invalid unit monitor state: ${job}" >&2
        exit 1
    }
    state_file=${file}
}

write_state() {
    local file=$1
    shift
    local temporary="${file}.tmp.$$"
    printf '%s\n' "$@" >"${temporary}"
    chmod 600 "${temporary}"
    mv "${temporary}" "${file}"
}

property_value() {
    local text=$1 key=$2
    awk -F= -v key="${key}" '
        $1 == key {count += 1; value=substr($0, length(key) + 2)}
        END {if (count == 1) print value; else exit 1}
    ' <<<"${text}"
}

unit_properties() {
    systemctl --user show "$1" \
        -p LoadState -p ActiveState -p SubState -p Result \
        -p ExecMainCode -p ExecMainStatus \
        -p ExecMainStartTimestampMonotonic \
        -p ExecMainExitTimestampMonotonic --no-pager
}

arm_job() {
    local job=$1 unit file properties load
    validate_job "${job}"
    unit=$(unit_name "${job}")
    mkdir -p "${state_root}"
    chmod 700 "${state_root}"
    exec 9>"${state_root}/lock"
    flock 9
    file=$(state_path "${job}")
    if [ -e "${file}" ]; then
        load_state "${job}"
        [ "$(exact_value "${file}" status)" != terminal ] || {
            echo "unit monitor job is already terminal: ${job}" >&2
            exit 1
        }
        printf 'armed=%s\nexisting=true\n' "${job}"
        return
    fi
    properties=$(unit_properties "${unit}")
    load=$(property_value "${properties}" LoadState)
    [ "${load}" = not-found ] || {
        echo "unit already exists before monitor admission: ${unit}" >&2
        exit 1
    }
    write_state "${file}" \
        schema=helium-unit-terminal-v1 \
        job="${job}" \
        unit="${unit}" \
        status=armed \
        armed_at_epoch="$(date +%s)"
    printf 'armed=%s\nexisting=false\nunit=%s\n' "${job}" "${unit}"
}

emit_terminal() {
    local file=$1
    cat "${file}"
}

poll_terminal() {
    local job=$1 file unit status properties load active sub result code exit_status
    local start_mono exit_mono duration result_name reason armed_at
    validate_job "${job}"
    load_state "${job}"
    file=${state_file}
    unit=$(unit_name "${job}")
    status=$(exact_value "${file}" status)
    if [ "${status}" = terminal ]; then
        emit_terminal "${file}"
        return
    fi
    properties=$(unit_properties "${unit}")
    load=$(property_value "${properties}" LoadState)
    if [ "${load}" = not-found ]; then
        printf 'state=staged\n'
        return
    fi
    [ "${load}" = loaded ] || {
        echo "unexpected unit load state: ${load}" >&2
        exit 1
    }
    active=$(property_value "${properties}" ActiveState)
    sub=$(property_value "${properties}" SubState)
    result=$(property_value "${properties}" Result)
    code=$(property_value "${properties}" ExecMainCode)
    exit_status=$(property_value "${properties}" ExecMainStatus)
    start_mono=$(property_value "${properties}" ExecMainStartTimestampMonotonic)
    exit_mono=$(property_value "${properties}" ExecMainExitTimestampMonotonic)
    [[ "${start_mono}" =~ ^[0-9]+$ && "${exit_mono}" =~ ^[0-9]+$ &&
        "${exit_status}" =~ ^[0-9]+$ ]] || {
        echo "invalid systemd execution properties for ${unit}" >&2
        exit 1
    }
    if [ "${sub}" = running ]; then
        armed_at=$(exact_value "${file}" armed_at_epoch)
        write_state "${file}" \
            schema=helium-unit-terminal-v1 \
            job="${job}" \
            unit="${unit}" \
            status=running \
            armed_at_epoch="${armed_at}" \
            observed_running_at_epoch="$(date +%s)" \
            exec_start_monotonic_usec="${start_mono}"
        printf 'state=running\n'
        return
    fi
    if [ "${sub}" != exited ] && [ "${active}" != failed ] &&
        [ "${active}" != inactive ]; then
        printf 'state=running\n'
        return
    fi
    [ "${start_mono}" -gt 0 ] && [ "${exit_mono}" -ge "${start_mono}" ] || {
        echo "unit has no admitted completed execution: ${unit}" >&2
        exit 1
    }
    duration=$(((exit_mono - start_mono) / 1000000))
    if [ "${result}" = success ] && [ "${code}" = exited ] &&
        [ "${exit_status}" = 0 ]; then
        result_name=success
        reason='systemd unit completed successfully'
    elif [ "${result}" = timeout ]; then
        result_name=timeout
        reason='systemd unit reached its wall-time limit'
        [ "${exit_status}" -gt 0 ] || exit_status=124
    else
        result_name=failure
        reason="systemd unit failed result ${result} code ${code}"
        [ "${exit_status}" -gt 0 ] || exit_status=1
    fi
    armed_at=$(exact_value "${file}" armed_at_epoch)
    write_state "${file}" \
        schema=helium-unit-terminal-v1 \
        job="${job}" \
        unit="${unit}" \
        status=terminal \
        armed_at_epoch="${armed_at}" \
        state=terminal \
        result="${result_name}" \
        exit_code="${exit_status}" \
        started_at_epoch="$(( $(date +%s) - duration ))" \
        finished_at_epoch="$(date +%s)" \
        duration_seconds="${duration}" \
        reason="${reason}" \
        systemd_result="${result}" \
        systemd_exec_code="${code}" \
        exec_start_monotonic_usec="${start_mono}" \
        exec_exit_monotonic_usec="${exit_mono}"
    emit_terminal "${file}"
}

show_status() {
    local job=$1
    validate_job "${job}"
    load_state "${job}"
    cat "${state_file}"
}

command=${1:-}
shift || true
[ "$#" -eq 1 ] || { usage; exit 2; }
case "${command}" in
    arm) arm_job "$1" ;;
    terminal) poll_terminal "$1" ;;
    status) show_status "$1" ;;
    *) usage; exit 2 ;;
esac
