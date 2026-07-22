#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=tab-ops-lib.sh
source "${script_dir}/tab-ops-lib.sh"

usage() {
    echo "usage: tab-snapshot-scheduler.sh <run-once|cycle|schedule|status> CONFIG" >&2
}

write_status() {
    local scheduler_state=$1 reason=$2 generation=${3:-} namespace status_file temporary
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    mkdir -p "${namespace}"
    chmod 700 "${namespace}"
    status_file="${namespace}/snapshot-status.env"
    temporary="${status_file}.tmp"
    {
        printf 'state=%s\nreason=%s\ngeneration=%s\n' "${scheduler_state}" "${reason}" "${generation}"
        printf 'checked_at_epoch=%s\nchecked_at=%s\n' "$(date +%s)" "$(date --iso-8601=seconds)"
    } >"${temporary}"
    chmod 600 "${temporary}"
    mv "${temporary}" "${status_file}"
}

proof_value() {
	local proof_file=$1 proof_key=$2
	awk -F= -v key="${proof_key}" \
		'$1 == key { print substr($0, length(key) + 2); exit }' "${proof_file}"
}

write_health_proof() {
	local generation=$1 backup_output=$2 namespace proof_file temporary
	namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
	proof_file="${namespace}/health-proof.env"
	temporary="${proof_file}.tmp"
	{
		printf 'schema_version=1\nsource_device=%s\nprofile=%s\nkey_id=%s\n' \
			"${TAB_SOURCE_DEVICE}" "${TAB_PROFILE}" "${TAB_KEY_ID}"
		printf 'generation=%s\nconfig_sha256=%s\nbackup_status_sha256=%s\n' \
			"${generation}" "$(sha256sum "${config_file}" | awk '{ print $1 }')" \
			"$(printf '%s\n' "${backup_output}" | sha256sum | awk '{ print $1 }')"
		printf 'destination_0=%s@%s\ndestination_1=%s@%s\n' \
			"${TAB_DEST_IDS[0]}" "${TAB_DEST_HOSTS[0]}" \
			"${TAB_DEST_IDS[1]}" "${TAB_DEST_HOSTS[1]}"
		printf 'checked_at_epoch=%s\nchecked_at=%s\n' "$(date +%s)" "$(date --iso-8601=seconds)"
	} >"${temporary}"
	chmod 600 "${temporary}"
	mv "${temporary}" "${proof_file}"
}

verify_health_proof() {
	local generation=$1 backup_output=$2 namespace proof_file expected_status_hash
	namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
	proof_file="${namespace}/health-proof.env"
	[ -f "${proof_file}" ] || { echo 'health_proof=missing'; return 1; }
	expected_status_hash=$(printf '%s\n' "${backup_output}" | sha256sum | awk '{ print $1 }')
	[ "$(proof_value "${proof_file}" schema_version)" = 1 ] && \
		[ "$(proof_value "${proof_file}" source_device)" = "${TAB_SOURCE_DEVICE}" ] && \
		[ "$(proof_value "${proof_file}" profile)" = "${TAB_PROFILE}" ] && \
		[ "$(proof_value "${proof_file}" key_id)" = "${TAB_KEY_ID}" ] && \
		[ "$(proof_value "${proof_file}" generation)" = "${generation}" ] && \
		[ "$(proof_value "${proof_file}" config_sha256)" = \
			"$(sha256sum "${config_file}" | awk '{ print $1 }')" ] && \
		[ "$(proof_value "${proof_file}" backup_status_sha256)" = "${expected_status_hash}" ] && \
		[ "$(proof_value "${proof_file}" destination_0)" = \
			"${TAB_DEST_IDS[0]}@${TAB_DEST_HOSTS[0]}" ] && \
		[ "$(proof_value "${proof_file}" destination_1)" = \
			"${TAB_DEST_IDS[1]}@${TAB_DEST_HOSTS[1]}" ] || {
		echo 'health_proof=stale_or_invalid'
		return 1
	}
	cat "${proof_file}"
	echo 'health_proof=verified'
}

