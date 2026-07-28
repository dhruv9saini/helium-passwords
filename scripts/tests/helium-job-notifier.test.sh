#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
test_root=$(mktemp -d /tmp/helium-job-notifier-test.XXXXXX)
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/remote" "${test_root}/queue-items"

source_info="${test_root}/source.env"
cat >"${source_info}" <<'EOF'
repository=helium-sync
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

fake_queue_ssh="${test_root}/queue-ssh"
cat >"${fake_queue_ssh}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${!#}" = queue-import-helium ]
payload=$(mktemp "${FAKE_QUEUE_ROOT}/incoming.XXXXXX")
trap 'find "${payload}" -delete' EXIT
cat >"${payload}"
jq -e '
  . as $item |
  ($item.source_ref | test("^helium-build:[a-z0-9][a-z0-9-]{0,47}:terminal$")) and
  $item.item_key == ("local:" + $item.source_ref) and
  $item.source_kind == "local" and
  $item.title == "Helium build operations" and
  $item.sender == null and
  $item.metadata == {event_key: $item.source_ref} and
  $item.response_policy == "important_only" and
  ($item.body | startswith("[trusted local queue event " + $item.source_ref + "]\n\n"))
' "${payload}" >/dev/null
key=$(jq -r .source_ref "${payload}")
printf '%s\n' "${key}" >>"${FAKE_QUEUE_ATTEMPTS}"
if [ "${key}" = "${FAKE_QUEUE_CONFLICT_KEY:-}" ]; then
    exit 2
fi
if [ -n "${FAKE_QUEUE_FAIL_ONCE:-}" ] && [ ! -e "${FAKE_QUEUE_FAIL_ONCE}" ]; then
    touch "${FAKE_QUEUE_FAIL_ONCE}"
    exit 75
fi
record="${FAKE_QUEUE_ROOT}/${key}.json"
if [ -e "${record}" ]; then
    cmp --silent "${payload}" "${record}" || exit 2
else
    cp "${payload}" "${record}"
    chmod 600 "${record}"
fi
printf '%s\n' "${key}" >>"${FAKE_QUEUE_SUCCESSES}"
printf '{"item_key":"local:%s","status":"queued"}\n' "${key}"
EOF
chmod 700 "${fake_queue_ssh}"

queue_identity="${test_root}/queue-identity"
queue_known_hosts="${test_root}/queue-known-hosts"
touch "${queue_identity}" "${queue_known_hosts}"
chmod 600 "${queue_identity}" "${queue_known_hosts}"

export HELIUM_JOB_NOTIFY_STATE_ROOT="${test_root}/state"
export HELIUM_JOB_NOTIFY_SSH="${fake_chromium_ssh}"
export HELIUM_WORK_QUEUE_SSH="${fake_queue_ssh}"
export HELIUM_WORK_QUEUE_IDENTITY="${queue_identity}"
export HELIUM_WORK_QUEUE_KNOWN_HOSTS="${queue_known_hosts}"
export HELIUM_JOB_NOTIFY_RECIPIENT=attacker@example.invalid
export FAKE_REMOTE_ROOT="${test_root}/remote"
export FAKE_QUEUE_ROOT="${test_root}/queue-items"
export FAKE_QUEUE_ATTEMPTS="${test_root}/queue-attempts"
export FAKE_QUEUE_SUCCESSES="${test_root}/queue-successes"
notifier="${root_dir}/scripts/helium-job-notifier.sh"

