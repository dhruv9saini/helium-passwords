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

usage() {
    cat >&2 <<'EOF'
usage: scripts/chromiumer-job.sh <command> [arguments]

Commands:
  connection
  preflight <disk-budget-gib>
  stage <job-id> <disk-budget-gib> [repository]
  start <job-id> --summary <text> --next <success-action> -- <command> [arguments...]
  status <job-id>
  terminal <job-id>
  limits <job-id>
  logs <job-id> [line-count]
  cancel <job-id>
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

stage() {
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

    local archive submodule_archive manifest archive_sha helium_submodule
    temp_dir=$(mktemp -d /tmp/helium-source.XXXXXX)
    archive="${temp_dir}/source.tar"
    submodule_archive="${temp_dir}/helium-chromium.tar"
    manifest="${temp_dir}/source.manifest.incoming"

    helium_submodule=$(git -C "${repository}" rev-parse HEAD:helium-chromium)
    [ "$(git -C "${repository}/helium-chromium" rev-parse HEAD)" = \
        "${helium_submodule}" ] || {
        echo "helium-chromium checkout does not match the committed gitlink" >&2
        exit 1
    }
    git -C "${repository}" archive --format=tar --output="${archive}" HEAD
    git -C "${repository}/helium-chromium" archive --format=tar \
        --prefix=helium-chromium/ --output="${submodule_archive}" \
        "${helium_submodule}"
    tar --concatenate --file="${archive}" "${submodule_archive}"
    archive_sha=$(sha256sum "${archive}" | awk '{ print $1 }')
    {
        printf 'repository=%s\n' "$(basename "${repository}")"
        printf 'origin=%s\n' "$(git -C "${repository}" remote get-url origin)"
        printf 'commit=%s\n' "$(git -C "${repository}" rev-parse HEAD)"
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
}

start() {
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
    install_worker

    local temp_dir source_file source_info repository product registration existing output
    temp_dir=$(mktemp -d /tmp/helium-notification.XXXXXX)
    source_file="${temp_dir}/source.env"
    cleanup_start() {
        local result=$?
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
    registration=$("${local_notifier}" register "${job}" "${product}" "${summary}" \
        "${success_next}" "${source_file}")
    existing=$(awk -F= '$1 == "existing" { print $2; exit }' <<<"${registration}")

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
}

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
    install_worker
    remote_exec "${remote_worker}" cancel "$1"
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
    status) [ "$#" -eq 1 ] || exit 2; status "$@" ;;
    terminal) [ "$#" -eq 1 ] || exit 2; terminal "$@" ;;
    limits) [ "$#" -eq 1 ] || exit 2; limits "$@" ;;
    logs) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || exit 2; logs "$@" ;;
    cancel) [ "$#" -eq 1 ] || exit 2; cancel "$@" ;;
    fetch) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || exit 2; fetch_artifact "$@" ;;
    cleanup) [ "$#" -eq 1 ] || exit 2; cleanup "$@" ;;
    test) [ "$#" -eq 0 ] || exit 2; test_wrapper ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
