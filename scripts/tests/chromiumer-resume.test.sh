#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-chromiumer-resume.XXXXXX)
cleanup() {
    find "$test_root" -depth -delete
}
trap cleanup EXIT

export HELIUM_CHROMIUMER_STATE_ROOT="$test_root/state"
export HELIUM_CHROMIUMER_WORK_ROOT="$test_root/work"
# shellcheck source=../chromiumer-worker.sh
source "$repo_root/scripts/chromiumer-worker.sh"

require_worker_host() {
    :
}
preflight() {
    printf 'test_preflight_profile=%s\n' "$1"
    printf 'test_preflight_budget_gib=%s\n' "$2"
    printf 'test_preflight_probe=%s\n' "$3"
    printf 'test_preflight_accounted=%s\n' "$4"
}

source_job=resume-source
destination_job=resume-destination
source_state="$HELIUM_CHROMIUMER_STATE_ROOT/$source_job"
source_root="$HELIUM_CHROMIUMER_WORK_ROOT/$source_job"
mkdir -p "$source_state" "$source_root/source/.build/out"
cat >"$source_state/stage.env" <<'EOF'
profile=production
disk_budget_gib=80
disk_budget_bytes=85899345920
staged_at=2026-07-23T00:00:00+00:00
EOF
cat >"$source_state/source.manifest" <<'EOF'
repository=helium-sync
commit=1111111111111111111111111111111111111111
tree=2222222222222222222222222222222222222222
EOF
cat >"$source_state/terminal.env" <<'EOF'
state=terminal
result=timeout
exit_code=124
EOF
printf 'sha256=3333333333333333333333333333333333333333333333333333333333333333\n' \
    >"$source_state/artifact-returned.env"
printf 'retained Ninja state\n' >"$source_root/source/.build/out/.ninja_log"

output=$(resume_stage "$source_job" "$destination_job")
destination_state="$HELIUM_CHROMIUMER_STATE_ROOT/$destination_job"
destination_root="$HELIUM_CHROMIUMER_WORK_ROOT/$destination_job"

[[ ! -e "$source_root" ]]
[[ -f "$destination_root/source/.build/out/.ninja_log" ]]
grep -qx 'retained Ninja state' \
    "$destination_root/source/.build/out/.ninja_log"
cmp "$source_state/source.manifest" "$destination_state/source.manifest"
cmp "$source_state/stage.env" "$destination_state/stage.env"
grep -qx "resumed_from_job=$source_job" "$destination_state/resume.env"
grep -qx 'resumed_from_result=timeout' "$destination_state/resume.env"
grep -qx 'disk_budget_bytes=85899345920' "$destination_state/resume.env"
grep -qx "resumed_to_job=$destination_job" "$source_state/resumed-to.env"
grep -qx "resume_source_job=$source_job" <<<"$output"
grep -qx "resume_destination_job=$destination_job" <<<"$output"
grep -qx "source_dir=$destination_root/source" <<<"$output"

failed_job=failed-source
failed_state="$HELIUM_CHROMIUMER_STATE_ROOT/$failed_job"
failed_root="$HELIUM_CHROMIUMER_WORK_ROOT/$failed_job"
mkdir -p "$failed_state" "$failed_root/source"
cp "$source_state/stage.env" "$failed_state/stage.env"
cp "$source_state/source.manifest" "$failed_state/source.manifest"
printf 'state=terminal\nresult=failure\nexit_code=1\n' \
    >"$failed_state/terminal.env"
cp "$source_state/artifact-returned.env" \
    "$failed_state/artifact-returned.env"
if (resume_stage "$failed_job" refused-destination) \
    >"$test_root/refused.out" 2>&1; then
    echo 'non-timeout resume source unexpectedly passed' >&2
    exit 1
fi
grep -qx \
    "resume source did not terminate at its wall-time limit: $failed_job" \
    "$test_root/refused.out"
[[ -d "$failed_root/source" ]]
[[ ! -e "$HELIUM_CHROMIUMER_WORK_ROOT/refused-destination" ]]
[[ ! -e "$HELIUM_CHROMIUMER_STATE_ROOT/refused-destination" ]]

grep -Fq 'resume-stage <terminal-job-id> <new-job-id>' \
    "$repo_root/scripts/chromiumer-job.sh"
grep -Fq 'resume-stage) [ "$#" -eq 2 ] || exit 2; resume_stage "$@" ;;' \
    "$repo_root/scripts/chromiumer-job.sh"

echo 'Chromiumer retained timeout resume contract passed'
