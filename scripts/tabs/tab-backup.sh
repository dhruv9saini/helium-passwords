#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=tab-ops-lib.sh
source "${script_dir}/tab-ops-lib.sh"

usage() {
    cat >&2 <<'EOF'
usage: tab-backup.sh <command> CONFIG [arguments]

Commands:
  preflight
  backup [GENERATION]
  status [GENERATION]
  retention-plan PLAN-FILE
  retention-apply PLAN-FILE
  quarantine DESTINATION-ID|local-spool GENERATION REASON-SLUG
  restore-to-disposable DESTINATION-ID GENERATION NEW-DIRECTORY
EOF
}

valid_generation() {
    [[ "$1" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]]
}

validate_recipients() {
	tab_ops_recipients_fingerprint "${TAB_AGE_RECIPIENTS}" >/dev/null
}

manifest_value() {
    local manifest_file=$1 manifest_key=$2
    awk -F= -v key="${manifest_key}" \
        '$1 == key { print substr($0, length(key) + 2); exit }' "${manifest_file}"
}

destination_index() {
    local wanted=$1 index
    for index in 0 1; do
        [ "${TAB_DEST_IDS[index]}" = "${wanted}" ] && {
            printf '%s\n' "${index}"
            return 0
        }
    done
    echo "unknown destination: ${wanted}" >&2
    return 1
}

destination_run() {
    local index=$1 command_text
    shift
	printf -v command_text '%q ' "$@"
	ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
		-o ClearAllForwardings=yes -o RequestTTY=no -o IdentitiesOnly=yes \
		-o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null \
		-o "UserKnownHostsFile=${TAB_SSH_KNOWN_HOSTS}" \
		-i "${TAB_SSH_IDENTITY}" -l "${TAB_SSH_USER}" \
		"${TAB_DEST_SSH[index]}" "${command_text}"
}

destination_rsh() {
	printf 'ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=%s -i %s -l %s\n' \
		"${TAB_SSH_KNOWN_HOSTS}" "${TAB_SSH_IDENTITY}" "${TAB_SSH_USER}"
}

verify_destination_host() {
    local index=$1 actual
    actual=$(destination_run "${index}" uname -n)
    actual=${actual%%.*}
    [ "${actual}" = "${TAB_DEST_HOSTS[index]}" ] || {
        echo "destination host identity mismatch for ${TAB_DEST_IDS[index]}" >&2
        return 1
    }
}

verify_destination_storage() {
	local index=$1 probe=$2 mount_target
	[ "${TAB_DEST_ROLES[index]}" = nas ] || return 0
	mount_target=$(destination_run "${index}" findmnt --target "${probe}" \
		--noheadings --output TARGET | awk 'NF { print $1; exit }')
	[ -n "${mount_target}" ] && [ "${mount_target}" != / ] || {
		echo "destination nas-on-lm is not backed by a separately mounted filesystem" >&2
		return 1
	}
}

destination_namespace() {
    local index=$1
    tab_ops_namespace "${TAB_DEST_ROOTS[index]}"
}

destination_cipher() {
    local index=$1 generation=$2
    printf '%s/generations/%s.tar.age\n' "$(destination_namespace "${index}")" "${generation}"
}

destination_manifest() {
    local index=$1 generation=$2
    printf '%s/generations/%s.backup.env\n' "$(destination_namespace "${index}")" "${generation}"
}

destination_exists() {
    destination_run "$1" test -f "$2"
}

destination_sha256() {
    destination_run "$1" sha256sum "$2" | awk '{ print $1 }'
}

latest_valid_generation() {
    "${TAB_HELIUM_TABS}" list --store "${TAB_SNAPSHOT_STORE}" | \
        jq -er '[.[] | select(.Valid == true)][0].Manifest.generation'
}

validate_snapshot() {
    local generation=$1 output=$2
    "${TAB_HELIUM_TABS}" validate --store "${TAB_SNAPSHOT_STORE}" \
        --generation "${generation}" >"${output}"
    [ "$(jq -r '.device' "${output}")" = "${TAB_SOURCE_DEVICE}" ] && \
        [ "$(jq -r '.profile' "${output}")" = "${TAB_PROFILE}" ] || {
        echo "snapshot device/profile does not match backup namespace" >&2
        return 1
    }
}

