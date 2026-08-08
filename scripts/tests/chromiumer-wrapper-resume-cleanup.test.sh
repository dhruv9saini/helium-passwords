#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
wrapper="${repo_root}/scripts/chromiumer-job.sh"
runtime_root=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export WRAPPER_RESUME_REAL_MKTEMP=$(command -v mktemp)
test_root=$(mktemp -d "${runtime_root}/helium-wrapper-resume.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/bin"

cat >"${test_root}/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod 700 "${test_root}/bin/rsync"

cat >"${test_root}/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *helium-notification.XXXXXX* ]]; then
    printf '%s\n' "$*" >>"${WRAPPER_RESUME_TEST_ROOT}/mktemp.log"
    attempt=0
    if [[ -f "${WRAPPER_RESUME_TEST_ROOT}/mktemp-attempt" ]]; then
        attempt=$(<"${WRAPPER_RESUME_TEST_ROOT}/mktemp-attempt")
    fi
    attempt=$((attempt + 1))
    printf '%s\n' "${attempt}" >"${WRAPPER_RESUME_TEST_ROOT}/mktemp-attempt"
    if [[ "${attempt}" -eq 1 ]]; then
        directory="${WRAPPER_RESUME_TEST_ROOT}/unwritable-notification"
        mkdir "${directory}"
        chmod 500 "${directory}"
        printf '%s\n' "${directory}"
        exit 0
    fi
    exec "$WRAPPER_RESUME_REAL_MKTEMP" -d \
        "${WRAPPER_RESUME_TEST_ROOT}/notification.XXXXXX"
fi
exec "$WRAPPER_RESUME_REAL_MKTEMP" "$@"
EOF
chmod 700 "${test_root}/bin/mktemp"

cat >"${test_root}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && "$1" == chromiumer ]]
command_text=$2
printf '%s\n' "${command_text}" >>"${WRAPPER_RESUME_TEST_ROOT}/remote.log"
case "${command_text}" in
    *" source-info "*)
        cat <<'REPORT'
repository=helium-sync
origin=https://github.com/example/helium-sync.git
commit=1111111111111111111111111111111111111111
tree=2222222222222222222222222222222222222222
helium_submodule=3333333333333333333333333333333333333333
chromium_version=150.0.7871.181
archive_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
workspace_owner=resume-parent
parent_job=resume-parent
REPORT
        ;;
    *" resume-init "*)
        printf '%s\n' \
            continuation=resume-child \
            parent_job=resume-parent \
            workspace_owner=resume-parent \
            existing=false
        ;;
    *" resume-abort "*)
        printf 'aborted=resume-child\n'
        ;;
    *" resume-start "*)
        printf '%s\n' \
            job=resume-child \
            unit=helium-job-resume-child.service \
            watch_unit=helium-watch-resume-child.service
        ;;
    *) ;;
esac
EOF
chmod 700 "${test_root}/bin/ssh"

cat >"${test_root}/management" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${WRAPPER_RESUME_TEST_ROOT}/management.log"
case "$1" in
    register) printf 'registered=%s\nexisting=false\n' "$2" ;;
    unregister) printf 'unregistered=%s\n' "$2" ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "${test_root}/management"

cat >"${test_root}/notifier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${WRAPPER_RESUME_TEST_ROOT}/notifier.log"
case "$1" in
    register) printf 'registered=%s\nexisting=false\n' "$2" ;;
    abandon) printf 'abandoned=%s\n' "$2" ;;
    *) exit 2 ;;
esac
EOF
chmod 700 "${test_root}/notifier"

export WRAPPER_RESUME_TEST_ROOT="${test_root}"
export PATH="${test_root}/bin:${PATH}"
wrapper_env=(
    HELIUM_CHROMIUMER_HOST=chromiumer
    HELIUM_CHROMIUMER_MANAGEMENT="${test_root}/management"
    HELIUM_JOB_NOTIFIER="${test_root}/notifier"
)
resume_args=(
    resume resume-parent resume-child
    --summary "Synthetic continuation"
    --next "Verify the returned artifact."
    --
    env AUTONINJA_JOBS=1 GCLIENT_JOBS=1 sh -c :
)

set +e
env "${wrapper_env[@]}" "${wrapper}" "${resume_args[@]}" \
    >"${test_root}/first.out" 2>"${test_root}/first.err"
first_status=$?
set -e
[[ "${first_status}" -ne 0 ]]
grep -Fq 'Permission denied' "${test_root}/first.err"
grep -Fqx -- "-d /run/user/$(id -u)/helium-notification.XXXXXX" \
    "${test_root}/mktemp.log"
if grep -Fq 'unbound variable' "${test_root}/first.err"; then
    echo "resume cleanup lost its function-local state" >&2
    exit 1
fi
grep -Fq ' resume-abort ' "${test_root}/remote.log"
grep -Fqx 'unregister resume-child' "${test_root}/management.log"
[[ ! -e "${test_root}/unwritable-notification" ]]

env "${wrapper_env[@]}" "${wrapper}" "${resume_args[@]}" \
    >"${test_root}/retry.out" 2>"${test_root}/retry.err"
grep -Fqx 'notification=armed' "${test_root}/retry.out"
grep -Fq ' resume-start ' "${test_root}/remote.log"
grep -Fq 'register resume-child Helium Sync Synthetic continuation' \
    "${test_root}/notifier.log"
[[ "$(wc -l <"${test_root}/mktemp.log")" -eq 2 ]]
[[ -z "$(find "${test_root}" -maxdepth 1 \
    -type d -name 'notification.*' -print -quit)" ]]

printf 'chromiumer_wrapper_resume_cleanup=passed\n'
