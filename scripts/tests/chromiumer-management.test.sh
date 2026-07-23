#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d /tmp/helium-management.XXXXXX)
trap 'find "${test_root}" -depth -delete' EXIT
mkdir -p "${test_root}/bin" "${test_root}/signals"
touch "${test_root}/identity"
chmod 600 "${test_root}/identity"

cat >"${test_root}/config" <<EOF
tailscale_ssh_host=chromiumer
tailscale_dns_name=chromiumer.tail.test
lan_address=192.168.5.27
ssh_user=d
ssh_identity=${test_root}/identity
ssh_host_key_alias=chromiumer
remote_worker=.local/libexec/helium-chromiumer-worker
admission_successes=3
dual_failure_cycles=3
EOF

cat >"${test_root}/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '-4 route show default' ]
[ -e "${MGMT_SIGNALS}/route" ] || exit 0
printf 'default via 192.168.5.1 dev enp1s0\n'
EOF
cat >"${test_root}/bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = ahosts ]
[ -e "${MGMT_SIGNALS}/dns" ]
printf '100.64.0.1 STREAM %s\n' "$2"
EOF
cat >"${test_root}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = ping ]
printf '%s\n' "$*" >>"${MGMT_TAILSCALE_CALLS}"
[ -e "${MGMT_SIGNALS}/tailscale-direct" ]
printf 'pong from chromiumer (100.64.0.1) via 192.168.5.27:41641 in 2ms\n'
EOF
cat >"${test_root}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path=tailscale
command_name=
job=
for argument in "$@"; do
    case "${argument}" in
        HostName=192.168.5.27) path=lan ;;
        true|terminal|cancel) command_name=${argument} ;;
    esac
    job=${argument}
done
printf '%s\t%s\t%s\n' "${path}" "${command_name}" "$*" >>"${MGMT_SSH_CALLS}"
case "${path}" in
    tailscale) [ -e "${MGMT_SIGNALS}/tailscale-ssh" ] ;;
    lan) [ -e "${MGMT_SIGNALS}/lan-ssh" ] ;;
esac
case "${command_name}" in
    true) ;;
    terminal)
        if [ -e "${MGMT_SIGNALS}/terminal-error" ]; then
            exit 1
        elif [ -e "${MGMT_SIGNALS}/terminal" ]; then
            printf 'state=terminal\nresult=success\nexit_code=0\n'
        else
            printf 'state=running\n'
        fi
        ;;
    cancel)
        printf '%s\n' "${path}" >"${MGMT_CANCEL_PATH}"
        ;;
    *)
        echo "unexpected SSH command" >&2
        exit 2
        ;;
esac
EOF
cat >"${test_root}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MGMT_SYSTEMCTL_CALLS}"
case "$*" in
    "--user enable --now helium-chromiumer-management@"*".timer") ;;
    "--user disable --now helium-chromiumer-management@"*".timer") ;;
    "--user is-active helium-chromiumer-management@"*".timer")
        printf 'active\n'
        ;;
    "--user is-enabled helium-chromiumer-management@"*".timer")
        printf 'enabled\n'
        ;;
    *)
        echo "unexpected systemctl command: $*" >&2
        exit 2
        ;;
esac
EOF
chmod 700 "${test_root}/bin/"*

export PATH="${test_root}/bin:${PATH}"
export MGMT_SIGNALS="${test_root}/signals"
export MGMT_TAILSCALE_CALLS="${test_root}/tailscale-calls"
export MGMT_SSH_CALLS="${test_root}/ssh-calls"
export MGMT_CANCEL_PATH="${test_root}/cancel-path"
export MGMT_SYSTEMCTL_CALLS="${test_root}/systemctl-calls"
export HELIUM_CHROMIUMER_MANAGEMENT_CONFIG="${test_root}/config"
export HELIUM_CHROMIUMER_MANAGEMENT_STATE_ROOT="${test_root}/state"
management="${repo_root}/scripts/chromiumer-management.sh"

touch "${MGMT_SIGNALS}/route" "${MGMT_SIGNALS}/dns" \
    "${MGMT_SIGNALS}/tailscale-direct" \
    "${MGMT_SIGNALS}/tailscale-ssh" "${MGMT_SIGNALS}/lan-ssh"

job='management-proof'
"${management}" register "${job}" >"${test_root}/register.out"
grep -Fqx 'job=management-proof phase=admission-3 route=yes dns=yes tailscale_direct=yes tailscale_ssh=yes lan_ssh=yes' \
    "${test_root}/register.out"
grep -Fqx "registered=${job}" "${test_root}/register.out"
[ "$(wc -l <"${MGMT_TAILSCALE_CALLS}")" -eq 3 ]
[ "$(awk '$2 == "true" { count += 1 } END { print count + 0 }' \
    "${MGMT_SSH_CALLS}")" -eq 6 ]
grep -Fq -- '--c 1 --timeout 5s --until-direct chromiumer.tail.test' \
    "${MGMT_TAILSCALE_CALLS}"
grep -Fq 'HostKeyAlias=chromiumer' "${MGMT_SSH_CALLS}"
grep -Fq 'IdentityFile='"${test_root}"'/identity' "${MGMT_SSH_CALLS}"
grep -Fq 'PreferredAuthentications=publickey' "${MGMT_SSH_CALLS}"
grep -Fq 'HostName=192.168.5.27' "${MGMT_SSH_CALLS}"
grep -Fqx -- \
    "--user enable --now helium-chromiumer-management@${job}.timer" \
    "${MGMT_SYSTEMCTL_CALLS}"