write_backup_manifest() {
    local generation=$1 cipher=$2 snapshot_json=$3 output=$4 temporary
    temporary="${output}.tmp"
    {
		printf 'schema_version=2\nsource_device=%s\nprofile=%s\nkey_id=%s\n' \
			"${TAB_SOURCE_DEVICE}" "${TAB_PROFILE}" "${TAB_KEY_ID}"
		printf 'recipients_sha256=%s\n' "$(tab_ops_recipients_fingerprint "${TAB_AGE_RECIPIENTS}")"
        printf 'generation=%s\n' "${generation}"
        printf 'cipher_sha256=%s\n' "$(sha256sum "${cipher}" | awk '{ print $1 }')"
        printf 'cipher_size=%s\n' "$(stat -c %s "${cipher}")"
        printf 'snapshot_manifest_sha256=%s\n' "$(sha256sum "${snapshot_json}" | awk '{ print $1 }')"
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    } >"${temporary}"
    chmod 600 "${temporary}"
    mv "${temporary}" "${output}"
}

verify_local_pair() {
    local cipher=$1 backup_manifest=$2 generation=$3 expected_hash
    [ -f "${cipher}" ] && [ -f "${backup_manifest}" ] || return 1
	[ "$(manifest_value "${backup_manifest}" schema_version)" = 2 ] && \
        [ "$(manifest_value "${backup_manifest}" source_device)" = "${TAB_SOURCE_DEVICE}" ] && \
        [ "$(manifest_value "${backup_manifest}" profile)" = "${TAB_PROFILE}" ] && \
		[ "$(manifest_value "${backup_manifest}" key_id)" = "${TAB_KEY_ID}" ] && \
		[ "$(manifest_value "${backup_manifest}" recipients_sha256)" = \
			"$(tab_ops_recipients_fingerprint "${TAB_AGE_RECIPIENTS}")" ] && \
        [ "$(manifest_value "${backup_manifest}" generation)" = "${generation}" ] || return 1
    expected_hash=$(manifest_value "${backup_manifest}" cipher_sha256)
    [[ "${expected_hash}" =~ ^[a-f0-9]{64}$ ]] && \
        [ "$(sha256sum "${cipher}" | awk '{ print $1 }')" = "${expected_hash}" ]
}

encrypt_generation() {
    local generation=$1 snapshot_json=$2 cipher=$3 backup_manifest=$4 temporary
    validate_recipients
    command -v age >/dev/null || { echo "age is required before tab backups can run" >&2; return 1; }
    temporary="${cipher}.tmp"
    tar -C "${TAB_SNAPSHOT_STORE}/generations" -cf - "${generation}" | \
        age --encrypt --recipients-file "${TAB_AGE_RECIPIENTS}" --output "${temporary}"
    chmod 600 "${temporary}"
    mv "${temporary}" "${cipher}"
    write_backup_manifest "${generation}" "${cipher}" "${snapshot_json}" "${backup_manifest}"
}

backup_preflight() {
    [ -x "${TAB_HELIUM_TABS}" ] || { echo "helium-tabs is unavailable" >&2; return 1; }
    [ -x "${TAB_EXPORTER}" ] || { echo "browser API tab exporter is unavailable" >&2; return 1; }
    command -v age >/dev/null || { echo "age is unavailable" >&2; return 1; }
    command -v jq >/dev/null || { echo "jq is unavailable" >&2; return 1; }
    validate_recipients
	"${TAB_EXPORTER}" --source "${TAB_BROWSER_EXPORT}" \
		--max-age-seconds "${TAB_BROWSER_EXPORT_MAX_AGE_SECONDS}" --check >/dev/null
    local index
	for index in 0 1; do
        verify_destination_host "${index}"
        local destination_probe=${TAB_DEST_ROOTS[index]}
        if ! destination_run "${index}" test -d "${destination_probe}"; then
            destination_probe=$(dirname "${destination_probe}")
        fi
        destination_run "${index}" test -d "${destination_probe}"
        destination_run "${index}" test -w "${destination_probe}"
		verify_destination_storage "${index}" "${destination_probe}"
    done
	printf 'preflight=ok\nsource_device=%s\nprofile=%s\nkey_id=%s\n' \
		"${TAB_SOURCE_DEVICE}" "${TAB_PROFILE}" "${TAB_KEY_ID}"
}

