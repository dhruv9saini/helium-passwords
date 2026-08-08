#!/usr/bin/env bash
set -euo pipefail
umask 077

config_path=${HELIUM_CHROMIUMER_MANAGEMENT_CONFIG:-/home/d/.config/helium/chromiumer-management.conf}
state_root=${HELIUM_CHROMIUMER_MANAGEMENT_STATE_ROOT:-/home/d/.local/state/helium-chromiumer-management}
jobs_dir="${state_root}/jobs"
leases_dir="${state_root}/leases"

usage() {
    echo "usage: chromiumer-management <register|unregister|poll-one|status|claim|authorize|cancel> <job-id>" >&2
}

validate_job() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
        echo "invalid job id: $1" >&2
        exit 2
    }
}

validate_owner() {
    [[ "$1" =~ ^/[a-z0-9][a-z0-9_/-]{0,94}$ ]] || {
        echo "invalid job owner: $1" >&2
        exit 2
    }
}

validate_generation() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{7,127}$ ]] || {
        echo "invalid job generation: $1" >&2
        exit 2
    }
}

load_config() {
    [ -f "${config_path}" ] && [ ! -L "${config_path}" ] || {
        echo "missing non-symlink management config: ${config_path}" >&2
        exit 1
    }
    # This mode-private file is installed from the reviewed repository config.
    # shellcheck disable=SC1090,SC1091
    source "${config_path}"
    : "${tailscale_ssh_host:?}" "${tailscale_dns_name:?}" \
        "${lan_address:?}" "${ssh_user:?}" "${ssh_identity:?}" \
        "${ssh_host_key_alias:?}" "${remote_worker:?}" \
        "${admission_successes:?}" "${dual_failure_cycles:?}"
    [[ "${admission_successes}" =~ ^[1-9][0-9]*$ ]] && \
        [[ "${dual_failure_cycles}" =~ ^[1-9][0-9]*$ ]] || {
        echo "invalid management cycle policy" >&2
        exit 1
    }
    [[ "${ssh_identity}" == /* ]] && [ -f "${ssh_identity}" ] && \
        [ ! -L "${ssh_identity}" ] || {
        echo "missing non-symlink dedicated SSH identity: ${ssh_identity}" >&2
        exit 1
    }
    config_sha=$(sha256sum "${config_path}" | awk '{ print $1 }')
    ssh_options=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o ConnectionAttempts=1
        -o IdentitiesOnly=yes
        -o PreferredAuthentications=publickey
        -o StrictHostKeyChecking=yes
        -o "IdentityFile=${ssh_identity}"
        -o "HostKeyAlias=${ssh_host_key_alias}"
        -o "User=${ssh_user}"
    )
}

tailscale_ssh() {
    # All remote arguments are constrained worker, command, and job tokens.
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" "${tailscale_ssh_host}" "$@"
}

lan_ssh() {
    # All remote arguments are constrained worker, command, and job tokens.
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" -o "HostName=${lan_address}" \
        "${tailscale_ssh_host}" "$@"
}

probe_paths() {
    route_ok=no
    dns_ok=no
    tailscale_direct_ok=no
    tailscale_ssh_ok=no
    lan_ssh_ok=no
    ip -4 route show default 2>/dev/null | grep -q '^default ' && route_ok=yes
    getent ahosts "${tailscale_dns_name}" >/dev/null 2>&1 && dns_ok=yes
    local ping_output
    if ping_output=$(tailscale ping --c 1 --timeout 5s --until-direct \
        "${tailscale_dns_name}" 2>/dev/null) && \
        grep -Eq 'pong from .* via .*:[0-9]+ in ' <<<"${ping_output}" && \
        ! grep -q ' via DERP' <<<"${ping_output}"; then
        tailscale_direct_ok=yes
    fi
    tailscale_ssh true >/dev/null 2>&1 && tailscale_ssh_ok=yes
    lan_ssh true >/dev/null 2>&1 && lan_ssh_ok=yes
    tailscale_ok=no
    [ "${route_ok}${dns_ok}${tailscale_direct_ok}${tailscale_ssh_ok}" = \
        yesyesyesyes ] && tailscale_ok=yes
    lan_ok=${lan_ssh_ok}
}

print_probe() {
    printf 'job=%s phase=%s route=%s dns=%s tailscale_direct=%s tailscale_ssh=%s lan_ssh=%s\n' \
        "$1" "$2" "${route_ok}" "${dns_ok}" "${tailscale_direct_ok}" \
        "${tailscale_ssh_ok}" "${lan_ssh_ok}"
}

state_path() {
    printf '%s/%s.env\n' "${jobs_dir}" "$1"
}

lease_path() {
    printf '%s/%s.env\n' "${leases_dir}" "$1"
}

lease_exists() {
    local file
    file=$(lease_path "$1")
    [ -e "${file}" ] || [ -L "${file}" ]
}

load_lease() {
    local expected=$1
    local file
    file=$(lease_path "${expected}")
    [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
    unset lease_job lease_owner lease_generation lease_claimed_at
    # The file is generated atomically by claim_job below.
    # shellcheck disable=SC1090
    source "${file}"
    [ "${lease_job:-}" = "${expected}" ] || return 1
    [[ "${lease_owner:-}" =~ ^/[a-z0-9][a-z0-9_/-]{0,94}$ ]] || return 1
    [[ "${lease_generation:-}" =~ ^[a-z0-9][a-z0-9._-]{7,127}$ ]] || \
        return 1
    [[ "${lease_claimed_at:-}" =~ ^[0-9]+$ ]] || return 1
}

require_caller_lease() {
    local job=$1
    if lease_exists "${job}"; then
        load_lease "${job}" || {
            echo "invalid job ownership lease: ${job}" >&2
            exit 1
        }
        [ "${HELIUM_JOB_OWNER_ID:-}" = "${lease_owner}" ] && \
            [ "${HELIUM_JOB_GENERATION:-}" = "${lease_generation}" ] || {
            echo "job ownership mismatch: ${job}" >&2
            exit 1
        }
    else
        lease_owner=
        lease_generation=
    fi
}

claim_job() {
    local job=$1
    validate_job "${job}"
    validate_owner "${HELIUM_JOB_OWNER_ID:-}"
    validate_generation "${HELIUM_JOB_GENERATION:-}"
    lock_state
    load_state "${job}"
    local file temp
    file=$(lease_path "${job}")
    if lease_exists "${job}"; then
        load_lease "${job}" || {
            echo "invalid job ownership lease: ${job}" >&2
            exit 1
        }
        [ "${lease_owner}" = "${HELIUM_JOB_OWNER_ID}" ] && \
            [ "${lease_generation}" = "${HELIUM_JOB_GENERATION}" ] || {
            echo "job already has a different owner or generation: ${job}" >&2
            exit 1
        }
        printf 'claimed=%s\nexisting=true\nowner=%s\ngeneration=%s\n' \
            "${job}" "${lease_owner}" "${lease_generation}"
        return
    fi
    temp="${file}.tmp.$$"
    {
        printf 'lease_job=%q\n' "${job}"
        printf 'lease_owner=%q\n' "${HELIUM_JOB_OWNER_ID}"
        printf 'lease_generation=%q\n' "${HELIUM_JOB_GENERATION}"
        printf 'lease_claimed_at=%q\n' "$(date +%s)"
    } >"${temp}"
    mv "${temp}" "${file}"
    printf 'claimed=%s\nexisting=false\nowner=%s\ngeneration=%s\n' \
        "${job}" "${HELIUM_JOB_OWNER_ID}" "${HELIUM_JOB_GENERATION}"
}

authorize_job() {
    local job=$1
    validate_job "${job}"
    load_state "${job}"
    require_caller_lease "${job}"
    printf 'authorized=%s\nowner=%s\ngeneration=%s\n' \
        "${job}" "${lease_owner}" "${lease_generation}"
}

timer_unit() {
    printf 'helium-chromiumer-management@%s.timer\n' "$1"
}

load_state() {
    local expected=$1
    local file
    file=$(state_path "${expected}")
    [ -f "${file}" ] && [ ! -L "${file}" ] || {
        echo "missing management state: ${expected}" >&2
        exit 1
    }
    unset state_job state_config_sha state_status state_health \
        state_dual_failures state_cancel_pending state_cancel_delivered \
        state_cancel_origin state_admitted_at_epoch
    # State is generated atomically by this script and mode-private.
    # shellcheck disable=SC1090
    source "${file}"
    [ "${state_job:-}" = "${expected}" ] && \
        [ "${state_config_sha:-}" = "${config_sha}" ] && \
        [[ "${state_status:-}" =~ ^(watching|terminal)$ ]] && \
        [[ "${state_health:-}" =~ ^(healthy|tailscale-only-failure|lan-only-failure|dual-path-failure)$ ]] && \
        [[ "${state_dual_failures:-}" =~ ^[0-9]+$ ]] && \
        [[ "${state_cancel_pending:-}" =~ ^(yes|no)$ ]] && \
        [[ "${state_cancel_delivered:-}" =~ ^(yes|no)$ ]] && \
        [[ "${state_cancel_origin:-}" =~ ^(none|manual|automatic-dual-path-loss)$ ]] && \
        [[ "${state_admitted_at_epoch:-}" =~ ^[0-9]+$ ]] || {
        echo "invalid management state: ${file}" >&2
        exit 1
    }
}

save_state() {
    local file temp
    file=$(state_path "${state_job}")
    temp="${file}.tmp.$$"
    {
        printf 'state_job=%q\n' "${state_job}"
        printf 'state_config_sha=%q\n' "${config_sha}"
        printf 'state_status=%q\n' "${state_status}"
        printf 'state_health=%q\n' "${state_health}"
        printf 'state_dual_failures=%q\n' "${state_dual_failures}"
        printf 'state_cancel_pending=%q\n' "${state_cancel_pending}"
        printf 'state_cancel_delivered=%q\n' "${state_cancel_delivered}"
        printf 'state_cancel_origin=%q\n' "${state_cancel_origin}"
        printf 'state_admission_successes=%q\n' "${admission_successes}"
        printf 'state_admitted_at_epoch=%q\n' "${state_admitted_at_epoch}"
        printf 'state_updated_at_epoch=%q\n' "$(date +%s)"
    } >"${temp}"
    mv "${temp}" "${file}"
}

lock_state() {
    exec 9>"${state_root}/lock"
    flock 9
}

register_job() {
    local job=$1
    validate_job "${job}"
    lock_state
    local existing=false file sequence
    file=$(state_path "${job}")
    if [ -f "${file}" ]; then
        load_state "${job}"
        [ "${state_status}${state_cancel_pending}${state_cancel_delivered}" = \
            watchingnono ] || {
            echo "management job is terminal or cancelling: ${job}" >&2
            exit 1
        }
        existing=true
    fi
    for sequence in $(seq 1 "${admission_successes}"); do
        probe_paths
        print_probe "${job}" "admission-${sequence}"
        [ "${tailscale_ok}${lan_ok}" = yesyes ] || {
            echo "management-path admission failed: ${job} sequence=${sequence}" >&2
            return 1
        }
    done
    if [ "${existing}" = false ]; then
        state_job=${job}
        state_status=watching
        state_health=healthy
        state_dual_failures=0
        state_cancel_pending=no
        state_cancel_delivered=no
        state_cancel_origin=none
        state_admitted_at_epoch=$(date +%s)
        save_state
    fi
    if ! systemctl --user enable --now "$(timer_unit "${job}")"; then
        [ "${existing}" = true ] || unlink "${file}"
        echo "failed to enable durable management monitor: ${job}" >&2
        exit 1
    fi
    printf 'registered=%s\nexisting=%s\n' "${job}" "${existing}"
}

unregister_job() {
    local job=$1
    validate_job "${job}"
    lock_state
    load_state "${job}"
    [ "${state_status}${state_cancel_pending}${state_cancel_delivered}" = \
        watchingnono ] || {
        echo "refusing to unregister active cancellation or terminal state" >&2
        exit 1
    }
    systemctl --user disable --now "$(timer_unit "${job}")"
    unlink "$(state_path "${job}")"
    printf 'unregistered=%s\n' "${job}"
}

remote_worker_call() {
    local path=$1
    shift
    case "${path}" in
        tailscale) tailscale_ssh "${remote_worker}" "$@" ;;
        lan) lan_ssh "${remote_worker}" "$@" ;;
        *) return 2 ;;
    esac
}

poll_job() {
    local job=$1
    load_state "${job}"
    [ "${state_status}" = watching ] || return 0
    local previous_health=${state_health}
    local selected_path='' terminal_output remote_state=''
    probe_paths
    print_probe "${job}" monitor
    case "${tailscale_ok}${lan_ok}" in
        yesyes)
            state_health=healthy
            state_dual_failures=0
            selected_path=tailscale
            ;;
        noyes)
            state_health=tailscale-only-failure
            state_dual_failures=0
            selected_path=lan
            ;;
        yesno)
            state_health=lan-only-failure
            state_dual_failures=0
            selected_path=tailscale
            ;;
        *)
            state_health=dual-path-failure
            state_dual_failures=$((state_dual_failures + 1))
            ;;
    esac
    if [ "${state_health}" != "${previous_health}" ]; then
        case "${state_health}" in
            tailscale-only-failure)
                echo "ALARM job=${job} Tailscale path failed; LAN is available" >&2 ;;
            lan-only-failure)
                echo "ALARM job=${job} LAN path failed; Tailscale is available" >&2 ;;
            dual-path-failure)
                echo "ALARM job=${job} both management paths failed" >&2 ;;
            healthy)
                echo "RECOVERY job=${job} both management paths healthy" >&2 ;;
        esac
    fi
    if [ "${state_dual_failures}" -ge "${dual_failure_cycles}" ] && \
        [ "${state_cancel_delivered}" = no ]; then
        if [ "${state_cancel_pending}" = no ]; then
            echo "CANCEL-PENDING job=${job} after ${state_dual_failures} failed cycles" >&2
        fi
        state_cancel_pending=yes
        [ "${state_cancel_origin}" != none ] || \
            state_cancel_origin=automatic-dual-path-loss
    fi
    if [ -n "${selected_path}" ] && \
        terminal_output=$(remote_worker_call "${selected_path}" terminal \
            "${job}" 2>/dev/null); then
        remote_state=$(awk -F= '
            $1 == "state" { count += 1; value = $2 }
            END { if (count == 1) print value; else exit 1 }
        ' <<<"${terminal_output}") || remote_state=
        if [ "${remote_state}" = terminal ]; then
            state_status=terminal
            state_cancel_pending=no
        elif [[ "${remote_state}" =~ ^(running|finishing|staged)$ ]] && \
            [ "${state_cancel_pending}" = yes ] && \
            [ "${state_cancel_delivered}" = no ]; then
            if lease_exists "${job}"; then
                load_lease "${job}" || {
                    echo "invalid job ownership lease: ${job}" >&2
                    exit 1
                }
                cancel_args=("${job}" "${lease_owner}" "${lease_generation}")
            else
                cancel_args=("${job}")
            fi
            if remote_worker_call "${selected_path}" cancel \
                "${cancel_args[@]}" >/dev/null 2>&1; then
                state_cancel_pending=no
                state_cancel_delivered=yes
                echo "CANCEL job=${job} path=${selected_path} origin=${state_cancel_origin}" >&2
            fi
        fi
    fi
    save_state
    printf 'job=%s health=%s dual_failures=%s cancel_pending=%s cancel_delivered=%s status=%s\n' \
        "${job}" "${state_health}" "${state_dual_failures}" \
        "${state_cancel_pending}" "${state_cancel_delivered}" \
        "${state_status}"
}

poll_one() {
    local job=$1
    validate_job "${job}"
    lock_state
    poll_job "${job}"
    load_state "${job}"
    [ "${state_status}" != terminal ] || \
        systemctl --user disable --now "$(timer_unit "${job}")"
}

cancel_job() {
    local job=$1
    validate_job "${job}"
    lock_state
    load_state "${job}"
    require_caller_lease "${job}"
    [ "${state_status}${state_cancel_delivered}" = watchingno ] || {
        echo "job is terminal or cancellation was delivered: ${job}" >&2
        exit 1
    }
    state_cancel_pending=yes
    state_cancel_origin=manual
    save_state
    poll_job "${job}"
}

status_job() {
    local job=$1
    validate_job "${job}"
    load_state "${job}"
    cat "$(state_path "${job}")"
    printf 'timer_active=%s\n' \
        "$(systemctl --user is-active "$(timer_unit "${job}")" \
            2>/dev/null || true)"
    printf 'timer_enabled=%s\n' \
        "$(systemctl --user is-enabled "$(timer_unit "${job}")" \
            2>/dev/null || true)"
}

load_config
mkdir -p "${jobs_dir}" "${leases_dir}"
chmod 700 "${state_root}" "${jobs_dir}" "${leases_dir}"
command=${1:-}
shift || true
[ "$#" -eq 1 ] || { usage; exit 2; }
case "${command}" in
    register) register_job "$1" ;;
    unregister) unregister_job "$1" ;;
    poll-one) poll_one "$1" ;;
    status) status_job "$1" ;;
    claim) claim_job "$1" ;;
    authorize) authorize_job "$1" ;;
    cancel) cancel_job "$1" ;;
    *) usage; exit 2 ;;
esac
