#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
worker="${repo_root}/scripts/chromiumer-worker.sh"
wrapper="${repo_root}/scripts/chromiumer-job.sh"
test_root=$(mktemp -d /tmp/helium-resume.XXXXXX)
trap 'find "${test_root}" -depth -delete' EXIT

# shellcheck source=../chromiumer-worker.sh
source "${worker}"
state_root="${test_root}/state"
work_root="${test_root}/work"
mkdir -p "${state_root}" "${work_root}" "${test_root}/bin"

cat >"${test_root}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    "--user --quiet is-active helium-watch-readiness.service")
        [ -e "${RESUME_TEST_WATCH_ACTIVE}" ]
        ;;
    "--user --quiet is-active "*) exit 1 ;;
    "--user stop "*) exit 0 ;;
    *)
        printf 'unexpected systemctl arguments: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod 700 "${test_root}/bin/systemctl"

cat >"${test_root}/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${RESUME_TEST_SYSTEMD_RUNS}"
printf '\n' >>"${RESUME_TEST_SYSTEMD_RUNS}"
EOF
chmod 700 "${test_root}/bin/systemd-run"
cat >"${test_root}/bin/hostname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 1 ] && [ "$1" = -s ]
printf 'chromiumer\n'
EOF
chmod 700 "${test_root}/bin/hostname"
export PATH="${test_root}/bin:${PATH}"
export RESUME_TEST_SYSTEMD_RUNS="${test_root}/systemd-runs"
export RESUME_TEST_WATCH_ACTIVE="${test_root}/watch-active"

preflight() {
    [ "$1" = production ]
    [ "$2" = 1 ]
    [ "$3" = "$4" ]
    [ -d "$3" ]
    printf 'preflight=ok\nworkspace=%s\n' "$3" \
        >>"${test_root}/preflight-calls"
}

write_parent() {
    local job=$1
    local command=$2
    local state="${state_root}/${job}"
    local workspace="${work_root}/${job}"
    mkdir -p "${state}" "${workspace}/source"
    cat >"${state}/stage.env" <<EOF
profile=production
disk_budget_gib=1
disk_budget_bytes=1073741824
workspace_owner=${job}
staged_at=2026-07-23T00:00:00+00:00
EOF
    cat >"${state}/policy.env" <<EOF
profile=production
disk_budget_bytes=1073741824
command=${command}
started_at_epoch=1
EOF
    cat >"${state}/terminal.env" <<'EOF'
state=terminal
result=timeout
exit_code=124
started_at_epoch=1
finished_at_epoch=28801
duration_seconds=28800
reason=systemd stopped the job at its wall-time limit
EOF
    cat >"${state}/source.manifest" <<'EOF'
repository=helium-sync
origin=git@github.com:example/helium-sync.git
commit=1111111111111111111111111111111111111111
tree=2222222222222222222222222222222222222222
helium_submodule=3333333333333333333333333333333333333333
chromium_version=150.0.7871.181
archive_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
transferred_at=2026-07-23T00:00:00+00:00
transferred_from=lm
EOF
    printf 'unfinished-object\n' >"${workspace}/source/object.o"
}

build_command=(sh -c 'printf "resume fixture\n"')
build_command_text=$(command_text "${build_command[@]}")
parent=resume-parent
child=resume-child
write_parent "${parent}" "${build_command_text}"
cat >"${state_root}/${parent}/artifact-returned.env" <<'EOF'
returned_at=2026-07-23T08:00:00+00:00
sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF

resume_init "${parent}" "${child}" -- "${build_command[@]}" \
    >"${test_root}/resume-init.out"
exec 9>&-
grep -Fqx "continuation=${child}" "${test_root}/resume-init.out"
grep -Fqx "parent_job=${parent}" "${test_root}/resume-init.out"
grep -Fqx "workspace_owner=${parent}" "${test_root}/resume-init.out"
grep -Fqx 'existing=false' "${test_root}/resume-init.out"
grep -Fqx "child_job=${child}" \
    "${state_root}/${parent}/continued-by.env"
grep -Fqx "parent_job=${parent}" "${state_root}/${child}/resume.env"
grep -Fqx "workspace_owner=${parent}" "${state_root}/${child}/stage.env"
grep -Fqx "parent_command=${build_command_text}" \
    "${state_root}/${child}/resume.env"
grep -Fqx 'command_mode=exact' "${state_root}/${child}/resume.env"
cmp "${state_root}/${parent}/source.manifest" \
    "${state_root}/${child}/source.manifest"
[ "$(stat -c %a "${state_root}/${child}/source.manifest")" = 600 ]
[ ! -e "${work_root}/${child}" ]

source_report=$(source_info "${child}")
grep -Fqx 'repository=helium-sync' <<<"${source_report}"
grep -Fqx "workspace_owner=${parent}" <<<"${source_report}"
grep -Fqx "parent_job=${parent}" <<<"${source_report}"