copy_file_to_destination() {
    local index=$1 source_file=$2 incoming=$3
	rsync -e "$(destination_rsh)" --archive --chmod=F600 "${source_file}" \
		"${TAB_DEST_SSH[index]}:${incoming}"
}

copy_to_destination() {
    local index=$1 generation=$2 cipher=$3 backup_manifest=$4 namespace final_cipher final_manifest
    local incoming_cipher incoming_manifest cipher_hash manifest_hash cipher_size available
    verify_destination_host "${index}"
    namespace=$(destination_namespace "${index}")
    final_cipher=$(destination_cipher "${index}" "${generation}")
    final_manifest=$(destination_manifest "${index}" "${generation}")
    cipher_hash=$(manifest_value "${backup_manifest}" cipher_sha256)
    manifest_hash=$(sha256sum "${backup_manifest}" | awk '{ print $1 }')
    cipher_size=$(manifest_value "${backup_manifest}" cipher_size)
    destination_run "${index}" mkdir -p \
        "${namespace}/generations" "${namespace}/incoming" "${namespace}/quarantine"
	verify_destination_storage "${index}" "${namespace}"
    available=$(destination_run "${index}" df -PB1 "${namespace}" | awk 'NR == 2 { print $4 }')
    [[ "${available}" =~ ^[0-9]+$ ]] && \
        [ "${available}" -ge "$((cipher_size + TAB_DESTINATION_RESERVE_BYTES))" ] || {
        echo "destination ${TAB_DEST_IDS[index]} lacks its free-space reserve" >&2
        return 1
    }

    if destination_exists "${index}" "${final_cipher}" || destination_exists "${index}" "${final_manifest}"; then
        destination_exists "${index}" "${final_cipher}" && destination_exists "${index}" "${final_manifest}" && \
            [ "$(destination_sha256 "${index}" "${final_cipher}")" = "${cipher_hash}" ] && \
            [ "$(destination_sha256 "${index}" "${final_manifest}")" = "${manifest_hash}" ] || {
            echo "destination has conflicting data; quarantine it explicitly before retry" >&2
            return 1
        }
        return 0
    fi

    incoming_cipher="${namespace}/incoming/${generation}.tar.age.$$"
    incoming_manifest="${namespace}/incoming/${generation}.backup.env.$$"
    copy_file_to_destination "${index}" "${cipher}" "${incoming_cipher}"
    [ "$(destination_sha256 "${index}" "${incoming_cipher}")" = "${cipher_hash}" ] || {
        echo "cipher transfer checksum mismatch" >&2
        return 1
    }
    copy_file_to_destination "${index}" "${backup_manifest}" "${incoming_manifest}"
    [ "$(destination_sha256 "${index}" "${incoming_manifest}")" = "${manifest_hash}" ] || {
        echo "manifest transfer checksum mismatch" >&2
        return 1
    }
    destination_run "${index}" mv "${incoming_cipher}" "${final_cipher}"
    destination_run "${index}" mv "${incoming_manifest}" "${final_manifest}"
}

destination_status() {
    local index=$1 generation=$2 expected_hash=$3 expected_manifest_hash=$4
    local cipher backup_manifest actual_hash actual_manifest_hash
    if ! verify_destination_host "${index}" 2>/dev/null; then
        printf 'destination=%s status=unreachable_or_wrong_host\n' "${TAB_DEST_IDS[index]}"
        return 1
    fi
    cipher=$(destination_cipher "${index}" "${generation}")
    backup_manifest=$(destination_manifest "${index}" "${generation}")
    if ! destination_exists "${index}" "${cipher}" || ! destination_exists "${index}" "${backup_manifest}"; then
        printf 'destination=%s status=missing\n' "${TAB_DEST_IDS[index]}"
        return 1
    fi
    actual_hash=$(destination_sha256 "${index}" "${cipher}")
    actual_manifest_hash=$(destination_sha256 "${index}" "${backup_manifest}")
    if [ "${actual_hash}" = "${expected_hash}" ] && \
        [ "${actual_manifest_hash}" = "${expected_manifest_hash}" ]; then
        printf 'destination=%s status=healthy hash=%s\n' "${TAB_DEST_IDS[index]}" "${actual_hash}"
        return 0
    fi
    printf 'destination=%s status=hash_mismatch\n' "${TAB_DEST_IDS[index]}"
    return 1
}

