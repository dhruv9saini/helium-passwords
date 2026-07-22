#!/usr/bin/env bash
set -euo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
install_home=${HOME}
operation_root=${install_home}/.local/libexec/helium-tab-ops
config_root=${install_home}/.config/helium-sync
template_root=${install_home}/.local/share/helium-tab-ops

[ "$#" -eq 2 ] && [ "$1" = install ] || {
    echo 'usage: install-oneplus-tab-scheduler.sh install CONFIG-TEMPLATE' >&2
    exit 2
}
config_template=$2
[ -f "${config_template}" ] || { echo 'config template is missing' >&2; exit 1; }
config_mode=$(stat -c %a "${config_template}")
(( (8#${config_mode} & 8#022) == 0 )) || {
    echo 'config template must not be group/world writable' >&2
    exit 1
}
# shellcheck source=tab-ops-lib.sh
source "${source_dir}/tab-ops-lib.sh"
tab_ops_load_config "${config_template}"
tab_ops_validate_destinations
[ "${TAB_SOURCE_DEVICE}" = oneplus ] || {
    echo 'config template must belong to oneplus' >&2
    exit 1
}

targets=(
    "${operation_root}/tab-ops-lib.sh"
    "${operation_root}/tab-backup.sh"
    "${operation_root}/tab-snapshot-scheduler.sh"
    "${install_home}/.local/libexec/helium-tab-exporter"
    "${config_root}/tab-ops.conf.template"
    "${template_root}/oneplus-tab-cycle-service.disabled"
)
for target in "${targets[@]}"; do
    [ ! -e "${target}" ] && [ ! -L "${target}" ] || {
        echo "refusing to overwrite existing oneplus tab source: ${target}" >&2
        exit 1
    }
done

mkdir -p "${install_home}/.local/libexec" "${install_home}/.local/share" \
    "${install_home}/.config"
for directory in "${operation_root}" "${config_root}" "${template_root}"; do
    if [ -e "${directory}" ] || [ -L "${directory}" ]; then
        [ -d "${directory}" ] && [ ! -L "${directory}" ] || {
            echo "unsafe existing installer directory: ${directory}" >&2
            exit 1
        }
    else
        mkdir -m 700 "${directory}"
    fi
done
install -m 700 "${source_dir}/tab-ops-lib.sh" "${targets[0]}"
install -m 700 "${source_dir}/tab-backup.sh" "${targets[1]}"
install -m 700 "${source_dir}/tab-snapshot-scheduler.sh" "${targets[2]}"
install -m 700 "${source_dir}/helium-tab-exporter.sh" "${targets[3]}"
install -m 600 "${config_template}" "${targets[4]}"
install -m 600 "${source_dir}/oneplus-tab-cycle-service.sh" "${targets[5]}"

printf '%s\n' \
    'installed_source=true' \
    'active_config=false' \
    'magisk_service_installed=false' \
    'enabled=false' \
    "runner_template=${targets[5]}"
