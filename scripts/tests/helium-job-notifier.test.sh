#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-job-notifier-test.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/remote"

source_info="${test_root}/source.env"
cat >"${source_info}" <<'EOF'
repository=helium-passwords
commit=abc123
tree=tree123
helium_submodule=def456
chromium_version=150.0.7871.181
HELIUM_ANDROID_CHROMIUM_COMMIT=chromium123
HELIUM_ANDROID_CORE_COMMIT=core123
HELIUM_ANDROID_DEPOT_TOOLS_COMMIT=depot123
workspace_owner=preserved-owner
parent_job=timed-out-parent
EOF
chmod 600 "${source_info}"

fake_chromium_ssh="${test_root}/chromium-ssh"
cat >"${fake_chromium_ssh}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
job=${!#}
cat "${FAKE_REMOTE_ROOT}/${job}.env"
EOF
chmod 700 "${fake_chromium_ssh}"

export HELIUM_JOB_NOTIFY_STATE_ROOT="${test_root}/state"
export HELIUM_JOB_NOTIFY_SSH="${fake_chromium_ssh}"
export FAKE_REMOTE_ROOT="${test_root}/remote"
notifier="${root_dir}/scripts/helium-job-notifier.sh"

legacy_bridge=/home/d/coding/codex-"mail""bridge"
for retired_token in "${legacy_bridge}" queue-"import-helium" HELIUM_WORK_"QUEUE" \
    HELIUM_"MAIL""BRIDGE" queue-"event" event-"status"; do
    ! grep -Fq "${retired_token}" "${notifier}"
done
! grep -Eq '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "${notifier}"

declare -A exit_codes=(
    [success]=0
    [failure]=1
    [timeout]=124
    [cancellation]=130
)
for result in success failure timeout cancellation; do
    job="test-${result}"
    "${notifier}" register "${job}" "Helium Passwords" "Synthetic ${result} proof" \
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
for result in success failure timeout cancellation; do
    job="test-${result}"
    state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${job}.json"
    jq -e --arg result "${result}" --argjson exit_code "${exit_codes[${result}]}" '
        .schema == 3 and .status == "terminal-recorded" and .result == $result and
        .exit_code == $exit_code and .duration_seconds == 61 and
        .terminal_reason == ("synthetic " + $result + " evidence") and
        .last_poll_error == null and
        (has("analysis_key") | not) and (has("conversation") | not) and
        ([keys[] | startswith("analysis_")] | any | not)
    ' "${state}" >/dev/null
done
[ ! -e "${HELIUM_JOB_NOTIFY_STATE_ROOT}/events" ]

# Repeated and concurrent polls preserve each locally recorded terminal result.
before_digest=$(find "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs" -type f -name '*.json' \
    -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
"${notifier}" poll
("${notifier}" poll) &
("${notifier}" poll) &
wait
after_digest=$(find "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs" -type f -name '*.json' \
    -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
[ "${before_digest}" = "${after_digest}" ]

# A transient Chromiumer failure leaves a job watched and the next poll records
# the real terminal result without requiring a delivery adapter.
delayed_job=test-delayed
"${notifier}" register "${delayed_job}" "Helium Passwords" \
    "Synthetic delayed terminal proof" "Inspect the synthetic artifact." \
    "${source_info}" >/dev/null
"${notifier}" poll
delayed_state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${delayed_job}.json"
jq -e '.schema == 3 and .status == "watching" and
       .last_poll_error == "chromiumer unavailable"' "${delayed_state}" >/dev/null
cat >"${FAKE_REMOTE_ROOT}/${delayed_job}.env" <<'EOF'
state=terminal
result=success
exit_code=0
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic delayed evidence
EOF
"${notifier}" poll
jq -e '.schema == 3 and .status == "terminal-recorded" and .result == "success" and
       .last_poll_error == null' "${delayed_state}" >/dev/null

# Delivery-era terminal state migrates to an ordinary locally recorded result
# without contacting a former queue or retaining its key fields.
legacy_state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-legacy.json"
cat >"${legacy_state}" <<'EOF'
{
  "schema": 1,
  "job_id": "test-legacy",
  "product": "Helium Passwords",
  "summary": "Synthetic legacy record",
  "success_next": "Inspect it.",
  "source_commits": "repository=helium-passwords",
  "remote_host": "chromiumer",
  "notification_key": "helium-build:test-legacy:terminal",
  "status": "notification-queued",
  "result": "failure",
  "duration_seconds": 31,
  "exit_code": 1,
  "terminal_reason": "synthetic legacy evidence",
  "last_poll_error": null
}
EOF
chmod 600 "${legacy_state}"
"${notifier}" poll
jq -e '.schema == 3 and .status == "terminal-recorded" and .result == "failure" and
       (has("notification_key") | not) and (has("analysis_key") | not) and
       (has("conversation") | not) and
       ([keys[] | startswith("analysis_")] | any | not)' "${legacy_state}" >/dev/null

echo "helium job notifier terminal-state monitoring simulations passed"
