#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
worker="${root_dir}/scripts/chromiumer-worker.sh"
host=${HELIUM_CHROMIUMER_HOST:-chromiumer}
remote_worker=.local/libexec/helium-chromiumer-worker
remote_state=.local/state/helium-builds
remote_work=helium-builds/work
default_artifact_root=${HELIUM_ARTIFACT_ROOT:-/srv/nas/helium-builds}
local_notifier=${HELIUM_JOB_NOTIFIER:-/home/d/.local/libexec/helium-job-notifier}
local_management=${HELIUM_CHROMIUMER_MANAGEMENT:-/home/d/.local/libexec/helium-chromiumer-management}
notification_runtime_dir="/run/user/$(id -u)"
local_source_staging=/home/d/.local/state/helium-builds/source-staging

usage() {
    cat >&2 <<'EOF'
usage: scripts/chromiumer-job.sh <command> [arguments]

Commands:
  connection
  preflight <disk-budget-gib>
  stage <job-id> <disk-budget-gib> [repository]
  start <job-id> --summary <text> --next <success-action> -- <command> [arguments...]
  resume <timed-out-job> <new-job-id> --summary <text> --next <success-action> -- <command> [arguments...]
  status <job-id>
  terminal <job-id>
  limits <job-id>
  logs <job-id> [line-count]
  cancel <job-id>
  management-status <job-id>
  fetch <job-id> <relative-artifact> [lm-or-NAS-directory]
  cleanup <job-id>
  test
EOF
}

validate_job() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
        echo "invalid job id: $1" >&2
        exit 2
    }
}

validate_disk_budget() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || {
        echo "disk budget must be a positive whole number of GiB: $1" >&2
        exit 2
    }
}

remote_exec() {
    local command_text
    printf -v command_text '%q ' "$@"
    ssh "${host}" "${command_text}"
}

install_worker() {
    remote_exec mkdir -p .local/libexec
    rsync --archive --checksum --chmod=F700 "${worker}" "${host}:${remote_worker}"
}

connection() {
    ssh -o BatchMode=yes "${host}" \
        'printf "connection=ok\nhost=%s\nuser=%s\n" "$(hostname -s)" "$(id -un)"'
}

preflight() {
    local disk_budget_gib=$1
    validate_disk_budget "${disk_budget_gib}"
    install_worker
    remote_exec "${remote_worker}" preflight production \
        "${disk_budget_gib}" "${remote_work}"
}

