#!/usr/bin/env bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
install_root="${HOME}/.local/libexec/helium-tab-ops"
config_root="${HOME}/.config/helium-sync"
unit_root="${HOME}/.config/systemd/user"

usage() {
    echo "usage: install-linux-tab-scheduler.sh <install CONFIG|enable|disable|status>" >&2
}

install_files() {
    local config_file=$1
    [ -f "${config_file}" ] || { echo "config file is missing" >&2; exit 1; }
    mkdir -p "${install_root}" "${config_root}" "${unit_root}"
    install -m 700 "${source_dir}/tab-ops-lib.sh" "${install_root}/tab-ops-lib.sh"
    install -m 700 "${source_dir}/tab-backup.sh" "${install_root}/tab-backup.sh"
    install -m 700 "${source_dir}/tab-snapshot-scheduler.sh" "${install_root}/tab-snapshot-scheduler.sh"
    install -m 600 "${config_file}" "${config_root}/tab-ops.conf"
    install -m 644 "${source_dir}/systemd/helium-tab-cycle.service" "${unit_root}/helium-tab-cycle.service"
    install -m 644 "${source_dir}/systemd/helium-tab-cycle.timer" "${unit_root}/helium-tab-cycle.timer"
    systemctl --user daemon-reload
    printf 'installed=true\nenabled=false\nnext=run enable after exporter/tools/destinations pass preflight\n'
}

enable_timer() {
    "${install_root}/tab-backup.sh" preflight "${config_root}/tab-ops.conf" >/dev/null
    systemctl --user enable --now helium-tab-cycle.timer
    systemctl --user status helium-tab-cycle.timer --no-pager
}

command_name=${1:-}
shift || true
case "${command_name}" in
    install) [ "$#" -eq 1 ] || exit 2; install_files "$1" ;;
    enable) [ "$#" -eq 0 ] || exit 2; enable_timer ;;
    disable) [ "$#" -eq 0 ] || exit 2; systemctl --user disable --now helium-tab-cycle.timer ;;
    status) [ "$#" -eq 0 ] || exit 2; systemctl --user status helium-tab-cycle.timer helium-tab-cycle.service --no-pager ;;
    *) usage; exit 2 ;;
esac
