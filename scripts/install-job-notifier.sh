#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

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