stage() (
    local job=$1
    local disk_budget_gib=$2
    local repository=${3:-"${root_dir}"}
    validate_job "${job}"
    validate_disk_budget "${disk_budget_gib}"
    repository=$(realpath -e "${repository}")
    [ -d "${repository}/.git" ] || {
        echo "not a Git repository: ${repository}" >&2
        exit 1
    }
    [ -z "$(git -C "${repository}" status --porcelain --untracked-files=normal --ignore-submodules=none)" ] || {
        echo "refusing to stage a dirty repository" >&2
        exit 1
    }

    local stage_initialized=false
    local stage_finished=false
    local temp_dir=
    cleanup_stage() {
        local result=$?
        if [ -n "${temp_dir}" ] && [ -d "${temp_dir}" ]; then
            find "${temp_dir}" -depth -delete
        fi
        if [ "${stage_initialized}" = true ] && [ "${stage_finished}" = false ]; then
            remote_exec "${remote_worker}" stage-abort "${job}" >/dev/null 2>&1 || true
        fi
        return "${result}"
    }
    trap cleanup_stage EXIT

    install_worker
    remote_exec "${remote_worker}" stage-init "${job}" "${disk_budget_gib}"
    stage_initialized=true

    local archive checkout manifest archive_sha helium_submodule
    local repository_commit repository_origin core_origin
    local passwords_ref passwords_commit source_depth
    [ ! -L "${local_source_staging}" ] || {
        echo "local source staging root must not be a symlink: ${local_source_staging}" >&2
        exit 1
    }
    mkdir -p "${local_source_staging}"
    [ -d "${local_source_staging}" ] && [ ! -L "${local_source_staging}" ] || {
        echo "invalid local source staging root: ${local_source_staging}" >&2
        exit 1
    }
    chmod 700 "${local_source_staging}"
    temp_dir=$(mktemp -d \
        "${local_source_staging}/helium-source.XXXXXX")
    archive="${temp_dir}/source.tar"
    checkout="${temp_dir}/source"
    manifest="${temp_dir}/source.manifest.incoming"

    repository_commit=$(git -C "${repository}" rev-parse HEAD)
    repository_origin=$(git -C "${repository}" remote get-url origin)
    helium_submodule=$(git -C "${repository}" rev-parse HEAD:helium-chromium)
    core_origin=$(git -C "${repository}/helium-chromium" remote get-url origin)
    [ "$(git -C "${repository}/helium-chromium" rev-parse HEAD)" = \
        "${helium_submodule}" ] || {
        echo "helium-chromium checkout does not match the committed gitlink" >&2
        exit 1
    }

    passwords_ref=$(awk -F= '
        $1 == "HELIUM_LINUX_PASSWORDS_REF" { count += 1; value = $2 }
        END { if (count == 1) print value; else exit 1 }
    ' "${repository}/linux-product.conf") || {
        echo "Linux product binding must contain one Passwords ref" >&2
        exit 1
    }
    passwords_commit=$(git -C "${repository}" rev-parse --verify \
        "${passwords_ref}^{commit}") || {
        echo "Linux product Passwords ref is unavailable" >&2
        exit 1
    }
    git -C "${repository}" merge-base --is-ancestor \
        "${passwords_commit}" "${repository_commit}" || {
        echo "Linux product Passwords ref is not a source ancestor" >&2
        exit 1
    }
    source_depth=$((
        $(git -C "${repository}" rev-list --ancestry-path --count \
            "${passwords_commit}..${repository_commit}") + 1
    ))

    git init --quiet "${checkout}"
    git -C "${checkout}" fetch --quiet --depth="${source_depth}" \
        "file://${repository}" "${repository_commit}"
    git -C "${checkout}" checkout --quiet --detach FETCH_HEAD
    git -C "${checkout}" -c protocol.file.allow=always \
        -c "submodule.helium-chromium.url=file://${repository}/helium-chromium" \
        submodule update --quiet --init --depth=1
    [ "$(git -C "${checkout}" rev-parse HEAD)" = "${repository_commit}" ] && \
        [ "$(git -C "${checkout}/helium-chromium" rev-parse HEAD)" = \
            "${helium_submodule}" ] || {
        echo "materialized source checkout does not match the committed revisions" >&2
        exit 1
    }
    git -C "${checkout}" remote add origin "${repository_origin}"
    git -C "${checkout}/helium-chromium" remote set-url origin "${core_origin}"
    tar --create --file="${archive}" --directory="${checkout}" .
    archive_sha=$(sha256sum "${archive}" | awk '{ print $1 }')
    {
        printf 'repository=%s\n' "$(basename "${repository}")"
        printf 'origin=%s\n' "${repository_origin}"
        printf 'commit=%s\n' "${repository_commit}"
        printf 'tree=%s\n' "$(git -C "${repository}" rev-parse HEAD^{tree})"
        printf 'helium_submodule=%s\n' "${helium_submodule}"
        printf 'chromium_version=%s\n' \
            "$(tr -d '\r\n' <"${repository}/helium-chromium/chromium_version.txt")"
        if [ -f "${repository}/chromium/android-build.lock" ]; then
            awk -F= '/^HELIUM_ANDROID_(CHROMIUM_COMMIT|CORE_COMMIT|DEPOT_TOOLS_COMMIT)=/ { print }' \
                "${repository}/chromium/android-build.lock"
        fi
        printf 'archive_sha256=%s\n' "${archive_sha}"
        printf 'transferred_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'transferred_from=%s\n' "$(uname -n)"
    } >"${manifest}"

    rsync --archive --checksum "${archive}" "${manifest}" \
        "${host}:${remote_state}/${job}/"
    remote_exec "${remote_worker}" stage-finish "${job}" "${archive_sha}"
    stage_finished=true
    find "${temp_dir}" -depth -delete
    temp_dir=
    trap - EXIT
)

