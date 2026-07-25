#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=tab-ops-lib.sh
source "${script_dir}/tab-ops-lib.sh"

[ "$#" -eq 3 ] || {
	echo "usage: tab-fleet-audit.sh D-CONFIG DA-CONFIG ONEPLUS-CONFIG" >&2
	exit 2
}

expected_devices=(d da oneplus)
config_files=("$@")
for index in 0 1 2; do
	config_file=${config_files[index]}
	tab_ops_load_config "${config_file}"
	tab_ops_validate_destinations
	[ "${TAB_SOURCE_DEVICE}" = "${expected_devices[index]}" ] || {
		echo "config $((index + 1)) must belong to ${expected_devices[index]}" >&2
		exit 1
	}
	printf 'device=%s topology=%s,%s\n' \
		"${TAB_SOURCE_DEVICE}" \
		"${TAB_DEST_IDS[0]}@${TAB_DEST_HOSTS[0]}" \
		"${TAB_DEST_IDS[1]}@${TAB_DEST_HOSTS[1]}"
done

echo 'fleet_configuration=verified'
