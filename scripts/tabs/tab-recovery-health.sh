#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 STATUS_ROOT SOURCE_DEVICE PROFILE" >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
status_root=$1
source_device=$2
profile=$3

[[ "$source_device" =~ ^(d|da|oneplus)$ ]] || {
	echo "invalid source device" >&2
	exit 2
}
[[ "$profile" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
	echo "invalid profile" >&2
	exit 2
}
[ -d "$status_root" ] && [ ! -L "$status_root" ] || {
	echo "status root must be a directory" >&2
	exit 2
}
command -v jq >/dev/null || {
	echo "jq is required" >&2
	exit 2
}

mechanisms=(
	chromium-native-session
	neutral-topology
	full-profile
)
maximum_ages=(2592000 1800 604800)
now=$(date +%s)
results=()

status_result() {
	local mechanism=$1 maximum_age=$2 file
	local line key value mode owner completed state generation
	local platform package_id browser_sha256 source_generation
	local version proof_device proof_profile proof_mechanism reason=healthy
	file="$status_root/$mechanism.status"
	declare -A fields=()

	if [ ! -f "$file" ] || [ -L "$file" ]; then
		reason=missing_or_unsafe
	elif ! mode=$(stat -c %a -- "$file") ||
		! owner=$(stat -c %u -- "$file"); then
		reason=unreadable_metadata
	elif (( (8#$mode & 077) != 0 )) || [ "$owner" != "$(id -u)" ]; then
		reason=wrong_owner_or_mode
	else
		while IFS= read -r line || [ -n "$line" ]; do
			if [[ "$line" != *=* ]]; then
				reason=invalid_line
				break
			fi
			key=${line%%=*}
			value=${line#*=}
			case "$key" in
				version|mechanism|state|platform|package_id|browser_sha256|source_generation|source_device|profile|completed_unix|generation|evidence) ;;
				*) reason=unknown_field; break ;;
			esac
			if [ -n "${fields[$key]+set}" ] || [ -z "$value" ]; then
				reason=duplicate_or_empty_field
				break
			fi
			fields[$key]=$value
		done <"$file"
	fi

	if [ "$reason" = healthy ]; then
		version=${fields[version]:-}
		proof_mechanism=${fields[mechanism]:-}
		state=${fields[state]:-}
		platform=${fields[platform]:-}
		package_id=${fields[package_id]:-}
		browser_sha256=${fields[browser_sha256]:-}
		source_generation=${fields[source_generation]:-}
		proof_device=${fields[source_device]:-}
		proof_profile=${fields[profile]:-}
		completed=${fields[completed_unix]:-}
		generation=${fields[generation]:-${fields[evidence]:-}}
		if [ "$version" != 2 ] || [ "$proof_mechanism" != "$mechanism" ] ||
			[ "$state" != healthy ] || [ "$proof_device" != "$source_device" ] ||
			[ "$proof_profile" != "$profile" ] ||
			! [[ "$platform" =~ ^(desktop|android)$ ]] ||
			{ [ "$platform" = desktop ] && [ "$package_id" != desktop ]; } ||
			{ [ "$platform" = android ] &&
			  [ "$package_id" != computer.helium.sync.test ]; } ||
			! [[ "$browser_sha256" =~ ^[0-9a-f]{64}$ ]] ||
			! [[ "$source_generation" =~ ^[0-9a-f]{64}$ ]] ||
			! [[ "$completed" =~ ^[0-9]+$ ]] ||
			[ -z "$generation" ]; then
			reason=invalid_proof
		elif [ "$completed" -gt "$now" ]; then
			reason=future_proof
		elif [ $((now - completed)) -gt "$maximum_age" ]; then
			reason=stale
		fi
	fi

	jq -cn \
		--arg mechanism "$mechanism" \
		--arg state "$([ "$reason" = healthy ] && printf healthy || printf unhealthy)" \
		--arg reason "$reason" \
		--arg platform "${platform:-}" \
		--arg package_id "${package_id:-}" \
		--arg browser_sha256 "${browser_sha256:-}" \
		--arg source_generation "${source_generation:-}" \
		--argjson maximum_age_seconds "$maximum_age" \
		'{mechanism:$mechanism,state:$state,reason:$reason,
		  runtime_identity:{platform:$platform,package_id:$package_id,
		    browser_sha256:$browser_sha256,source_generation:$source_generation},
		  maximum_age_seconds:$maximum_age_seconds}'
}

for index in "${!mechanisms[@]}"; do
	results+=("$(status_result "${mechanisms[index]}" "${maximum_ages[index]}")")
done

healthy=$(printf '%s\n' "${results[@]}" |
	jq -s 'all(.state == "healthy") and
	  ([.[].runtime_identity] | unique | length) == 1')
printf '%s\n' "${results[@]}" |
	jq -sc \
		--arg source_device "$source_device" \
		--arg profile "$profile" \
		--argjson healthy "$healthy" \
		'{schema_version:1,source_device:$source_device,profile:$profile,
		  healthy:$healthy,mechanisms:.}'

[ "$healthy" = true ]