capture_once() {
    [ -x "${TAB_HELIUM_TABS}" ] || {
        write_status failure helium_tabs_unavailable
        echo "helium-tabs executable is unavailable" >&2
        return 1
    }
    [ -x "${TAB_EXPORTER}" ] || {
        write_status blocked browser_exporter_unavailable
        echo "browser API tab exporter is unavailable" >&2
        return 1
    }

    local namespace temporary session_json capture_json generation
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    mkdir -p "${namespace}/tmp"
    chmod 700 "${namespace}" "${namespace}/tmp"
    exec 9>"${namespace}/snapshot.lock"
    flock -n 9 || { echo "another snapshot capture is active" >&2; return 1; }

    temporary=$(mktemp -d "${namespace}/tmp/capture.XXXXXX")
    cleanup_capture() {
        local result=$?
		[ -z "${temporary:-}" ] || find "${temporary}" -depth -delete 2>/dev/null || true
        return "${result}"
    }
    trap cleanup_capture EXIT
    session_json="${temporary}/session.json"
    capture_json="${temporary}/capture.json"
    write_status running browser_export

	if ! "${TAB_EXPORTER}" --source "${TAB_BROWSER_EXPORT}" \
		--max-age-seconds "${TAB_BROWSER_EXPORT_MAX_AGE_SECONDS}" \
		--output "${session_json}" >"${temporary}/export.stdout" 2>"${temporary}/export.stderr"; then
        write_status failure browser_export_failed
        echo "browser API tab export failed; payload and exporter output were discarded" >&2
        return 1
    fi
    [ -s "${session_json}" ] || {
        write_status failure browser_export_empty
        echo "browser API tab exporter produced no session" >&2
        return 1
    }
    chmod 600 "${session_json}"
    if ! "${TAB_HELIUM_TABS}" capture \
        --store "${TAB_SNAPSHOT_STORE}" --input "${session_json}" \
        --device "${TAB_SOURCE_DEVICE}" --profile "${TAB_PROFILE}" \
        --browser-version "${TAB_BROWSER_VERSION}" \
        --chromium-version "${TAB_CHROMIUM_VERSION}" --reason scheduled \
        >"${capture_json}" 2>"${temporary}/capture.error"; then
        write_status failure snapshot_validation_or_commit_failed
        echo "tab snapshot validation or atomic commit failed" >&2
        return 1
    fi
    generation=$(jq -er '.generation' "${capture_json}")
    [[ "${generation}" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]] || {
        write_status failure invalid_generation_result
        echo "helium-tabs returned an invalid generation" >&2
        return 1
    }
    "${TAB_HELIUM_TABS}" validate --store "${TAB_SNAPSHOT_STORE}" --generation "${generation}" >/dev/null
    write_status healthy capture_committed "${generation}"
    printf 'generation=%s\n' "${generation}"
    find "${temporary}" -depth -delete
    trap - EXIT
}

show_status() {
    local status_file now checked capture_age maximum generation backup_output
    status_file="$(tab_ops_namespace "${TAB_STATE_ROOT}")/snapshot-status.env"
    [ -f "${status_file}" ] || { echo "state=missing"; return 1; }
    cat "${status_file}"
    generation=$(awk -F= '$1 == "generation" { print $2; exit }' "${status_file}")
    checked=$(awk -F= '$1 == "checked_at_epoch" { print $2; exit }' "${status_file}")
    [[ "${checked}" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    capture_age=$((now - checked))
    maximum=$((TAB_INTERVAL_SECONDS * 2 + 60))
    printf 'age_seconds=%s\nmax_age_seconds=%s\n' "${capture_age}" "${maximum}"
    [ "${capture_age}" -le "${maximum}" ] && grep -q '^state=healthy$' "${status_file}" || return 1
    backup_output=$("${script_dir}/tab-backup.sh" status "${config_file}" "${generation}") || {
        printf '%s\n' "${backup_output}"
        return 1
    }
	verify_health_proof "${generation}" "${backup_output}"
    printf '%s\n' "${backup_output}"
}

cycle() {
    local capture_output generation backup_output namespace plan
    capture_output=$(capture_once) || return 1
    generation=${capture_output#generation=}
    if ! backup_output=$("${script_dir}/tab-backup.sh" backup "${config_file}" "${generation}"); then
        write_status degraded off_device_backup_failed "${generation}"
        printf '%s\n' "${backup_output}" >&2
        return 1
    fi
	write_health_proof "${generation}" "${backup_output}"
    write_status healthy two_off_device_copies_committed "${generation}"
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    mkdir -p "${namespace}/retention-plans"
    plan="${namespace}/retention-plans/$(date -u +%Y%m%dT%H%M%S.%NZ).plan"
    "${script_dir}/tab-backup.sh" retention-plan "${config_file}" "${plan}" >/dev/null
    if grep -qx 'complete=true' "${plan}" && grep -q '^generation=' "${plan}"; then
        "${script_dir}/tab-backup.sh" retention-apply "${config_file}" "${plan}" >/dev/null
    fi
    printf '%s\n' "${backup_output}"
}

schedule() {
    while true; do
        cycle || true
        sleep "${TAB_INTERVAL_SECONDS}"
    done
}

[ "$#" -eq 2 ] || { usage; exit 2; }
command_name=$1
config_file=$2
tab_ops_load_config "${config_file}"
tab_ops_validate_destinations
tab_ops_require_source_host
case "${command_name}" in
    run-once) capture_once ;;
    cycle) cycle ;;
    schedule) schedule ;;
    status) show_status ;;
    *) usage; exit 2 ;;
esac