status_generation() {
    local generation=${1:-} namespace backup_manifest expected_hash expected_manifest_hash index failures=0
    [ -n "${generation}" ] || generation=$(latest_valid_generation)
    valid_generation "${generation}" || { echo "invalid generation" >&2; return 1; }
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    backup_manifest="${namespace}/encrypted/${generation}.backup.env"
    [ -f "${backup_manifest}" ] || {
        printf 'generation=%s\nstatus=not_encrypted\n' "${generation}"
        return 1
    }
    expected_hash=$(manifest_value "${backup_manifest}" cipher_sha256)
    expected_manifest_hash=$(sha256sum "${backup_manifest}" | awk '{ print $1 }')
    [[ "${expected_hash}" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf 'generation=%s\n' "${generation}"
    for index in 0 1; do
        destination_status "${index}" "${generation}" "${expected_hash}" \
            "${expected_manifest_hash}" || failures=$((failures + 1))
    done
    if [ "${failures}" -eq 0 ]; then echo 'status=healthy'; else echo 'status=degraded'; return 1; fi
}

backup_generation() {
    local generation=${1:-} namespace cipher backup_manifest snapshot_json index
    [ -x "${TAB_HELIUM_TABS}" ] || { echo "helium-tabs is unavailable" >&2; return 1; }
    [ -n "${generation}" ] || generation=$(latest_valid_generation)
    valid_generation "${generation}" || { echo "invalid generation" >&2; return 1; }
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    mkdir -p "${namespace}/encrypted" "${namespace}/tmp" "${namespace}/quarantine"
    chmod 700 "${namespace}" "${namespace}/encrypted" "${namespace}/tmp" "${namespace}/quarantine"
    exec 9>"${namespace}/backup.lock"
    flock -n 9 || { echo "another tab backup operation is active" >&2; return 1; }
    snapshot_json="${namespace}/tmp/${generation}.snapshot.json"
    cipher="${namespace}/encrypted/${generation}.tar.age"
    backup_manifest="${namespace}/encrypted/${generation}.backup.env"
    validate_snapshot "${generation}" "${snapshot_json}"
    if ! verify_local_pair "${cipher}" "${backup_manifest}" "${generation}"; then
        [ ! -e "${cipher}" ] && [ ! -e "${backup_manifest}" ] || {
            echo "local encrypted generation is incomplete or corrupt; quarantine it explicitly" >&2
            return 1
        }
        encrypt_generation "${generation}" "${snapshot_json}" "${cipher}" "${backup_manifest}"
    fi
    find "${snapshot_json}" -delete
    for index in 0 1; do
        copy_to_destination "${index}" "${generation}" "${cipher}" "${backup_manifest}"
    done
    status_generation "${generation}"
}

quarantine_destination() {
    local destination_id=$1 generation=$2 reason=$3 index cipher backup_manifest namespace stamp
    valid_generation "${generation}" || { echo "invalid generation" >&2; return 1; }
    tab_ops_valid_id "${reason}" || { echo "reason must be a short slug" >&2; return 1; }
    index=$(destination_index "${destination_id}")
    verify_destination_host "${index}"
    cipher=$(destination_cipher "${index}" "${generation}")
    backup_manifest=$(destination_manifest "${index}" "${generation}")
    namespace=$(destination_namespace "${index}")
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    destination_run "${index}" mkdir -p "${namespace}/quarantine"
    if destination_exists "${index}" "${cipher}"; then
        destination_run "${index}" mv "${cipher}" \
            "${namespace}/quarantine/${stamp}-${generation}-${reason}.tar.age"
    fi
    if destination_exists "${index}" "${backup_manifest}"; then
        destination_run "${index}" mv "${backup_manifest}" \
            "${namespace}/quarantine/${stamp}-${generation}-${reason}.backup.env"
    fi
    printf 'quarantined_destination=%s\ngeneration=%s\nreason=%s\n' \
        "${destination_id}" "${generation}" "${reason}"
}

quarantine_local_spool() {
    local generation=$1 reason=$2 namespace cipher backup_manifest stamp moved=false
    valid_generation "${generation}" || { echo "invalid generation" >&2; return 1; }
    tab_ops_valid_id "${reason}" || { echo "reason must be a short slug" >&2; return 1; }
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    cipher="${namespace}/encrypted/${generation}.tar.age"
    backup_manifest="${namespace}/encrypted/${generation}.backup.env"
    mkdir -p "${namespace}/quarantine"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if [ -e "${cipher}" ]; then
        mv "${cipher}" "${namespace}/quarantine/${stamp}-${generation}-${reason}.tar.age"
        moved=true
    fi
    if [ -e "${backup_manifest}" ]; then
        mv "${backup_manifest}" "${namespace}/quarantine/${stamp}-${generation}-${reason}.backup.env"
        moved=true
    fi
    [ "${moved}" = true ] || { echo "local encrypted generation is missing" >&2; return 1; }
    printf 'quarantined_destination=local-spool\ngeneration=%s\nreason=%s\n' \
        "${generation}" "${reason}"
}

retention_plan() {
    local plan_file=$1 namespace store_plan plan_sha temporary generation backup_manifest expected_hash index healthy
    local store_delete_count eligible_count=0 expected_manifest_hash
    tab_ops_require_absolute plan_file "${plan_file}"
    [ ! -e "${plan_file}" ] || { echo "retention plan already exists" >&2; return 1; }
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    mkdir -p "${namespace}/tmp"
    store_plan="${namespace}/tmp/retention-store.$$.json"
    temporary="${plan_file}.tmp"
    "${TAB_HELIUM_TABS}" retention-plan --store "${TAB_SNAPSHOT_STORE}" >"${store_plan}"
    plan_sha=$(sha256sum "${store_plan}" | awk '{ print $1 }')
    store_delete_count=$(jq -r '.Delete | length' "${store_plan}")
    {
        printf 'schema_version=1\nsource_device=%s\nprofile=%s\nstore_plan_sha256=%s\nstore_delete_count=%s\ncreated_at=%s\n' \
            "${TAB_SOURCE_DEVICE}" "${TAB_PROFILE}" "${plan_sha}" \
            "${store_delete_count}" "$(date --iso-8601=seconds)"
        while IFS= read -r generation; do
            backup_manifest="${namespace}/encrypted/${generation}.backup.env"
            [ -f "${backup_manifest}" ] || continue
            expected_hash=$(manifest_value "${backup_manifest}" cipher_sha256)
            expected_manifest_hash=$(sha256sum "${backup_manifest}" | awk '{ print $1 }')
            healthy=true
            for index in 0 1; do
                destination_status "${index}" "${generation}" "${expected_hash}" \
                    "${expected_manifest_hash}" >/dev/null || healthy=false
            done
            if [ "${healthy}" = true ]; then
                printf 'generation=%s\n' "${generation}"
                eligible_count=$((eligible_count + 1))
            fi
        done < <(jq -r '.Delete[]?' "${store_plan}")
        if [ "${eligible_count}" -eq "${store_delete_count}" ]; then
            echo 'complete=true'
        else
            echo 'complete=false'
        fi
    } >"${temporary}"
    chmod 600 "${temporary}"
    mv "${temporary}" "${plan_file}"
    find "${store_plan}" -delete
    cat "${plan_file}"
}

retention_apply() {
    local plan_file=$1 namespace current_plan current_sha recorded_sha generation index
    [ -f "${plan_file}" ] || { echo "retention plan is missing" >&2; return 1; }
    grep -qx 'complete=true' "${plan_file}" || {
        echo "retention refused until every local deletion candidate has two healthy copies" >&2
        return 1
    }
    namespace=$(tab_ops_namespace "${TAB_STATE_ROOT}")
    current_plan="${namespace}/tmp/retention-current.$$.json"
    "${TAB_HELIUM_TABS}" retention-plan --store "${TAB_SNAPSHOT_STORE}" >"${current_plan}"
    current_sha=$(sha256sum "${current_plan}" | awk '{ print $1 }')
    recorded_sha=$(manifest_value "${plan_file}" store_plan_sha256)
    [ "${current_sha}" = "${recorded_sha}" ] || {
        find "${current_plan}" -delete
        echo "retention plan is stale; generate a new plan" >&2
        return 1
    }
    find "${current_plan}" -delete
    while IFS= read -r generation; do
        valid_generation "${generation}" || { echo "invalid generation in plan" >&2; return 1; }
        status_generation "${generation}" >/dev/null
        for index in 0 1; do
            quarantine_destination "${TAB_DEST_IDS[index]}" "${generation}" retention >/dev/null
        done
        find "${namespace}/encrypted/${generation}.tar.age" \
            "${namespace}/encrypted/${generation}.backup.env" -maxdepth 0 -type f -delete
        printf 'off_device_quarantine=%s\n' "${generation}"
    done < <(awk -F= '$1 == "generation" { print $2 }' "${plan_file}")
    "${TAB_HELIUM_TABS}" retention-apply --store "${TAB_SNAPSHOT_STORE}" >/dev/null
}

fetch_destination_file() {
    local index=$1 remote_file=$2 local_file=$3
	rsync -e "$(destination_rsh)" --archive \
		"${TAB_DEST_SSH[index]}:${remote_file}" "${local_file}"
	chmod 600 "${local_file}"
}

restore_disposable() {
    local destination_id=$1 generation=$2 restore_destination=$3 index temporary expected_hash archive listing temp_store
    local identity_mode restored_manifest
    valid_generation "${generation}" || { echo "invalid generation" >&2; return 1; }
    tab_ops_require_absolute restore_destination "${restore_destination}"
    [ ! -e "${restore_destination}" ] || { echo "restore destination already exists" >&2; return 1; }
    [ -f "${TAB_AGE_IDENTITY}" ] || { echo "age identity file is unavailable" >&2; return 1; }
    identity_mode=$(stat -c %a "${TAB_AGE_IDENTITY}")
    (( (8#${identity_mode} & 8#077) == 0 )) || {
        echo "age identity file must not be accessible by group or world" >&2
        return 1
    }
    command -v age >/dev/null || { echo "age is required before restore" >&2; return 1; }
    index=$(destination_index "${destination_id}")
    verify_destination_host "${index}"
    temporary=$(mktemp -d /tmp/helium-tab-restore.XXXXXX)
    cleanup_restore() {
        local result=$?
		[ -z "${temporary:-}" ] || find "${temporary}" -depth -delete 2>/dev/null || true
        return "${result}"
    }
    trap cleanup_restore EXIT
    fetch_destination_file "${index}" "$(destination_cipher "${index}" "${generation}")" \
        "${temporary}/generation.tar.age"
    fetch_destination_file "${index}" "$(destination_manifest "${index}" "${generation}")" \
        "${temporary}/generation.backup.env"
	[ "$(manifest_value "${temporary}/generation.backup.env" schema_version)" = 2 ] && \
        [ "$(manifest_value "${temporary}/generation.backup.env" source_device)" = "${TAB_SOURCE_DEVICE}" ] && \
        [ "$(manifest_value "${temporary}/generation.backup.env" profile)" = "${TAB_PROFILE}" ] && \
		[ "$(manifest_value "${temporary}/generation.backup.env" key_id)" = "${TAB_KEY_ID}" ] && \
		[ "$(manifest_value "${temporary}/generation.backup.env" recipients_sha256)" = \
			"$(tab_ops_recipients_fingerprint "${TAB_AGE_RECIPIENTS}")" ] && \
        [ "$(manifest_value "${temporary}/generation.backup.env" generation)" = "${generation}" ] || {
        echo "backup manifest namespace mismatch" >&2
        return 1
    }
    expected_hash=$(manifest_value "${temporary}/generation.backup.env" cipher_sha256)
    [ "$(sha256sum "${temporary}/generation.tar.age" | awk '{ print $1 }')" = "${expected_hash}" ] || {
        echo "encrypted backup hash mismatch" >&2
        return 1
    }
    archive="${temporary}/generation.tar"
    age --decrypt --identity "${TAB_AGE_IDENTITY}" --output "${archive}" \
        "${temporary}/generation.tar.age"
    listing="${temporary}/archive.list"
    tar -tf "${archive}" >"${listing}"
    awk -v generation="${generation}" '
      $0 == generation "/" || $0 == generation "/manifest.json" || $0 == generation "/session.json" { next }
      { bad = 1 }
      END { exit bad }
    ' "${listing}" || { echo "backup archive contains unexpected paths" >&2; return 1; }
    [ "$(wc -l <"${listing}")" -eq 3 ] || { echo "backup archive inventory is incomplete" >&2; return 1; }
    temp_store="${temporary}/store"
    mkdir -p "${temp_store}/generations"
    chmod 700 "${temp_store}" "${temp_store}/generations"
    tar --no-same-owner --no-same-permissions -xf "${archive}" -C "${temp_store}/generations"
	chmod 700 "${temp_store}/generations/${generation}"
	chmod 600 "${temp_store}/generations/${generation}/manifest.json" \
		"${temp_store}/generations/${generation}/session.json"
    restored_manifest="${temporary}/restored-manifest.json"
    "${TAB_HELIUM_TABS}" validate --store "${temp_store}" --generation "${generation}" >"${restored_manifest}"
    [ "$(jq -r '.device' "${restored_manifest}")" = "${TAB_SOURCE_DEVICE}" ] && \
        [ "$(jq -r '.profile' "${restored_manifest}")" = "${TAB_PROFILE}" ] || {
        echo "decrypted snapshot namespace mismatch" >&2
        return 1
    }
    "${TAB_HELIUM_TABS}" restore --store "${temp_store}" --generation "${generation}" \
        --destination "${restore_destination}"
	"${TAB_HELIUM_TABS}" validate-restore --destination "${restore_destination}" \
		>"${temporary}/restore-validation.json"
	[ "$(jq -r '.source_generation' "${temporary}/restore-validation.json")" = "${generation}" ] && \
		[ "$(jq -r '.source_device' "${temporary}/restore-validation.json")" = "${TAB_SOURCE_DEVICE}" ] && \
		[ "$(jq -r '.source_profile' "${temporary}/restore-validation.json")" = "${TAB_PROFILE}" ] || {
		echo "disposable restore receipt mismatch" >&2
		return 1
	}
    find "${temporary}" -depth -delete
    trap - EXIT
}

[ "$#" -ge 2 ] || { usage; exit 2; }
command_name=$1
config_file=$2
shift 2
tab_ops_load_config "${config_file}"
tab_ops_validate_destinations
tab_ops_require_source_host
tab_ops_require_ssh_material
tab_ops_require_absolute age_recipients "${TAB_AGE_RECIPIENTS}"
tab_ops_require_absolute age_identity "${TAB_AGE_IDENTITY}"

case "${command_name}" in
    preflight) [ "$#" -eq 0 ] || exit 2; backup_preflight ;;
    backup) [ "$#" -le 1 ] || exit 2; backup_generation "${1:-}" ;;
    status) [ "$#" -le 1 ] || exit 2; status_generation "${1:-}" ;;
    retention-plan) [ "$#" -eq 1 ] || exit 2; retention_plan "$1" ;;
    retention-apply) [ "$#" -eq 1 ] || exit 2; retention_apply "$1" ;;
    quarantine)
        [ "$#" -eq 3 ] || exit 2
        if [ "$1" = local-spool ]; then quarantine_local_spool "$2" "$3"; else quarantine_destination "$1" "$2" "$3"; fi
        ;;
    restore-to-disposable) [ "$#" -eq 3 ] || exit 2; restore_disposable "$1" "$2" "$3" ;;
    *) usage; exit 2 ;;
esac
