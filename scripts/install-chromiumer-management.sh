#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

install -d -m 0755 /home/d/.local/libexec
install -m 0755 "${root_dir}/scripts/chromiumer-management.sh" \
    /home/d/.local/libexec/helium-chromiumer-management
install -d -m 0700 /home/d/.config/helium
install -m 0600 "${root_dir}/chromiumer-management.conf" \
    /home/d/.config/helium/chromiumer-management.conf
install -d -m 0700 /home/d/.config/systemd/user
install -m 0644 \
    "${root_dir}/systemd/helium-chromiumer-management@.service" \
    /home/d/.config/systemd/user/helium-chromiumer-management@.service
install -m 0644 \
    "${root_dir}/systemd/helium-chromiumer-management@.timer" \
    /home/d/.config/systemd/user/helium-chromiumer-management@.timer
systemctl --user daemon-reload

printf 'installed=helium-chromiumer-management\n'
printf 'timer_template=helium-chromiumer-management@.timer\n'