# An idempotent registration retry repeats admission instead of allowing an
# old registration to bypass the current path gate.
"${management}" register "${job}" >"${test_root}/register-retry.out"
grep -Fqx 'existing=true' "${test_root}/register-retry.out"
[ "$(wc -l <"${MGMT_TAILSCALE_CALLS}")" -eq 6 ]

"${management}" poll-one "${job}" >"${test_root}/healthy.out"
grep -Fqx 'state_health=healthy' \
    "${test_root}/state/jobs/${job}.env"

# Losing only Tailscale is a visible state and alarm; LAN keeps inspection
# available and resets the consecutive dual-failure counter.
find "${MGMT_SIGNALS}/tailscale-direct" -delete
"${management}" poll-one "${job}" >"${test_root}/tailscale-only.out" \
    2>"${test_root}/tailscale-only.error"
grep -Fq 'Tailscale path failed; LAN is available' \
    "${test_root}/tailscale-only.error"
grep -Fqx 'state_health=tailscale-only-failure' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx 'state_dual_failures=0' \
    "${test_root}/state/jobs/${job}.env"

# Three complete cycles with neither path produce a durable pending cancel.
# No cancellation is attempted while there is no management path.
find "${MGMT_SIGNALS}/lan-ssh" -delete
for attempt in 1 2 3; do
    "${management}" poll-one "${job}" >"${test_root}/dual-${attempt}.out" \
        2>"${test_root}/dual-${attempt}.error"
done
grep -Fqx 'state_health=dual-path-failure' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx 'state_dual_failures=3' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx 'state_cancel_pending=yes' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx 'state_cancel_origin=automatic-dual-path-loss' \
    "${test_root}/state/jobs/${job}.env"
grep -Fq 'CANCEL-PENDING job=management-proof' \
    "${test_root}/dual-3.error"
[ ! -e "${MGMT_CANCEL_PATH}" ]

# The first recovered path must successfully inspect terminal state before
# delivering the pending request. An inspection failure never becomes an
# assumed nonterminal state.
touch "${MGMT_SIGNALS}/lan-ssh"
touch "${MGMT_SIGNALS}/terminal-error"
"${management}" poll-one "${job}" >"${test_root}/inspection-error.out" \
    2>"${test_root}/inspection-error.error"
[ ! -e "${MGMT_CANCEL_PATH}" ]
grep -Fqx 'state_cancel_pending=yes' \
    "${test_root}/state/jobs/${job}.env"

# A subsequent successful inspection proves the job is nonterminal and
# executes the durable pending request before normal monitoring continues.
find "${MGMT_SIGNALS}/terminal-error" -delete
"${management}" poll-one "${job}" >"${test_root}/recovery.out" \
    2>"${test_root}/recovery.error"
grep -Fqx 'lan' "${MGMT_CANCEL_PATH}"
grep -Fqx 'state_cancel_pending=no' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx 'state_cancel_delivered=yes' \
    "${test_root}/state/jobs/${job}.env"
grep -Fq 'origin=automatic-dual-path-loss' "${test_root}/recovery.error"

touch "${MGMT_SIGNALS}/terminal"
"${management}" poll-one "${job}" >/dev/null
grep -Fqx 'state_status=terminal' \
    "${test_root}/state/jobs/${job}.env"
grep -Fqx -- \
    "--user disable --now helium-chromiumer-management@${job}.timer" \
    "${MGMT_SYSTEMCTL_CALLS}"
"${management}" status "${job}" >"${test_root}/status.out"
grep -Fqx 'timer_active=active' "${test_root}/status.out"

# Admission itself fails closed as soon as either independent path is absent.
failed_job='management-refused'
if "${management}" register "${failed_job}" \
    >"${test_root}/refused.out" 2>"${test_root}/refused.error"; then
    echo "admission passed without the Tailscale path" >&2
    exit 1
fi
grep -Fq 'management-path admission failed' "${test_root}/refused.error"
[ ! -e "${test_root}/state/jobs/${failed_job}.env" ]

# The one operator cancel command uses the same durable state and recovered
# path selection rather than a second direct-SSH implementation.
manual_job='management-manual'
touch "${MGMT_SIGNALS}/tailscale-direct"
"${management}" register "${manual_job}" >/dev/null
find "${MGMT_SIGNALS}/terminal" "${MGMT_CANCEL_PATH}" -delete
"${management}" cancel "${manual_job}" >/dev/null
grep -Fqx 'tailscale' "${MGMT_CANCEL_PATH}"
grep -Fqx 'state_cancel_origin=manual' \
    "${test_root}/state/jobs/${manual_job}.env"

service="${repo_root}/systemd/helium-chromiumer-management@.service"
timer="${repo_root}/systemd/helium-chromiumer-management@.timer"
grep -Fq 'poll-one %i' "${service}"
grep -Fqx 'CPUQuota=5%' "${service}"
grep -Fqx 'MemoryMax=64M' "${service}"
grep -Fqx 'TasksMax=16' "${service}"
grep -Fqx 'IOSchedulingClass=idle' "${service}"
grep -Fqx 'OnUnitActiveSec=60s' "${timer}"
grep -Fqx 'Persistent=true' "${timer}"

wrapper="${repo_root}/scripts/chromiumer-job.sh"
registration_line=$(grep -n '"${local_management}" register "${job}"' \
    "${wrapper}" | head -1 | cut -d: -f1)
remote_start_line=$(grep -n 'start production "${job}"' "${wrapper}" |
    head -1 | cut -d: -f1)
[ "${registration_line}" -lt "${remote_start_line}" ]
grep -Fq '"${local_management}" cancel "$1"' "${wrapper}"

printf 'chromiumer_management=passed\n'
printf 'admission_successes=%s\ndual_failure_cycles=%s\n' 3 3
