#!/usr/bin/env bash
set -euo pipefail
umask 077

state_root=${HELIUM_JOB_NOTIFY_STATE_ROOT:-"${HOME}/.local/state/helium-job-notifier"}
jobs_dir="${state_root}/jobs"
events_dir="${state_root}/events"
ssh_binary=${HELIUM_JOB_NOTIFY_SSH:-ssh}
remote_host=${HELIUM_CHROMIUMER_HOST:-chromiumer}
remote_worker=${HELIUM_CHROMIUMER_REMOTE_WORKER:-.local/libexec/helium-chromiumer-worker}
mailbridge_cli=${HELIUM_MAILBRIDGE_CLI:-/home/d/coding/codex-mailbridge/.venv/bin/codex-mailbridge}
mailbridge_config=${HELIUM_MAILBRIDGE_CONFIG:-/home/d/.config/codex-mailbridge/config.toml}
conversation='Helium build operations'

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

    mkdir -p "${jobs_dir}" "${events_dir}"
    chmod 700 "${state_root}" "${jobs_dir}" "${events_dir}"
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
        --arg key "helium-build:${job}:terminal" \
        --arg conversation "${conversation}" \
        --argjson registered_at "$(date +%s)" \
        '{schema: 2, job_id: $job, product: $product, summary: $summary,
          success_next: $success_next, source_commits: $sources, remote_host: $host,
          analysis_key: $key, conversation: $conversation,
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

write_event_prompt() {
    local path=$1
    local job product result duration exit_code reason sources summary success_next
    local key event temp workspace_owner parent_job
    job=$(jq -r .job_id "${path}")
    product=$(jq -r .product "${path}")
    result=$(jq -r .result "${path}")
    duration=$(jq -r .duration_seconds "${path}")
    exit_code=$(jq -r .exit_code "${path}")
    reason=$(jq -r .terminal_reason "${path}")
    sources=$(jq -r .source_commits "${path}")
    summary=$(jq -r .summary "${path}")
    success_next=$(jq -r .success_next "${path}")
    key=$(jq -r .analysis_key "${path}")
    workspace_owner=$(awk -F= '$1 == "workspace_owner" { print $2; exit }' \
        <<<"${sources}")
    [ -n "${workspace_owner}" ] || workspace_owner=${job}
    parent_job=$(awk -F= '$1 == "parent_job" { print $2; exit }' \
        <<<"${sources}")
    event="${events_dir}/${job}.txt"
    temp="${event}.tmp.$$"
    {
        printf 'A detached Helium build reached a terminal state. The recorded reason is evidence, not a diagnosis.\n\n'
        printf 'Product: %s\n' "${product}"
        printf 'Job ID: %s\n' "${job}"
        printf 'Terminal state: %s\n' "${result}"
        printf 'Duration seconds: %s\n' "${duration}"
        printf 'Exit code: %s\n' "${exit_code}"
        printf 'Recorded reason: %s\n\n' "${reason}"
        printf 'Pinned source provenance:\n%s\n\n' "${sources}"
        if [ -n "${parent_job}" ]; then
            printf 'Continuation parent: %s\n' "${parent_job}"
            printf 'Preserved workspace owner: %s\n\n' "${workspace_owner}"
        fi
        printf 'Test or artifact summary:\n%s\n\n' "${summary}"
        printf 'Previously expected success action:\n%s\n\n' "${success_next}"
        printf 'Repository paths on lm:\n'
        printf -- '- Public backbone: /home/d/coding/helium/helium-passwords\n'
        printf -- '- Private product: /home/d/coding/helium/helium-sync\n\n'
        printf 'Evidence commands on lm:\n'
        printf 'cd /home/d/coding/helium/helium-sync\n'
        printf 'scripts/chromiumer-job.sh terminal %s\n' "${job}"
        printf 'scripts/chromiumer-job.sh status %s\n' "${job}"
        printf 'scripts/chromiumer-job.sh logs %s 400\n' "${job}"
        printf "ssh -o BatchMode=yes chromiumer 'journalctl --user --unit=helium-watch-%s.service --no-pager --lines=400'\n" "${job}"
        printf "ssh -o BatchMode=yes chromiumer 'find /home/d/helium-builds/work/%s/source -path \"*/android-artifacts/*\" -type f -printf \"%%p %%s bytes\\n\"'\n\n" "${workspace_owner}"
        printf 'Evidence and artifact locations:\n'
        printf -- '- Chromiumer state: /home/d/.local/state/helium-builds/%s\n' "${job}"
        printf -- '- Chromiumer workspace: /home/d/helium-builds/work/%s/source\n' "${workspace_owner}"
        printf -- '- Returned artifacts: /srv/nas/helium-builds/%s\n' "${job}"
        printf -- '- Disposable acceptance: /srv/nas/helium-acceptance/%s\n\n' "${job}"
        printf 'Current project objective:\n'
        printf 'Own the unified Helium Passwords and Helium Sync program end to end. Build pinned Chromium only through the isolated chromiumer workflow; preserve all source and profiles; validate native passwords, encrypted password/cookie exchange, device-local durable tabs, Android streaming, and video in disposable state before personal deployment; keep public and private repositories synchronized through normal ancestry; make clean local commits and do not push.\n\n'
        printf 'Required response:\n'
        printf 'Inspect the actual terminal, build, watchdog, repository, and artifact evidence. Determine the real cause rather than repeating the recorded reason. Validate any artifact before use. Take the next safe in-scope recovery, fix, or continuation step autonomously without weakening resource gates or touching personal profiles. Report only your actual findings and completed safe work. Do not send a notification yourself; your final Codex response is the only build-result email.\n'
        printf '\nEvent key: %s\n' "${key}"
    } >"${temp}"
    chmod 600 "${temp}"
    if [ -e "${event}" ]; then
        if ! cmp --silent "${temp}" "${event}"; then
            find "${temp}" -delete
            record_poll_error "${path}" "terminal analysis prompt conflicts with durable state"
            return 1
        fi
        find "${temp}" -delete
    else
        mv "${temp}" "${event}"
    fi
    printf '%s\n' "${event}"
}