! grep -q '/home/d/coding/codex-mailbridge' "${notifier}"
! grep -Eq 'queue-(event|notification)|event-status' "${notifier}"
! grep -q 'HELIUM_JOB_NOTIFY_RECIPIENT' "${notifier}"
! grep -Eq '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "${notifier}"
grep -q 'queue-import-helium' "${notifier}"
grep -q 'response_policy: "important_only"' "${notifier}"

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
[ "$(wc -l <"${FAKE_QUEUE_SUCCESSES}")" -eq 4 ]
for result in success failure timeout cancellation; do
    job="test-${result}"
    key="helium-build:${job}:terminal"
    state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${job}.json"
    event="${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${job}.txt"
    payload="${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${job}.queue.json"
    jq -e --arg result "${result}" \
        '.schema == 2 and .status == "analysis-queued" and .result == $result and
         .analysis_key == ("helium-build:" + .job_id + ":terminal") and
         .conversation == "Helium build operations" and
         .last_poll_error == null' "${state}" >/dev/null
    [ "$(stat -c %a "${event}")" = 600 ]
    [ "$(stat -c %a "${payload}")" = 600 ]
    grep -q "Terminal state: ${result}" "${event}"
    grep -q "Exit code: ${exit_codes[${result}]}" "${event}"
    grep -q "Recorded reason: synthetic ${result} evidence" "${event}"
    grep -q 'HELIUM_ANDROID_CHROMIUM_COMMIT=chromium123' "${event}"
    grep -q "scripts/chromiumer-job.sh logs ${job} 400" "${event}"
    grep -q 'Continuation parent: timed-out-parent' "${event}"
    grep -q 'Preserved workspace owner: preserved-owner' "${event}"
    grep -q 'outbound delivery requires an explicit user request after review' "${event}"
    jq -e --arg key "${key}" \
        '.item_key == ("local:" + $key) and .source_ref == $key and
         .source_kind == "local" and .response_policy == "important_only" and
         .metadata == {event_key: $key}' "${payload}" >/dev/null
    cmp --silent "${payload}" "${FAKE_QUEUE_ROOT}/${key}.json"
done

# Repeated, concurrent, and restart-style polls do not import another item.
"${notifier}" poll
("${notifier}" poll) &
("${notifier}" poll) &
wait
[ "$(wc -l <"${FAKE_QUEUE_SUCCESSES}")" -eq 4 ]

# A temporary queue failure retains byte-identical evidence and envelope, then
# a fresh notifier process retries the immutable item successfully.
retry_job=test-retry
retry_key="helium-build:${retry_job}:terminal"
"${notifier}" register "${retry_job}" "Helium Passwords" \
    "Synthetic temporary da queue failure" "Inspect the synthetic artifact." \
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
export FAKE_QUEUE_FAIL_ONCE="${test_root}/queue-failed-once"
"${notifier}" poll
retry_state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${retry_job}.json"
retry_event="${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${retry_job}.txt"
retry_payload="${HELIUM_JOB_NOTIFY_STATE_ROOT}/events/${retry_job}.queue.json"
jq -e '.status == "terminal-pending" and
       .last_poll_error == "da work queue unavailable"' "${retry_state}" >/dev/null
event_digest=$(sha256sum "${retry_event}" | awk '{print $1}')
payload_digest=$(sha256sum "${retry_payload}" | awk '{print $1}')
"${notifier}" poll
jq -e '.status == "analysis-queued" and .result == "success" and
       .last_poll_error == null' "${retry_state}" >/dev/null
[ "$(sha256sum "${retry_event}" | awk '{print $1}')" = "${event_digest}" ]
[ "$(sha256sum "${retry_payload}" | awk '{print $1}')" = "${payload_digest}" ]
[ "$(grep -cFx "${retry_key}" "${FAKE_QUEUE_ATTEMPTS}")" -eq 2 ]
[ "$(grep -cFx "${retry_key}" "${FAKE_QUEUE_SUCCESSES}")" -eq 1 ]
"${notifier}" poll
[ "$(grep -cFx "${retry_key}" "${FAKE_QUEUE_ATTEMPTS}")" -eq 2 ]

# A changed immutable binding fails closed and never invents another key.
conflict_job=test-conflict
conflict_key="helium-build:${conflict_job}:terminal"
"${notifier}" register "${conflict_job}" "Helium Sync" \
    "Synthetic immutable queue conflict" "Inspect the conflict." \
    "${source_info}" >/dev/null
cat >"${FAKE_REMOTE_ROOT}/${conflict_job}.env" <<'EOF'
state=terminal
result=failure
exit_code=125
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic immutable conflict
EOF
export FAKE_QUEUE_CONFLICT_KEY="${conflict_key}"
"${notifier}" poll
conflict_state="${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${conflict_job}.json"
jq -e '.status == "analysis-conflict" and
       .last_poll_error == "da queue rejected immutable event input"' \
    "${conflict_state}" >/dev/null
[ "$(grep -cFx "${conflict_key}" "${FAKE_QUEUE_ATTEMPTS}")" -eq 1 ]
"${notifier}" poll
[ "$(grep -cFx "${conflict_key}" "${FAKE_QUEUE_ATTEMPTS}")" -eq 1 ]

! grep -R -q 'attacker@example.invalid' "${HELIUM_JOB_NOTIFY_STATE_ROOT}"
echo "helium job notifier da-queue, retry, conflict, and restart simulations passed"