start() (
    local job=$1
    shift
    validate_job "${job}"
    [ "${1:-}" = --summary ] && [ "$#" -ge 6 ] || {
        usage
        exit 2
    }
    local summary=$2
    shift 2
    [ "${1:-}" = --next ] || {
        usage
        exit 2
    }
    local success_next=$2
    shift 2
    [ "${1:-}" = -- ] || {
        usage
        exit 2
    }
    shift
    [ "$#" -gt 0 ] || {
        echo "missing build command" >&2
        exit 2
    }
    [ -x "${local_notifier}" ] || {
        echo "Helium job notifier is not installed: ${local_notifier}" >&2
        exit 1
    }
    [ -x "${local_management}" ] || {
        echo "Chromiumer management monitor is not installed: ${local_management}" >&2
        exit 1
    }
    install_worker

    local management_registered=false
    local remote_start_attempted=false
    local temp_dir source_file source_info repository product registration existing output
    temp_dir=$(mktemp -d \
        "${notification_runtime_dir}/helium-notification.XXXXXX")
    source_file="${temp_dir}/source.env"
    cleanup_start() {
        local result=$?
        if [ "${management_registered}" = true ] && \
            [ "${remote_start_attempted}" = false ]; then
            "${local_management}" unregister "${job}" >/dev/null 2>&1 || true
        fi
        find "${temp_dir}" -depth -delete
        return "${result}"
    }
    trap cleanup_start EXIT
    source_info=$(remote_exec "${remote_worker}" source-info "${job}")
    printf '%s\n' "${source_info}" >"${source_file}"
    chmod 600 "${source_file}"
    repository=$(awk -F= '$1 == "repository" { print $2; exit }' <<<"${source_info}")
    case "${repository}" in
        helium-passwords) product="Helium Passwords" ;;
        helium-sync) product="Helium Sync" ;;
        *)
            echo "unsupported staged Helium repository: ${repository}" >&2
            exit 1
            ;;
    esac
    "${local_management}" register "${job}"
    management_registered=true
    registration=$("${local_notifier}" register "${job}" "${product}" "${summary}" \
        "${success_next}" "${source_file}")
    existing=$(awk -F= '$1 == "existing" { print $2; exit }' <<<"${registration}")

    remote_start_attempted=true
    if ! output=$(remote_exec "${remote_worker}" start production "${job}" \
        "${remote_work}/${job}/source" -- "$@"); then
        if [ "${existing}" = false ]; then
            "${local_notifier}" abandon "${job}" >/dev/null || true
        fi
        return 1
    fi
    printf '%s\nnotification=armed\n' "${output}"
    find "${temp_dir}" -depth -delete
    trap - EXIT
)

