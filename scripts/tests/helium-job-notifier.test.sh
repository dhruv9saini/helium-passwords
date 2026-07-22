#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
test_root=$(mktemp -d /tmp/helium-job-notifier-test.XXXXXX)
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/remote" "${test_root}/mailbridge-events"

source_info="${test_root}/source.env"
cat >"${source_info}" <<'EOF'
repository=helium-sync
commit=abc123
tree=tree123
helium_submodule=def456
chromium_version=148.0.7778.178
HELIUM_ANDROID_CHROMIUM_COMMIT=chromium123
HELIUM_ANDROID_CORE_COMMIT=core123
HELIUM_ANDROID_DEPOT_TOOLS_COMMIT=depot123
EOF
chmod 600 "${source_info}"

fake_ssh="${test_root}/ssh"
cat >"${fake_ssh}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
job=${!#}
cat "${FAKE_REMOTE_ROOT}/${job}.env"
EOF
chmod 700 "${fake_ssh}"

fake_mailbridge="${test_root}/mailbridge"
cat >"${fake_mailbridge}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=
for argument in "$@"; do
    case "${argument}" in
        queue-event|event-status|queue-notification) command_name=${argument}; break ;;
    esac
done
case "${command_name}" in
    queue-notification)
        echo "static build notification is forbidden" >&2
        exit 64
        ;;
    queue-event)
        if [ -n "${FAKE_MAIL_FAIL_ONCE:-}" ] && [ ! -e "${FAKE_MAIL_FAIL_ONCE}" ]; then
            touch "${FAKE_MAIL_FAIL_ONCE}"
            exit 75
        fi
        key=
        conversation=
        prompt=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --key) key=$2; shift 2 ;;
                --conversation) conversation=$2; shift 2 ;;
                --prompt-file) prompt=$2; shift 2 ;;
                --to|--subject|--body-file)
                    echo "notification or recipient arguments are forbidden" >&2
                    exit 64
                    ;;
                *) shift ;;
            esac
        done
        [ "${conversation}" = 'Helium build operations' ]
        [ -f "${prompt}" ] && [ ! -L "${prompt}" ]
        [ "$(stat -c %a "${prompt}")" = 600 ]
        digest=$(sha256sum "${prompt}" | awk '{print $1}')
        record="${FAKE_EVENT_ROOT}/${key}.env"
        if [ -e "${record}" ]; then
            grep -qx "prompt_sha256=${digest}" "${record}"
            grep -qx "conversation=${conversation}" "${record}"
        else
            cat >"${record}" <<STATE
prompt_sha256=${digest}
conversation=${conversation}
status=queued
STATE
        fi
        printf '%s\t%s\t%s\n' "${key}" "${digest}" "${conversation}" \
            >>"${FAKE_EVENT_CALLS}"
        printf '{"event_key":"%s","status":"queued"}\n' "${key}"
        ;;
    event-status)
        key=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --key) key=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        status=$(awk -F= '$1 == "status" { print $2 }' \
            "${FAKE_EVENT_ROOT}/${key}.env")
        printf '{"event_key":"%s","status":"%s"}\n' "${key}" "${status}"
        ;;
    *)
        echo "unexpected Mailbridge command" >&2
        exit 64
        ;;
esac
EOF
chmod 700 "${fake_mailbridge}"

export HELIUM_JOB_NOTIFY_STATE_ROOT="${test_root}/state"
export HELIUM_JOB_NOTIFY_SSH="${fake_ssh}"
export HELIUM_MAILBRIDGE_CLI="${fake_mailbridge}"
export HELIUM_MAILBRIDGE_CONFIG="${test_root}/unused.toml"
export HELIUM_JOB_NOTIFY_RECIPIENT=attacker@example.invalid
export FAKE_REMOTE_ROOT="${test_root}/remote"
export FAKE_EVENT_ROOT="${test_root}/mailbridge-events"
export FAKE_EVENT_CALLS="${test_root}/event-calls"
notifier="${root_dir}/scripts/helium-job-notifier.sh"

! grep -q 'queue-notification' "${notifier}"
! grep -q 'HELIUM_JOB_NOTIFY_RECIPIENT' "${notifier}"
! grep -Eq -- '(^|[[:space:]])--to([=[:space:]]|$)' "${notifier}"
! grep -Eq '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "${notifier}"
grep -q 'queue-event' "${notifier}"
grep -q "conversation='Helium build operations'" "${notifier}"

