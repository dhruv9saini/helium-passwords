#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

install -d -m 0755 /home/d/.local/libexec
install -m 0755 "${root_dir}/scripts/helium-job-notifier.sh" \
    /home/d/.local/libexec/helium-job-notifier
install -d -m 0700 /home/d/.config/systemd/user
install -m 0644 "${root_dir}/systemd/helium-job-notifier.service" \
    /home/d/.config/systemd/user/helium-job-notifier.service
install -m 0644 "${root_dir}/systemd/helium-job-notifier.timer" \
    /home/d/.config/systemd/user/helium-job-notifier.timer
systemctl --user daemon-reload
systemctl --user enable --now helium-job-notifier.timer

systemctl --user show helium-job-notifier.timer \
    -p ActiveState -p SubState -p UnitFileState
