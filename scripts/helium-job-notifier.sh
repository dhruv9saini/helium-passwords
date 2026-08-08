#!/usr/bin/env bash
set -euo pipefail
umask 077

state_root=${HELIUM_JOB_NOTIFY_STATE_ROOT:-"${HOME}/.local/state/helium-job-notifier"}
jobs_dir="${state_root}/jobs"
ssh_binary=${HELIUM_JOB_NOTIFY_SSH:-ssh}
remote_host=${HELIUM_CHROMIUMER_HOST:-chromiumer}
remote_worker=${HELIUM_CHROMIUMER_REMOTE_WORKER:-.local/libexec/helium-chromiumer-worker}

usage() {
    cat >&2 <<'EOF'
usage: helium-job-notifier <command> [arguments]

Commands:
  register <job-id> <product> <summary> <success-next-action> <source-info-file>
  abandon <job-id>
  poll
  status <job-id>
EOF
}

validate_job() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
        echo "invalid job id: $1" >&2
        exit 2
    }
}

validate_text() {
    local label=$1
    local value=$2
    local maximum=$3
    [ -n "${value}" ] && [ "${#value}" -le "${maximum}" ] || {
        echo "${label} must contain 1-${maximum} characters" >&2
        exit 2
    }
}

job_file() {
    printf '%s/%s.json\n' "${jobs_dir}" "$1"
}

replace_json() {
    local path=$1
    shift
    local temp="${path}.tmp.$$"
    jq "$@" "${path}" >"${temp}"
    chmod 600 "${temp}"
    mv "${temp}" "${path}"
}

register_job() {
    local job=$1
    local product=$2
    local summary=$3
    local success_next=$4
    local source_file=$5
    validate_job "${job}"
    validate_text product "${product}" 80
    validate_text summary "${summary}" 1000
    validate_text success-next-action "${success_next}" 1000
    [[ "${product}" =~ ^[A-Za-z0-9][A-Za-z0-9+._[:space:]-]*$ ]] || {
        echo "product contains unsupported characters" >&2
        exit 2
    }
    [ -f "${source_file}" ] && [ ! -L "${source_file}" ] || {
        echo "source info must be a non-symlink regular file" >&2
        exit 2
    }
    local source_commits
    source_commits=$(<"${source_file}")
    validate_text source-commits "${source_commits}" 4096

    mkdir -p "${jobs_dir}"
    chmod 700 "${state_root}" "${jobs_dir}"
    exec 9>"${state_root}/queue.lock"
    flock 9

    local path
    path=$(job_file "${job}")
    if [ -f "${path}" ]; then
        jq -e \
            --arg product "${product}" \
            --arg summary "${summary}" \
            --arg success_next "${success_next}" \
            --arg sources "${source_commits}" \
            '.product == $product and .summary == $summary and
             .success_next == $success_next and .source_commits == $sources and
             .status != "abandoned"' "${path}" >/dev/null || {
            echo "job notification registration conflicts with existing state: ${job}" >&2
            exit 1
        }
        printf 'registered=%s\nexisting=true\n' "${job}"
        return
    fi

    local temp="${path}.tmp.$$"
    jq -n \
        --arg job "${job}" \
        --arg product "${product}" \
        --arg summary "${summary}" \
        --arg success_next "${success_next}" \
        --arg sources "${source_commits}" \
        --arg host "${remote_host}" \
        --argjson registered_at "$(date +%s)" \
        '{schema: 3, job_id: $job, product: $product, summary: $summary,
          success_next: $success_next, source_commits: $sources, remote_host: $host,
          status: "watching", registered_at: $registered_at,
          last_poll_error: null}' >"${temp}"
    chmod 600 "${temp}"
    mv "${temp}" "${path}"
    printf 'registered=%s\nexisting=false\n' "${job}"
}

abandon_job() {
    local job=$1
    validate_job "${job}"
    local path
    path=$(job_file "${job}")
    [ -f "${path}" ] || return 0
    exec 9>"${state_root}/queue.lock"
    flock 9
    replace_json "${path}" \
        --argjson now "$(date +%s)" \
        '.schema = 3 | .status = "abandoned" | .abandoned_at = $now |
         del(.notification_key, .conversation) |
         with_entries(select(.key | startswith("analysis_") | not))'
    printf 'abandoned=%s\n' "${job}"
}

record_poll_error() {
    local path=$1
    local error=$2
    local old
    old=$(jq -r '.last_poll_error // ""' "${path}")
    replace_json "${path}" --arg error "${error}" '.last_poll_error = $error'
    if [ "${old}" != "${error}" ]; then
        printf 'job=%s poll-delayed=%s\n' "$(jq -r .job_id "${path}")" "${error}" >&2
    fi
}

