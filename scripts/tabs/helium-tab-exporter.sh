#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: helium-tab-exporter.sh --source FILE --max-age-seconds N [--output NEW-FILE|--check]" >&2
}

source_file=
output_file=
max_age_seconds=
check_only=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--source) [ "$#" -ge 2 ] || { usage; exit 2; }; source_file=$2; shift 2 ;;
		--max-age-seconds) [ "$#" -ge 2 ] || { usage; exit 2; }; max_age_seconds=$2; shift 2 ;;
		--output) [ "$#" -ge 2 ] || { usage; exit 2; }; output_file=$2; shift 2 ;;
		--check) check_only=true; shift ;;
		*) usage; exit 2 ;;
	esac
done

[[ "${source_file}" == /* && "${source_file}" != *$'\n'* ]] || {
	echo "browser export source must be an absolute path" >&2
	exit 1
}
[[ "${max_age_seconds}" =~ ^[1-9][0-9]*$ ]] || {
	echo "max export age must be positive" >&2
	exit 1
}
if [ "${check_only}" = true ]; then
	[ -z "${output_file}" ] || { usage; exit 2; }
else
	[[ "${output_file}" == /* && "${output_file}" != *$'\n'* ]] || {
		echo "output must be a new absolute path" >&2
		exit 1
	}
	[ "${output_file}" != "${source_file}" ] && [ ! -e "${output_file}" ] && [ ! -L "${output_file}" ] || {
		echo "output must be a new path distinct from the browser export" >&2
		exit 1
	}
fi

[ ! -L "${source_file}" ] && [ -f "${source_file}" ] || {
	echo "browser export must be a regular non-symlink file" >&2
	exit 1
}
[ "$(stat -c %u -- "${source_file}")" -eq "$(id -u)" ] || {
	echo "browser export must be owned by the scheduler user" >&2
	exit 1
}
source_mode=$(stat -c %a -- "${source_file}")
(( (8#${source_mode} & 8#077) == 0 )) || {
	echo "browser export must be mode 0600 or stricter" >&2
	exit 1
}
source_size=$(stat -c %s -- "${source_file}")
[[ "${source_size}" =~ ^[0-9]+$ ]] && [ "${source_size}" -gt 0 ] && \
	[ "${source_size}" -le 16777216 ] || {
	echo "browser export is empty or exceeds 16 MiB" >&2
	exit 1
}
now=$(date +%s)
source_mtime=$(stat -c %Y -- "${source_file}")
[[ "${source_mtime}" =~ ^[0-9]+$ ]] || {
	echo "browser export has an invalid modification time" >&2
	exit 1
}
age_seconds=$((now - source_mtime))
[ "${age_seconds}" -ge 0 ] && [ "${age_seconds}" -le "${max_age_seconds}" ] || {
	echo "browser export is stale or dated in the future" >&2
	exit 1
}

if [ "${check_only}" = false ]; then
	before=$(stat -c '%d:%i:%s:%Y' -- "${source_file}")
	install -m 600 -- "${source_file}" "${output_file}"
	after=$(stat -c '%d:%i:%s:%Y' -- "${source_file}")
	[ "${before}" = "${after}" ] || {
		find "${output_file}" -maxdepth 0 -type f -delete
		echo "browser export changed during capture; retry the next cycle" >&2
		exit 1
	}
fi

printf 'export_fresh=true\nexport_age_seconds=%s\nexport_bytes=%s\n' \
	"${age_seconds}" "${source_size}"
