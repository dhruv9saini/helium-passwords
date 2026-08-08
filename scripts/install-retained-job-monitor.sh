#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
host=${HELIUM_CHROMIUMER_HOST:-chromiumer}

ssh -o BatchMode=yes "${host}" 'mkdir -p .local/libexec'
rsync --archive --checksum --chmod=F700 \
    "${root_dir}/scripts/chromiumer-unit-terminal.sh" \
    "${host}:.local/libexec/helium-unit-terminal"
install -d -m 0755 /home/d/.local/libexec
install -m 0755 "${root_dir}/scripts/helium-job-notifier.sh" \
    /home/d/.local/libexec/helium-job-notifier
install -d -m 0700 /home/d/.config/systemd/user
install -m 0644 \
    "${root_dir}/systemd/helium-retained-job-notifier.service" \
    /home/d/.config/systemd/user/helium-retained-job-notifier.service
install -m 0644 \
    "${root_dir}/systemd/helium-retained-job-notifier.timer" \
    /home/d/.config/systemd/user/helium-retained-job-notifier.timer
systemctl --user daemon-reload
systemctl --user enable --now helium-retained-job-notifier.timer
systemctl --user show helium-retained-job-notifier.timer \
    -p ActiveState -p SubState -p UnitFileState