# An uncertain client retry is idempotent only for the exact same parent,
# child, source, and command.
resume_init "${parent}" "${child}" -- "${build_command[@]}" \
    >"${test_root}/resume-init-again.out"
grep -Fqx 'existing=true' "${test_root}/resume-init-again.out"
if (resume_init "${parent}" resume-other -- "${build_command[@]}") \
    >"${test_root}/second.out" 2>"${test_root}/second.error"; then
    echo "one timeout parent admitted two continuations" >&2
    exit 1
fi
grep -Fq 'disqualifying state: continued-by.env' \
    "${test_root}/second.error"
if (resume_init "${parent}" resume-wrong -- sh -c 'exit 0') \
    >"${test_root}/wrong.out" 2>"${test_root}/wrong.error"; then
    echo "a changed continuation command was admitted" >&2
    exit 1
fi

# A continuation may make the one fail-closed resource adjustment needed
# after a two-edge linker/compiler memory stall: reduce only AUTONINJA_JOBS
# from two to one. No other command token can change.
reduced_parent=resume-reduced-parent
reduced_child=resume-reduced-child
parallel_command=(env AUTONINJA_JOBS=2 GCLIENT_JOBS=2 sh -c \
    'printf "parallel fixture\n"')
reduced_command=(env AUTONINJA_JOBS=1 GCLIENT_JOBS=2 sh -c \
    'printf "parallel fixture\n"')
write_parent "${reduced_parent}" "$(command_text "${parallel_command[@]}")"
resume_init "${reduced_parent}" "${reduced_child}" -- \
    "${reduced_command[@]}" >"${test_root}/reduced.out"
exec 9>&-
grep -Fqx 'command_mode=reduced-parallelism' \
    "${state_root}/${reduced_child}/resume.env"
grep -Fqx "parent_command=$(command_text "${parallel_command[@]}")" \
    "${state_root}/${reduced_child}/resume.env"
grep -Fqx "command=$(command_text "${reduced_command[@]}")" \
    "${state_root}/${reduced_child}/resume.env"

write_parent resume-increased-parent \
    "$(command_text "${parallel_command[@]}")"
if (resume_init resume-increased-parent resume-increased-child -- \
    env AUTONINJA_JOBS=3 GCLIENT_JOBS=2 sh -c \
        'printf "parallel fixture\n"') \
    >"${test_root}/increased.out" 2>"${test_root}/increased.error"; then
    echo "a continuation increased build parallelism" >&2
    exit 1
fi
grep -Fq 'only reduce AUTONINJA_JOBS from 2 to 1' \
    "${test_root}/increased.error"

write_parent resume-mutated-parent \
    "$(command_text "${parallel_command[@]}")"
if (resume_init resume-mutated-parent resume-mutated-child -- \
    env AUTONINJA_JOBS=1 GCLIENT_JOBS=1 sh -c \
        'printf "parallel fixture\n"') \
    >"${test_root}/mutated.out" 2>"${test_root}/mutated.error"; then
    echo "a continuation changed an unrelated command token" >&2
    exit 1
fi
grep -Fq 'only reduce AUTONINJA_JOBS from 2 to 1' \
    "${test_root}/mutated.error"

resume_start "${child}" -- "${build_command[@]}" \
    >"${test_root}/resume-start.out"
exec 9>&-
[ "$(wc -l <"${RESUME_TEST_SYSTEMD_RUNS}")" -eq 2 ]
grep -Fq -- '--property=RuntimeMaxSec=28800' "${RESUME_TEST_SYSTEMD_RUNS}"
grep -Fq -- '--property=CPUQuota=200%' "${RESUME_TEST_SYSTEMD_RUNS}"
grep -Fq -- '--property=MemoryMax=5G' "${RESUME_TEST_SYSTEMD_RUNS}"
grep -Fq -- '--property=TasksMax=256' "${RESUME_TEST_SYSTEMD_RUNS}"
grep -Fqx "workspace_owner=${parent}" \
    "${state_root}/${child}/policy.env"
grep -Fqx "parent_job=${parent}" "${state_root}/${child}/policy.env"
grep -Fqx "work_dir=${work_root}/${parent}/source" \
    "${state_root}/${child}/policy.env"
grep -Fqx 'watchdog_ready_seconds=600' \
    "${state_root}/${child}/policy.env"
grep -Fq ' helium-watch-resume-child.service 600 1 -- ' \
    "${RESUME_TEST_SYSTEMD_RUNS}"
[ "$(grep -Fc "preflight=ok" "${test_root}/preflight-calls")" -ge 2 ]
if grep '^workspace=' "${test_root}/preflight-calls" |
    grep -Fvx "workspace=${work_root}/${parent}" |
    grep -Fvx "workspace=${work_root}/${reduced_parent}" >/dev/null; then
    echo "continuation preflight accounted the wrong workspace" >&2
    exit 1