declare -A exit_codes=(
    [success]=0
    [failure]=1
    [timeout]=124
    [cancellation]=130
)
for result in success failure timeout cancellation; do
    job="test-${result}"
    "${notifier}" register "${job}" "Helium Sync" "Synthetic ${result} proof" \
        "Fetch and validate the synthetic artifact." "${source_info}" >/dev/null
    cat >"${FAKE_REMOTE_ROOT}/${job}.env" <<EOF
state=terminal
result=${result}
exit_code=${exit_codes[${result}]}
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic ${result} evidence
EOF
done

"${notifier}" poll
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 4 ]
for result in success failure timeout cancellation; do
    job="test-${result}"
    state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${job}.json"
    event="${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${job}.txt"
    jq -e --arg result "${result}" \
        '.schema == 2 and .status == "analysis-queued" and .result == $result and
         .analysis_key == ("helium-build:" + .job_id + ":terminal") and
         .conversation == "Helium build operations"' "${state}" >/dev/null
    grep -q "Terminal state: ${result}" "${event}"
    grep -q "Exit code: ${exit_codes[${result}]}" "${event}"
    grep -q "Recorded reason: synthetic ${result} evidence" "${event}"
    grep -q 'Pinned source provenance:' "${event}"
    grep -q 'HELIUM_ANDROID_CHROMIUM_COMMIT=chromium123' "${event}"
    grep -q '/home/d/coding/helium/helium-passwords' "${event}"
    grep -q '/home/d/coding/helium/helium-sync' "${event}"
    grep -q "scripts/chromiumer-job.sh logs ${job} 400" "${event}"
    grep -q "/home/d/.local/state/helium-builds/${job}" "${event}"
    grep -q "/home/d/helium-builds/work/${job}/source" "${event}"
    grep -q "/srv/nas/helium-builds/${job}" "${event}"
    grep -q 'Current project objective:' "${event}"
    grep -q 'Determine the real cause rather than repeating the recorded reason' "${event}"
    grep -q 'your final Codex response is the only build-result email' "${event}"
done

# Repeated and concurrent polling must never create another event turn.
"${notifier}" poll
("${notifier}" poll) &
("${notifier}" poll) &
wait
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 4 ]

# The producer mirrors content-free Mailbridge state without sending anything.
sed -i 's/status=queued/status=running/' \
    "${FAKE_EVENT_ROOT}/helium-build:test-success:terminal.env"
sed -i 's/status=queued/status=completed/' \
    "${FAKE_EVENT_ROOT}/helium-build:test-failure:terminal.env"
sed -i 's/status=queued/status=emailed/' \
    "${FAKE_EVENT_ROOT}/helium-build:test-timeout:terminal.env"
sed -i 's/status=queued/status=failed/' \
    "${FAKE_EVENT_ROOT}/helium-build:test-cancellation:terminal.env"
"${notifier}" poll
jq -e '.status == "analysis-running" and .analysis_status == "running"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-success.json" >/dev/null
jq -e '.status == "analysis-completed" and .analysis_status == "completed"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-failure.json" >/dev/null
jq -e '.status == "analysis-emailed" and .analysis_status == "emailed"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-timeout.json" >/dev/null
jq -e '.status == "analysis-failed" and .analysis_status == "failed"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-cancellation.json" >/dev/null
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 4 ]

# A temporary queue-interface failure retains the exact prompt and retries it.
retry_job=test-retry
"${notifier}" register "${retry_job}" "Helium Passwords" \
    "Synthetic temporary Mailbridge failure" "Inspect the synthetic artifact." \
    "${source_info}" >/dev/null
cat >"${FAKE_REMOTE_ROOT}/${retry_job}.env" <<'EOF'
state=terminal
result=success
exit_code=0
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic retry evidence
EOF
export FAKE_MAIL_FAIL_ONCE="${test_root}/mail-failed-once"
"${notifier}" poll
jq -e '.status == "terminal-pending" and
       .last_poll_error == "mailbridge event queue unavailable"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${retry_job}.json" >/dev/null
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 4 ]
retry_digest=$(sha256sum \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${retry_job}.txt" | awk '{print $1}')
"${notifier}" poll
jq -e '.status == "analysis-queued" and .result == "success"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${retry_job}.json" >/dev/null
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 5 ]
[ "$(sha256sum "${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${retry_job}.txt" |
    awk '{print $1}')" = "${retry_digest}" ]
"${notifier}" poll
[ "$(wc -l <"${FAKE_EVENT_CALLS}")" -eq 5 ]

! grep -q 'attacker@example.invalid' "${FAKE_EVENT_CALLS}"
! grep -R -q 'queue-notification' "${HELIUM_JOB_NOTIFY_STATE_ROOT}"

echo "helium job notifier Codex-turn, retry, state, and exactly-once simulations passed"
