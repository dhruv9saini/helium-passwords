#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
test_root=$(mktemp -d /tmp/helium-job-notifier-test.XXXXXX)
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/remote"

source_info="${test_root}/source.env"
printf 'repository=helium-sync\ncommit=abc123\nhelium_submodule=def456\n' >"${source_info}"
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
if [ -n "${FAKE_MAIL_FAIL_ONCE:-}" ] && [ ! -e "${FAKE_MAIL_FAIL_ONCE}" ]; then
    touch "${FAKE_MAIL_FAIL_ONCE}"
    exit 75
fi
key=
body=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --key) key=$2; shift 2 ;;
        --body-file) body=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\t%s\n' "${key}" "$(sha256sum "${body}" | awk '{print $1}')" \
    >>"${FAKE_MAIL_CALLS}"
EOF
chmod 700 "${fake_mailbridge}"

export HELIUM_JOB_NOTIFY_STATE_ROOT="${test_root}/state"
export HELIUM_JOB_NOTIFY_SSH="${fake_ssh}"
export HELIUM_MAILBRIDGE_CLI="${fake_mailbridge}"
export HELIUM_MAILBRIDGE_CONFIG="${test_root}/unused.toml"
export FAKE_REMOTE_ROOT="${test_root}/remote"
export FAKE_MAIL_CALLS="${test_root}/mail-calls"
notifier="${root_dir}/scripts/helium-job-notifier.sh"

for result in success failure timeout cancellation; do
    job="test-${result}"
    "${notifier}" register "${job}" "Helium Sync" "Synthetic ${result} proof" \
        "Fetch the synthetic artifact." "${source_info}" >/dev/null
    cat >"${FAKE_REMOTE_ROOT}/${job}.env" <<EOF
state=terminal
result=${result}
exit_code=0
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic ${result}
EOF
done

"${notifier}" poll
[ "$(wc -l <"${FAKE_MAIL_CALLS}")" -eq 4 ]
for result in success failure timeout cancellation; do
    jq -e --arg result "${result}" \
        '.status == "notification-queued" and .result == $result' \
        "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/test-${result}.json" >/dev/null
    grep -q "Result: ${result}" \
        "${HELIUM_JOB_NOTIFY_STATE_ROOT}/bodies/test-${result}.txt"
done

"${notifier}" poll
[ "$(wc -l <"${FAKE_MAIL_CALLS}")" -eq 4 ]

retry_job=test-retry
"${notifier}" register "${retry_job}" "Helium Passwords" \
    "Synthetic temporary Mailbridge failure" "Fetch the synthetic artifact." \
    "${source_info}" >/dev/null
cat >"${FAKE_REMOTE_ROOT}/${retry_job}.env" <<EOF
state=terminal
result=success
exit_code=0
started_at_epoch=1
finished_at_epoch=62
duration_seconds=61
reason=synthetic retry
EOF
export FAKE_MAIL_FAIL_ONCE="${test_root}/mail-failed-once"
"${notifier}" poll
jq -e '.status == "terminal-pending" and
       .last_poll_error == "mailbridge queue unavailable"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${retry_job}.json" >/dev/null
[ "$(wc -l <"${FAKE_MAIL_CALLS}")" -eq 4 ]
"${notifier}" poll
jq -e '.status == "notification-queued" and .result == "success"' \
    "${HELIUM_JOB_NOTIFY_STATE_ROOT}/jobs/${retry_job}.json" >/dev/null
[ "$(wc -l <"${FAKE_MAIL_CALLS}")" -eq 5 ]
"${notifier}" poll
[ "$(wc -l <"${FAKE_MAIL_CALLS}")" -eq 5 ]

echo "helium job notifier terminal, retry, and exactly-once simulations passed"