resume() (
    local parent=$1
    local job=$2
    shift 2
    validate_job "${parent}"
    validate_job "${job}"
    [ "${parent}" != "${job}" ] || {
        echo "continuation job id must differ from its parent" >&2
        exit 2
    }
    [ "${1:-}" = --summary ] && [ "$#" -ge 6 ] || {
        usage
        exit 2
    }
    local summary=$2
    shift 2
    [ "${1:-}" = --next ] || {
        usage
        exit 2
    }
    local success_next=$2
    shift 2
    [ "${1:-}" = -- ] || {
        usage
        exit 2
    }
    shift
    [ "$#" -gt 0 ] || {
        echo "missing build command" >&2
        exit 2
    }
    [ -x "${local_notifier}" ] || {
        echo "Helium job notifier is not installed: ${local_notifier}" >&2
        exit 1
    }
    [ -x "${local_management}" ] || {
        echo "Chromiumer management monitor is not installed: ${local_management}" >&2
        exit 1
    }
    install_worker

    local initialized=false
    local registered=false
    local management_registered=false
    local temp_dir source_file source_info repository product output
    temp_dir=$(mktemp -d \
        "${notification_runtime_dir}/helium-notification.XXXXXX")
    source_file="${temp_dir}/source.env"
    # shellcheck disable=SC2329 # Invoked by the EXIT trap below.
    cleanup_resume() {
        local result=$?
        if [ "${initialized}" = true ] && [ "${registered}" = false ]; then
            remote_exec "${remote_worker}" resume-abort "${job}" \
                >/dev/null 2>&1 || true
        fi
        if [ "${management_registered}" = true ] && \
            [ "${registered}" = false ]; then
            "${local_management}" unregister "${job}" >/dev/null 2>&1 || true
        fi
        find "${temp_dir}" -depth -delete
        return "${result}"
    }
    trap cleanup_resume EXIT

    remote_exec "${remote_worker}" resume-init "${parent}" "${job}" -- "$@"
    initialized=true
    "${local_management}" register "${job}"
    management_registered=true
    source_info=$(remote_exec "${remote_worker}" source-info "${job}")
    printf '%s\n' "${source_info}" >"${source_file}"
    chmod 600 "${source_file}"
    repository=$(awk -F= '$1 == "repository" { print $2; exit }' <<<"${source_info}")
    case "${repository}" in
        helium-passwords) product="Helium Passwords" ;;
        helium-sync) product="Helium Sync" ;;
        *)
            echo "unsupported staged Helium repository: ${repository}" >&2
            exit 1
            ;;
    esac
    "${local_notifier}" register "${job}" "${product}" "${summary}" \
        "${success_next}" "${source_file}"
    registered=true

    if ! output=$(remote_exec "${remote_worker}" resume-start "${job}" -- "$@"); then
        if remote_exec "${remote_worker}" resume-abort "${job}" \
            >/dev/null 2>&1; then
            initialized=false
            "${local_notifier}" abandon "${job}" >/dev/null || true
            "${local_management}" unregister "${job}" >/dev/null 2>&1 || true
            management_registered=false
        fi
        return 1
    fi
    printf '%s\nnotification=armed\n' "${output}"
    find "${temp_dir}" -depth -delete
    trap - EXIT
)

status() {
    install_worker
    remote_exec "${remote_worker}" status "$1"
}

terminal() {
    install_worker
    remote_exec "${remote_worker}" terminal "$1"
}

limits() {
    install_worker
    remote_exec "${remote_worker}" limits "$1"
}

logs() {
    install_worker
    remote_exec "${remote_worker}" logs "$@"
}

cancel() {
    [ -x "${local_management}" ] || {
        echo "Chromiumer management monitor is not installed: ${local_management}" >&2
        exit 1
    }
    "${local_management}" cancel "$1"
}

management_status() {
    [ -x "${local_management}" ] || {
        echo "Chromiumer management monitor is not installed: ${local_management}" >&2
        exit 1
    }
    "${local_management}" status "$1"
}

