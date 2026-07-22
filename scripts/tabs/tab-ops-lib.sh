#!/usr/bin/env bash

# Configuration is data, not shell; never source it.

tab_ops_host_short() {
    uname -n | cut -d. -f1
}

tab_ops_valid_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

tab_ops_require_absolute() {
    [[ "$2" == /* && "$2" != *$'\n'* ]] || {
        echo "$1 must be an absolute path" >&2
        return 1
    }
}

tab_ops_recipients_fingerprint() {
	local recipients_file=$1 normalized recipient_count
	[ -s "${recipients_file}" ] || {
		echo "age recipient file is missing or empty" >&2
		return 1
	}
	normalized=$(awk '
	  /^[[:space:]]*($|#)/ { next }
	  /^age1[023456789acdefghjklmnpqrstuvwxyz]{20,}$/ { print $1; next }
	  /^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+\/=]+([[:space:]].*)?$/ {
		print $1 " " $2
		next
	  }
	  { invalid = 1 }
	  END { if (invalid) exit 1 }
	' "${recipients_file}" | sort -u) || {
		echo "age recipient file contains an invalid recipient" >&2
		return 1
	}
	recipient_count=$(wc -l <<<"${normalized}")
	[ "${recipient_count}" -ge 2 ] || {
		echo "at least two distinct age recipients are required" >&2
		return 1
	}
	printf '%s\n' "${normalized}" | sha256sum | awk '{ print $1 }'
}

tab_ops_load_config() {
    local config_file=$1 line key value extra config_mode
    [ -f "${config_file}" ] || {
        echo "tab operations config is not a regular file: ${config_file}" >&2
        return 1
    }
    config_mode=$(stat -c %a "${config_file}")
    (( (8#${config_mode} & 8#022) == 0 )) || {
        echo "tab operations config must not be group/world writable" >&2
        return 1
    }

    TAB_CONFIG_VERSION=
    TAB_SOURCE_DEVICE=
	TAB_KEY_ID=
    TAB_PROFILE=
    TAB_SNAPSHOT_STORE=
    TAB_STATE_ROOT=
    TAB_HELIUM_TABS=
    TAB_EXPORTER=
    TAB_BROWSER_VERSION=
    TAB_CHROMIUM_VERSION=
    TAB_INTERVAL_SECONDS=900
    TAB_AGE_RECIPIENTS=
    TAB_AGE_IDENTITY=
    TAB_DESTINATION_RESERVE_BYTES=1073741824
    TAB_DEST_IDS=()
	TAB_DEST_ROLES=()
    TAB_DEST_KINDS=()
    TAB_DEST_HOSTS=()
    TAB_DEST_SSH=()
    TAB_DEST_ROOTS=()

    while IFS= read -r line || [ -n "${line}" ]; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        [[ "${line}" == *=* ]] || {
            echo "invalid config line (expected key=value)" >&2
            return 1
        }
        key=${line%%=*}
        value=${line#*=}
        case "${key}" in
            version) TAB_CONFIG_VERSION=${value} ;;
            source_device) TAB_SOURCE_DEVICE=${value} ;;
			key_id) TAB_KEY_ID=${value} ;;
            profile) TAB_PROFILE=${value} ;;
            snapshot_store) TAB_SNAPSHOT_STORE=${value} ;;
            state_root) TAB_STATE_ROOT=${value} ;;
            helium_tabs) TAB_HELIUM_TABS=${value} ;;
            exporter) TAB_EXPORTER=${value} ;;
            browser_version) TAB_BROWSER_VERSION=${value} ;;
            chromium_version) TAB_CHROMIUM_VERSION=${value} ;;
            interval_seconds) TAB_INTERVAL_SECONDS=${value} ;;
            age_recipients) TAB_AGE_RECIPIENTS=${value} ;;
            age_identity) TAB_AGE_IDENTITY=${value} ;;
            destination_reserve_bytes) TAB_DESTINATION_RESERVE_BYTES=${value} ;;
            destination)
				local destination_id destination_role destination_kind destination_host destination_ssh destination_root
				IFS='|' read -r destination_id destination_role destination_kind destination_host destination_ssh destination_root extra <<<"${value}"
                [ -z "${extra:-}" ] && [ -n "${destination_root:-}" ] || {
					echo "destination requires id|nas-or-device|ssh|host-id|ssh-alias|absolute-root" >&2
                    return 1
                }
                TAB_DEST_IDS+=("${destination_id}")
				TAB_DEST_ROLES+=("${destination_role}")
                TAB_DEST_KINDS+=("${destination_kind}")
                TAB_DEST_HOSTS+=("${destination_host}")
                TAB_DEST_SSH+=("${destination_ssh}")
                TAB_DEST_ROOTS+=("${destination_root}")
                ;;
            *) echo "unknown tab operations config key: ${key}" >&2; return 1 ;;
        esac
    done <"${config_file}"

	[ "${TAB_CONFIG_VERSION}" = 2 ] || {
        echo "unsupported tab operations config version" >&2
        return 1
    }
	case "${TAB_SOURCE_DEVICE}" in
		d|da|oneplus) ;;
		*) echo "source_device must be d, da, or oneplus" >&2; return 1 ;;
	esac
	[ "${TAB_KEY_ID}" = "${TAB_SOURCE_DEVICE}-tabs-v1" ] || {
		echo "key_id must be the device-local ${TAB_SOURCE_DEVICE}-tabs-v1 namespace" >&2
		return 1
	}
    tab_ops_valid_id "${TAB_PROFILE}" || { echo "invalid profile" >&2; return 1; }
    tab_ops_require_absolute snapshot_store "${TAB_SNAPSHOT_STORE}"
    tab_ops_require_absolute state_root "${TAB_STATE_ROOT}"
    tab_ops_require_absolute helium_tabs "${TAB_HELIUM_TABS}"
    [[ "${TAB_INTERVAL_SECONDS}" =~ ^[1-9][0-9]*$ ]] || {
        echo "interval_seconds must be positive" >&2
        return 1
    }
    [[ "${TAB_DESTINATION_RESERVE_BYTES}" =~ ^[1-9][0-9]*$ ]] || {
        echo "destination_reserve_bytes must be positive" >&2
        return 1
    }
}

tab_ops_validate_destinations() {
    [ "${#TAB_DEST_IDS[@]}" -eq 2 ] || {
        echo "exactly two off-device destinations are required" >&2
        return 1
    }
	local index expected_peer nas_count=0 device_count=0
	case "${TAB_SOURCE_DEVICE}" in
		d|oneplus) expected_peer=da ;;
		da) expected_peer=d ;;
	esac
    for index in 0 1; do
        tab_ops_valid_id "${TAB_DEST_IDS[index]}" || { echo "invalid destination id" >&2; return 1; }
        tab_ops_valid_id "${TAB_DEST_HOSTS[index]}" || { echo "invalid destination host id" >&2; return 1; }
        [ "${TAB_DEST_HOSTS[index]}" != "${TAB_SOURCE_DEVICE}" ] || {
            echo "destination ${TAB_DEST_IDS[index]} is on source device ${TAB_SOURCE_DEVICE}" >&2
            return 1
        }
        tab_ops_require_absolute destination_root "${TAB_DEST_ROOTS[index]}"
        [[ "${TAB_DEST_ROOTS[index]}" =~ ^/[A-Za-z0-9._/-]+$ && "${TAB_DEST_ROOTS[index]}" != *..* ]] || {
            echo "destination root contains unsupported characters" >&2
            return 1
        }
		[ "${TAB_DEST_KINDS[index]}" = ssh ] || {
			echo "off-source destinations must use noninteractive SSH" >&2
			return 1
		}
		[[ "${TAB_DEST_SSH[index]}" =~ ^[A-Za-z0-9._-]+$ ]] || {
			echo "invalid destination SSH alias" >&2
			return 1
		}
		case "${TAB_DEST_ROLES[index]}" in
			nas)
				[ "${TAB_DEST_IDS[index]}" = nas-on-lm ] && [ "${TAB_DEST_HOSTS[index]}" = lm ] || {
					echo "the NAS copy must be destination nas-on-lm on host lm" >&2
					return 1
				}
				[ "${TAB_DEST_ROOTS[index]}" = /srv/nas/helium-tab-backups ] || {
					echo "nas-on-lm must use /srv/nas/helium-tab-backups" >&2
					return 1
				}
				nas_count=$((nas_count + 1))
				;;
			device)
				[ "${TAB_DEST_IDS[index]}" = "${expected_peer}-copy" ] && \
					[ "${TAB_DEST_HOSTS[index]}" = "${expected_peer}" ] || {
					echo "${TAB_SOURCE_DEVICE} must use ${expected_peer} as its device replica" >&2
					return 1
				}
				device_count=$((device_count + 1))
				;;
			*) echo "destination role must be nas or device" >&2; return 1 ;;
		esac
    done
    [ "${TAB_DEST_IDS[0]}" != "${TAB_DEST_IDS[1]}" ] && \
        [ "${TAB_DEST_HOSTS[0]}" != "${TAB_DEST_HOSTS[1]}" ] || {
        echo "the two copies must use distinct destination IDs and hosts" >&2
        return 1
    }
	[ "${nas_count}" -eq 1 ] && [ "${device_count}" -eq 1 ] || {
		echo "exactly one lm NAS copy and one required device replica are required" >&2
		return 1
	}
}

tab_ops_require_source_host() {
	local actual
	actual=$(tab_ops_host_short)
	[ "${actual}" = "${TAB_SOURCE_DEVICE}" ] || {
		echo "tab operations for ${TAB_SOURCE_DEVICE} must run on that source host (found ${actual})" >&2
		return 1
	}
}

tab_ops_namespace() {
    printf '%s/%s/%s\n' "$1" "${TAB_SOURCE_DEVICE}" "${TAB_PROFILE}"
}