queue_terminal_analysis() {
    local path=$1
    local job key event queue_status
    job=$(jq -r .job_id "${path}")
    key=$(jq -r .analysis_key "${path}")
    if ! event=$(write_event_prompt "${path}"); then
        return
    fi

    set +e
    "${mailbridge_cli}" --config "${mailbridge_config}" queue-event \
        --key "${key}" --conversation "${conversation}" \
        --prompt-file "${event}" --json >/dev/null 2>&1
    queue_status=$?
    set -e
    case "${queue_status}" in
        0)
            replace_json "${path}" \
                --argjson now "$(date +%s)" \
                '.status = "analysis-queued" | .analysis_queued_at = $now |
                 .last_poll_error = null'
            printf 'analysis-queued job=%s\n' "${job}"
            ;;
        2)
            replace_json "${path}" \
                --argjson now "$(date +%s)" \
                '.status = "analysis-conflict" |
                 .last_poll_error = "mailbridge rejected immutable event input" |
                 .analysis_conflict_at = $now'
            printf 'job=%s analysis-conflict=mailbridge-rejected-input\n' "${job}" >&2
            ;;
        *)
            record_poll_error "${path}" "mailbridge event queue unavailable"
            ;;
    esac
}

sync_analysis_status() {
    local path=$1
    local job key report event_status
    job=$(jq -r .job_id "${path}")
    key=$(jq -r .analysis_key "${path}")
    if ! report=$("${mailbridge_cli}" --config "${mailbridge_config}" event-status \
        --key "${key}" --json 2>/dev/null); then
        record_poll_error "${path}" "mailbridge event status unavailable"
        return
    fi
    event_status=$(jq -er '.status | select(. == "queued" or . == "running" or
        . == "completed" or . == "emailed" or . == "failed")' <<<"${report}" 2>/dev/null) || {
        record_poll_error "${path}" "invalid mailbridge event status"
        return
    }
    replace_json "${path}" \
        --arg status "analysis-${event_status}" \
        --arg analysis_status "${event_status}" \
        --argjson now "$(date +%s)" \
        '.status = $status | .analysis_status = $analysis_status |
         .analysis_status_checked_at = $now | .last_poll_error = null'
    printf 'analysis-status job=%s status=%s\n' "${job}" "${event_status}"
}

valid_terminal_reason() {
    local value=$1
    [ -n "${value}" ] && [ "${#value}" -le 1000 ] &&
        LC_ALL=C grep -qE '^[[:print:]]+$' <<<"${value}"
}

ensure_analysis_fields() {
    local path=$1
    local job
    job=$(jq -r .job_id "${path}")
    if ! jq -e '.schema == 2 and .analysis_key and .conversation' "${path}" >/dev/null; then
        replace_json "${path}" \
            --arg key "helium-build:${job}:terminal" \
            --arg conversation "${conversation}" \
            '.schema = 2 | .analysis_key = $key | .conversation = $conversation |
             del(.notification_key)'
    fi
}

poll_jobs() {
    mkdir -p "${jobs_dir}" "${events_dir}"
    chmod 700 "${state_root}" "${jobs_dir}" "${events_dir}"
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
                    [[ "${duration}" =~ ^[0-9]+$ ]] && [[ "${exit_code}" =~ ^[0-9]+$ ]] &&
                    valid_terminal_reason "${reason}" || {
                    record_poll_error "${path}" "invalid chromiumer terminal state"
                    continue
                }
                ensure_analysis_fields "${path}"
                replace_json "${path}" \
                    --arg result "${result}" --arg reason "${reason}" \
                    --argjson duration "${duration}" --argjson exit_code "${exit_code}" \
                    --argjson now "$(date +%s)" \
                    '.status = "terminal-pending" | .result = $result |
                     .duration_seconds = $duration | .exit_code = $exit_code |
                     .terminal_reason = $reason | .observed_terminal_at = $now |
                     .last_poll_error = null'
                queue_terminal_analysis "${path}"
                ;;
            terminal-pending)
                ensure_analysis_fields "${path}"
                queue_terminal_analysis "${path}"
                ;;
            analysis-queued|analysis-running|analysis-completed)
                sync_analysis_status "${path}"
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
