#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
queue_identity=/home/d/.ssh/helium_queue_da_ed25519
queue_known_hosts=/home/d/.ssh/helium_queue_da_known_hosts

for protected_file in "${queue_identity}" "${queue_known_hosts}"; do
    [ -f "${protected_file}" ] && [ ! -L "${protected_file}" ] &&
        [ "$(stat -c %a "${protected_file}")" = 600 ] || {
        echo "missing protected Helium queue SSH file: ${protected_file}" >&2
        exit 1
    }
done

sudo install -d -m 0755 /home/d/.local/libexec
sudo install -m 0755 "${root_dir}/scripts/helium-job-notifier.sh" \
    /home/d/.local/libexec/helium-job-notifier
sudo chown d:d /home/d/.local/libexec/helium-job-notifier
sudo install -m 0644 "${root_dir}/systemd/helium-job-notifier.service" \
    /etc/systemd/system/helium-job-notifier.service
sudo install -m 0644 "${root_dir}/systemd/helium-job-notifier.timer" \
    /etc/systemd/system/helium-job-notifier.timer
sudo systemctl daemon-reload
sudo systemctl enable --now helium-job-notifier.timer

systemctl show helium-job-notifier.timer -p ActiveState -p SubState -p UnitFileState