terminal_value() {
    local text=$1
    local key=$2
    awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${text}"
}

migrate_delivery_fields() {
    local path=$1
    if jq -e '
        .schema == 3 and
        (has("notification_key") | not) and
        (has("conversation") | not) and
        ([keys[] | startswith("analysis_")] | any | not)
    ' "${path}" >/dev/null; then
        return
    fi
    replace_json "${path}" '
        .schema = 3 |
        del(.notification_key, .conversation) |
        with_entries(select(.key | startswith("analysis_") | not))
    '
}

record_terminal_state() {
    local path=$1
    local job
    job=$(jq -r .job_id "${path}")
    if ! jq -e '
        .result != null and .duration_seconds != null and .exit_code != null and
        .terminal_reason != null
    ' "${path}" >/dev/null; then
        record_poll_error "${path}" "terminal state record is incomplete"
        return
    fi
    replace_json "${path}" \
        --argjson now "$(date +%s)" \
        '.schema = 3 | .status = "terminal-recorded" |
         .terminal_recorded_at = $now | .last_poll_error = null |
         del(.notification_key, .conversation) |
         with_entries(select(.key | startswith("analysis_") | not))'
    printf 'terminal-recorded job=%s\n' "${job}"
}

valid_terminal_reason() {
    local value=$1
    [ -n "${value}" ] && [ "${#value}" -le 1000 ] &&
        LC_ALL=C grep -qE '^[[:print:]]+$' <<<"${value}"
}

poll_jobs() {
    mkdir -p "${jobs_dir}"
    chmod 700 "${state_root}" "${jobs_dir}"
    exec 9>"${state_root}/queue.lock"
    flock -n 9 || exit 0

    local path status job terminal state result duration exit_code reason
    shopt -s nullglob
    for path in "${jobs_dir}"/*.json; do
        migrate_delivery_fields "${path}"
        status=$(jq -r .status "${path}")
        case "${status}" in
            watching)
                job=$(jq -r .job_id "${path}")
                if ! terminal=$("${ssh_binary}" -o BatchMode=yes "${remote_host}" \
                    "${remote_worker}" terminal "${job}" 2>/dev/null); then
                    record_poll_error "${path}" "chromiumer unavailable"
                    continue
                fi
                state=$(terminal_value "${terminal}" state)
                if [ "${state}" != terminal ]; then
                    if [ "$(jq -r '.last_poll_error // ""' "${path}")" != "" ]; then
                        replace_json "${path}" '.last_poll_error = null'
                    fi
                    continue
                fi
                result=$(terminal_value "${terminal}" result)
                duration=$(terminal_value "${terminal}" duration_seconds)
                exit_code=$(terminal_value "${terminal}" exit_code)
                reason=$(terminal_value "${terminal}" reason)
                [[ "${result}" =~ ^(success|failure|timeout|cancellation)$ ]] && \
                    [[ "${duration}" =~ ^[0-9]+$ ]] && [[ "${exit_code}" =~ ^[0-9]+$ ]] &&
                    valid_terminal_reason "${reason}" || {
                    record_poll_error "${path}" "invalid chromiumer terminal state"
                    continue
                }
                replace_json "${path}" \
                    --arg result "${result}" --arg reason "${reason}" \
                    --argjson duration "${duration}" --argjson exit_code "${exit_code}" \
                    --argjson now "$(date +%s)" \
                    '.status = "terminal-pending" | .result = $result |
                     .duration_seconds = $duration | .exit_code = $exit_code |
                     .terminal_reason = $reason | .observed_terminal_at = $now |
                     .last_poll_error = null'
                record_terminal_state "${path}"
                ;;
            terminal-pending|notification-pending|notification-queued|notification-sent|notification-failed|analysis-queued|analysis-running|analysis-completed|analysis-emailed|analysis-failed|analysis-conflict)
                record_terminal_state "${path}"
                ;;
        esac
    done
}

show_status() {
    local job=$1
    validate_job "${job}"
    local path
    path=$(job_file "${job}")
    [ -f "${path}" ] || {
        echo "unknown notification job: ${job}" >&2
        exit 1
    }
    jq . "${path}"
}

command=${1:-}
shift || true
case "${command}" in
    register) [ "$#" -eq 5 ] || { usage; exit 2; }; register_job "$@" ;;
    abandon) [ "$#" -eq 1 ] || { usage; exit 2; }; abandon_job "$@" ;;
    poll) [ "$#" -eq 0 ] || { usage; exit 2; }; poll_jobs ;;
    status) [ "$#" -eq 1 ] || { usage; exit 2; }; show_status "$@" ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
