#!/usr/bin/env bash
set -euo pipefail
umask 077

state_root=${HELIUM_JOB_NOTIFY_STATE_ROOT:-"${HOME}/.local/state/helium-job-notifier"}
jobs_dir="${state_root}/jobs"
body_dir="${state_root}/bodies"
ssh_binary=${HELIUM_JOB_NOTIFY_SSH:-ssh}
remote_host=${HELIUM_CHROMIUMER_HOST:-chromiumer}
remote_worker=${HELIUM_CHROMIUMER_REMOTE_WORKER:-.local/libexec/helium-chromiumer-worker}
mailbridge_cli=${HELIUM_MAILBRIDGE_CLI:-/home/d/coding/codex-mailbridge/.venv/bin/codex-mailbridge}
mailbridge_config=${HELIUM_MAILBRIDGE_CONFIG:-/home/d/.config/codex-mailbridge/config.toml}
recipient=${HELIUM_JOB_NOTIFY_RECIPIENT:-dhruv9saini@gmail.com}

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

    mkdir -p "${jobs_dir}" "${body_dir}"
    chmod 700 "${state_root}" "${jobs_dir}" "${body_dir}"
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
        --arg key "helium-job:${job}:terminal" \
        --argjson registered_at "$(date +%s)" \
        '{schema: 1, job_id: $job, product: $product, summary: $summary,
          success_next: $success_next, source_commits: $sources, remote_host: $host,
          notification_key: $key, status: "watching", registered_at: $registered_at,
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
        '.status = "abandoned" | .abandoned_at = $now'
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

format_duration() {
    local total=$1
    printf '%02d:%02d:%02d' "$((total / 3600))" "$(((total % 3600) / 60))" \
        "$((total % 60))"
}

queue_terminal_notification() {
    local path=$1
    local job product result duration sources summary success_next next body subject key
    job=$(jq -r .job_id "${path}")
    product=$(jq -r .product "${path}")
    result=$(jq -r .result "${path}")
    duration=$(jq -r .duration_seconds "${path}")
    sources=$(jq -r .source_commits "${path}")
    summary=$(jq -r .summary "${path}")
    success_next=$(jq -r .success_next "${path}")
    key=$(jq -r .notification_key "${path}")

    case "${result}" in
        success)
            next=${success_next}
            ;;
        failure)
            next="Inspect scripts/chromiumer-job.sh logs ${job} 200, fix the first failing target, then start a new unique job."
            ;;
        timeout)
            next="Inspect scripts/chromiumer-job.sh logs ${job} 200 and identify the last target before splitting work or changing a measured limit."
            ;;
        cancellation)
            next="Review scripts/chromiumer-job.sh status ${job} and its logs before deciding whether a new unique job is needed."
            ;;
        *)
            record_poll_error "${path}" "invalid terminal result"
            return
            ;;
    esac

    body="${body_dir}/${job}.txt"
    {
        printf '%s job finished.\n\n' "${product}"
        printf 'Product: %s\n' "${product}"
        printf 'Job ID: %s\n' "${job}"
        printf 'Result: %s\n' "${result}"
        printf 'Duration: %s (%s seconds)\n\n' "$(format_duration "${duration}")" "${duration}"
        printf 'Source commits:\n%s\n\n' "${sources}"
        printf 'Test or artifact summary:\n%s\n\n' "${summary}"
        printf 'Next useful action:\n%s\n' "${next}"
    } >"${body}"
    chmod 600 "${body}"
    subject="[Helium] ${product}: ${job} ${result}"

    if "${mailbridge_cli}" --config "${mailbridge_config}" queue-notification \
        --key "${key}" --to "${recipient}" --subject "${subject}" \
        --body-file "${body}" >/dev/null 2>&1; then
        replace_json "${path}" \
            --argjson now "$(date +%s)" \
            '.status = "notification-queued" | .notification_queued_at = $now |
             .last_poll_error = null'
        printf 'notification-queued job=%s result=%s\n' "${job}" "${result}"
    else
        record_poll_error "${path}" "mailbridge queue unavailable"
    fi
}

poll_jobs() {
    mkdir -p "${jobs_dir}" "${body_dir}"
    chmod 700 "${state_root}" "${jobs_dir}" "${body_dir}"
    exec 9>"${state_root}/queue.lock"
    flock -n 9 || exit 0

    local path status job terminal state result duration exit_code reason
    shopt -s nullglob
    for path in "${jobs_dir}"/*.json; do
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
                    [[ "${duration}" =~ ^[0-9]+$ ]] && [[ "${exit_code}" =~ ^[0-9]+$ ]] || {
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
                queue_terminal_notification "${path}"
                ;;
            terminal-pending)
                queue_terminal_notification "${path}"
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