fi
grep -Fqx "workspace=${work_root}/${parent}" \
    "${test_root}/preflight-calls"
grep -Fqx "workspace=${work_root}/${reduced_parent}" \
    "${test_root}/preflight-calls"

cat >"${state_root}/${child}/terminal.env" <<'EOF'
state=terminal
result=success
exit_code=0
started_at_epoch=1
finished_at_epoch=2
duration_seconds=1
reason=build command completed
EOF
resume_start "${child}" -- "${build_command[@]}" \
    >"${test_root}/resume-start-again.out"
grep -Fqx 'existing=true' "${test_root}/resume-start-again.out"
[ "$(wc -l <"${RESUME_TEST_SYSTEMD_RUNS}")" -eq 2 ]

# Readiness is a proof gate: even an otherwise runnable command cannot begin
# until the independent watcher publishes its initial healthy scan.
readiness_state="${test_root}/readiness-state"
mkdir "${readiness_state}"
cat >"${readiness_state}/policy.env" <<EOF
started_at_epoch=$(date +%s)
EOF
: >"${RESUME_TEST_WATCH_ACTIVE}"
timeout 10 "${worker}" run "${readiness_state}" \
    helium-watch-readiness.service 6 1 -- \
    sh -c ': >"$1"' sh "${test_root}/command-started" &
readiness_pid=$!
sleep 2
[ ! -e "${test_root}/command-started" ]
printf 'watchdog_ready_at=%s\n' "$(date --iso-8601=seconds)" \
    >"${readiness_state}/watchdog-ready.env"
wait "${readiness_pid}"
grep -Fqx 'result=success' "${readiness_state}/terminal.env"
[ -e "${test_root}/command-started" ]
find "${RESUME_TEST_WATCH_ACTIVE}" -delete

artifact_report=$(artifact_info "${child}" object.o)
artifact_sha=$(awk -F= '$1 == "sha256" { print $2 }' <<<"${artifact_report}")
[ -n "${artifact_sha}" ]
mark_returned "${child}" "${artifact_sha}"
if (cleanup_job "${parent}") >"${test_root}/parent-cleanup.out" \
    2>"${test_root}/parent-cleanup.error"; then
    echo "a superseded segment cleaned the shared workspace" >&2
    exit 1
fi
grep -Fq 'segment that has a continuation' \
    "${test_root}/parent-cleanup.error"
cleanup_job "${child}" >"${test_root}/cleanup.out"
exec 9>&-
[ ! -e "${work_root}/${parent}" ]
grep -Fqx "cleaned_by_job=${child}" \
    "${state_root}/${parent}/workspace-cleaned-by.env"
if (cleanup_job "${child}") >"${test_root}/cleanup-again.out" \
    2>"${test_root}/cleanup-again.error"; then
    echo "shared workspace cleanup ran twice" >&2
    exit 1
fi
grep -Fq 'workspace was already cleaned' "${test_root}/cleanup-again.error"

abort_parent=abort-parent
abort_child=abort-child
write_parent "${abort_parent}" "${build_command_text}"
resume_init "${abort_parent}" "${abort_child}" -- "${build_command[@]}" \
    >/dev/null
exec 9>&-
resume_abort "${abort_child}" >"${test_root}/abort.out"
exec 9>&-
[ ! -e "${state_root}/${abort_child}" ]
[ ! -e "${state_root}/${abort_parent}/continued-by.env" ]
[ -e "${work_root}/${abort_parent}/source/object.o" ]
cat >"${state_root}/${abort_parent}/watchdog-stop.env" <<'EOF'
reason=synthetic watchdog failure
EOF
if (resume_init "${abort_parent}" watchdog-child -- "${build_command[@]}") \
    >"${test_root}/watchdog.out" 2>"${test_root}/watchdog.error"; then
    echo "a watchdog-stopped parent was resumed" >&2
    exit 1
fi
grep -Fq 'disqualifying state: watchdog-stop.env' \
    "${test_root}/watchdog.error"

# The public control client must arm a unique Mailbridge-observed job before
# asking the worker to launch it, and expose the one-command interface.
grep -Fq 'resume <timed-out-job> <new-job-id>' "${wrapper}"
register_line=$(grep -n '"${local_notifier}" register "${job}"' "${wrapper}" |
    tail -1 | cut -d: -f1)
start_line=$(grep -n 'resume-start "${job}"' "${wrapper}" | cut -d: -f1)
[ "${register_line}" -lt "${start_line}" ]
grep -Fq 'resume-init "${parent}" "${job}" -- "$@"' "${wrapper}"
grep -Fq 'resume-abort "${job}"' "${wrapper}"

printf 'chromiumer_resume=passed\n'
printf 'parent_job=%s\ncontinuation_job=%s\n' "${parent}" "${child}"
printf 'systemd_segments=%s\n' 1