fetch_artifact() {
    local job=$1
    local relative=$2
    local destination=${3:-"${default_artifact_root}/${job}"}
    validate_job "${job}"
    [[ "${relative}" != /* && "${relative}" != *..* ]] || {
        echo "artifact path must be a contained relative path" >&2
        exit 2
    }
    install_worker

    local info remote_path remote_sha local_path local_sha
    info=$(remote_exec "${remote_worker}" artifact-info "${job}" "${relative}")
    remote_path=$(awk -F= '$1 == "path" { print substr($0, 6) }' <<<"${info}")
    remote_sha=$(awk -F= '$1 == "sha256" { print $2 }' <<<"${info}")
    [ -n "${remote_path}" ] && [ -n "${remote_sha}" ] || {
        echo "invalid artifact metadata from chromiumer" >&2
        exit 1
    }

    mkdir -p "${destination}"
    destination=$(realpath -e "${destination}")
    if [[ "${destination}" == /srv/nas/* ]]; then
        findmnt -M /srv/nas >/dev/null || {
            echo "/srv/nas is not mounted" >&2
            exit 1
        }
    fi
    rsync --archive --partial "${host}:${remote_path}" "${destination}/"
    local_path="${destination}/$(basename "${remote_path}")"
    local_sha=$(sha256sum "${local_path}" | awk '{ print $1 }')
    [ "${local_sha}" = "${remote_sha}" ] || {
        echo "returned artifact checksum mismatch" >&2
        exit 1
    }
    {
        printf 'job=%s\n' "${job}"
        printf 'artifact=%s\n' "${local_path}"
        printf 'sha256=%s\n' "${local_sha}"
        printf 'received_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'received_on=%s\n' "$(uname -n)"
    } >"${destination}/artifact-receipt.env"
    remote_exec "${remote_worker}" mark-returned "${job}" "${local_sha}"
    printf 'artifact=%s\nsha256=%s\n' "${local_path}" "${local_sha}"
}

cleanup() {
    install_worker
    remote_exec "${remote_worker}" cleanup "$1"
}

test_wrapper() {
    install_worker
    local job="wrapper-test-$(date +%Y%m%d-%H%M%S)"
    local test_dir
    test_dir=$(remote_exec "${remote_worker}" test-prepare "${job}" | tail -n 1)
    remote_exec "${remote_worker}" start test "${job}" "${test_dir}" -- \
        sh -c 'printf "wrapper_test=start\n"; sleep 5; printf "wrapper_test=complete\n"'
    sleep 1
    remote_exec "${remote_worker}" limits "${job}"

    local attempt state
    for attempt in $(seq 1 20); do
        state=$(remote_exec "${remote_worker}" status "${job}")
        if grep -q '^exit_code=' <<<"${state}"; then
            break
        fi
        sleep 1
    done
    grep -q '^exit_code=0$' <<<"${state}" || {
        printf '%s\n' "${state}" >&2
        echo "wrapper test did not complete successfully" >&2
        exit 1
    }
    remote_exec "${remote_worker}" logs "${job}" 40 | \
        grep -E 'wrapper_test=(start|complete)'
    remote_exec "${remote_worker}" cleanup "${job}"
    printf 'wrapper_test=passed\njob=%s\n' "${job}"
}

command=${1:-}
shift || true
case "${command}" in
    connection) [ "$#" -eq 0 ] || exit 2; connection ;;
    preflight) [ "$#" -eq 1 ] || exit 2; preflight "$@" ;;
    stage) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2; stage "$@" ;;
    start) [ "$#" -ge 7 ] || exit 2; start "$@" ;;
    resume) [ "$#" -ge 8 ] || exit 2; resume "$@" ;;
    status) [ "$#" -eq 1 ] || exit 2; status "$@" ;;
    terminal) [ "$#" -eq 1 ] || exit 2; terminal "$@" ;;
    limits) [ "$#" -eq 1 ] || exit 2; limits "$@" ;;
    logs) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || exit 2; logs "$@" ;;
    cancel) [ "$#" -eq 1 ] || exit 2; cancel "$@" ;;
    management-status) [ "$#" -eq 1 ] || exit 2; management_status "$@" ;;
    fetch) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2; fetch_artifact "$@" ;;
    cleanup) [ "$#" -eq 1 ] || exit 2; cleanup "$@" ;;
    test) [ "$#" -eq 0 ] || exit 2; test_wrapper ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
