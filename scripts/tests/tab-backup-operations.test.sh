#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
temporary=$(mktemp -d /tmp/helium-tab-ops-test.XXXXXX)
cleanup() {
    local result=$?
    find "${temporary}" -depth -delete 2>/dev/null || true
    return "${result}"
}
trap cleanup EXIT

mkdir -p "${temporary}/bin" "${temporary}/snapshots" "${temporary}/state" \
    "${temporary}/destination-lm" "${temporary}/destination-two"
go build -o "${temporary}/bin/helium-tabs" "${repo_root}/cmd/helium-tabs"

browser_export="${temporary}/browser-export.json"
cat >"${browser_export}" <<'JSON'
{
  "schema_version": 1,
  "windows": [{
    "id": "window-fixture",
    "active_index": 0,
    "tabs": [{
      "id": "tab-fixture",
      "current_index": 0,
      "navigations": [{"url": "https://fixture.invalid/", "title": "Fixture"}]
    }]
  }]
}
JSON
chmod 600 "${browser_export}"

cat >"${temporary}/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
input=
decrypt=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --encrypt) shift ;;
        --decrypt) decrypt=true; shift ;;
        --recipients-file|--identity) [ -s "$2" ]; shift 2 ;;
        --output) output=$2; shift 2 ;;
        *) input=$1; shift ;;
    esac
done
[ -n "${output}" ]
if [ "${decrypt}" = true ]; then
    [ -f "${input}" ]
    tail -n +2 "${input}" >"${output}"
else
    { printf 'age-encrypted-fixture\n'; cat; } >"${output}"
fi
EOF

cat >"${temporary}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == -* ]]; do
    if [ "$1" = -o ]; then shift 2; else shift; fi
done
remote_alias=$1
shift
command_text=$1
command_text=${command_text//\/srv\/nas\/helium-tab-backups/${TAB_TEST_NAS_ROOT}}
if [[ "${command_text}" == "uname -n " ]]; then
    printf '%s\n' "${remote_alias}"
else
    bash -c "${command_text}"
fi
EOF

cat >"${temporary}/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
count=${#arguments[@]}
source_file=${arguments[count-2]}
destination_file=${arguments[count-1]}
source_file=${source_file#*:}
destination_file=${destination_file#*:}
source_file=${source_file/\/srv\/nas\/helium-tab-backups/${TAB_TEST_NAS_ROOT}}
destination_file=${destination_file/\/srv\/nas\/helium-tab-backups/${TAB_TEST_NAS_ROOT}}
install -m 600 "${source_file}" "${destination_file}"
EOF

cat >"${temporary}/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -n ]
printf 'da\n'
EOF

cat >"${temporary}/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '/synthetic-separate-nas\n'
EOF
chmod 700 "${temporary}/bin/age" "${temporary}/bin/ssh" \
	"${temporary}/bin/rsync" "${temporary}/bin/uname" "${temporary}/bin/findmnt"
printf '%s\n' \
    'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' \
    'age1pppppppppppppppppppppppppppppppppppppppppppppppppppp' \
    >"${temporary}/recipients.txt"
printf 'AGE-SECRET-KEY-SYNTHETIC\n' >"${temporary}/identity.txt"
chmod 600 "${temporary}/recipients.txt" "${temporary}/identity.txt"

config="${temporary}/tab-ops.conf"
cat >"${config}" <<EOF
version=2
source_device=da
key_id=da-tabs-v1
profile=default
snapshot_store=${temporary}/snapshots
state_root=${temporary}/state
helium_tabs=${temporary}/bin/helium-tabs
exporter=${repo_root}/scripts/tabs/helium-tab-exporter.sh
browser_export=${browser_export}
browser_export_max_age_seconds=420
browser_version=fixture
chromium_version=fixture
interval_seconds=60
age_recipients=${temporary}/recipients.txt
age_identity=${temporary}/identity.txt
destination_reserve_bytes=1
destination=nas-on-lm|nas|ssh|lm|lm|/srv/nas/helium-tab-backups
destination=d-copy|device|ssh|d|d|${temporary}/destination-two
EOF
chmod 600 "${config}"
export TAB_TEST_NAS_ROOT="${temporary}/destination-lm"
export PATH="${temporary}/bin:${PATH}"

adapter="${repo_root}/scripts/tabs/helium-tab-exporter.sh"
"${adapter}" --source "${browser_export}" --max-age-seconds 420 --check >/dev/null
adapter_output="${temporary}/adapter-output.json"
"${adapter}" --source "${browser_export}" --max-age-seconds 420 \
	--output "${adapter_output}" >/dev/null
cmp "${browser_export}" "${adapter_output}"
if "${adapter}" --source "${browser_export}" --max-age-seconds 420 \
	--output "${adapter_output}" >/dev/null 2>&1; then
	echo "tab exporter overwrote an existing output" >&2
	exit 1
fi

stale_export="${temporary}/stale-export.json"
install -m 600 "${browser_export}" "${stale_export}"
touch -d "@$(( $(date +%s) - 421 ))" "${stale_export}"
if "${adapter}" --source "${stale_export}" --max-age-seconds 420 --check >/dev/null 2>&1; then
	echo "stale browser tab export was accepted" >&2
	exit 1
fi
linked_export="${temporary}/linked-export.json"
ln -s "${browser_export}" "${linked_export}"
if "${adapter}" --source "${linked_export}" --max-age-seconds 420 --check >/dev/null 2>&1; then
	echo "symlink browser tab export was accepted" >&2
	exit 1
fi

cycle_output=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" cycle "${config}")
generation=$(awk -F= '$1 == "generation" { print $2; exit }' <<<"${cycle_output}")
[[ "${generation}" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]]
scheduler_status=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" status "${config}")
grep -q '^state=healthy$' <<<"${scheduler_status}"
grep -q '^health_proof=verified$' <<<"${scheduler_status}"
grep -q '^key_id=da-tabs-v1$' <<<"${scheduler_status}"

changed_config="${temporary}/changed.conf"
sed 's/interval_seconds=60/interval_seconds=61/' "${config}" >"${changed_config}"
chmod 600 "${changed_config}"
if "${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" status \
	"${changed_config}" >/dev/null 2>&1; then
	echo "health proof remained valid after configuration changed" >&2
	exit 1
fi

unbounded_freshness_config="${temporary}/unbounded-freshness.conf"
sed 's/browser_export_max_age_seconds=420/browser_export_max_age_seconds=601/' \
	"${config}" >"${unbounded_freshness_config}"
chmod 600 "${unbounded_freshness_config}"
if "${repo_root}/scripts/tabs/tab-backup.sh" preflight \
	"${unbounded_freshness_config}" >/dev/null 2>&1; then
	echo "unbounded browser export freshness was accepted" >&2
	exit 1
fi

grep -q '^status=healthy$' <<<"${cycle_output}"
for destination_root in "${temporary}/destination-lm" "${temporary}/destination-two"; do
	test -f "${destination_root}/da/default/generations/${generation}.tar.age"
	test -f "${destination_root}/da/default/generations/${generation}.backup.env"
done

first_generation=${generation}
cycle_output=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" cycle "${config}")
generation=$(awk -F= '$1 == "generation" { print $2; exit }' <<<"${cycle_output}")
[ "${generation}" != "${first_generation}" ]
test ! -e "${temporary}/snapshots/generations/${first_generation}"
test ! -e "${temporary}/state/da/default/encrypted/${first_generation}.tar.age"
for destination_root in "${temporary}/destination-lm" "${temporary}/destination-two"; do
	test ! -e "${destination_root}/da/default/generations/${first_generation}.tar.age"
	find "${destination_root}/da/default/quarantine" \
        -name "*-${first_generation}-retention.tar.age" -print -quit | grep -q .
	test -f "${destination_root}/da/default/generations/${generation}.tar.age"
done

restore_directory="${temporary}/disposable-restore"
"${repo_root}/scripts/tabs/tab-backup.sh" restore-to-disposable "${config}" \
	d-copy "${generation}" "${restore_directory}" >/dev/null
test -f "${restore_directory}/session.json"
test -f "${restore_directory}/restore-manifest.json"
grep -q 'fixture.invalid' "${restore_directory}/session.json"

printf 'corrupt\n' >"${temporary}/destination-two/da/default/generations/${generation}.tar.age"
if "${repo_root}/scripts/tabs/tab-backup.sh" status "${config}" "${generation}" >/dev/null 2>&1; then
    echo "corrupt destination unexpectedly reported healthy" >&2
    exit 1
fi
"${repo_root}/scripts/tabs/tab-backup.sh" quarantine "${config}" \
	d-copy "${generation}" synthetic-corruption >/dev/null
"${repo_root}/scripts/tabs/tab-backup.sh" backup "${config}" "${generation}" >/dev/null
backup_status=$("${repo_root}/scripts/tabs/tab-backup.sh" status "${config}" "${generation}")
grep -q '^status=healthy$' <<<"${backup_status}"
find "${temporary}/destination-two/da/default/quarantine" \
    -name "*-${generation}-synthetic-corruption.tar.age" -print -quit | grep -q .

plan="${temporary}/retention.plan"
"${repo_root}/scripts/tabs/tab-backup.sh" retention-plan "${config}" "${plan}" >/dev/null
grep -q '^schema_version=1$' "${plan}"
grep -q '^source_device=da$' "${plan}"

single_recipients="${temporary}/single-recipient.txt"
head -n 1 "${temporary}/recipients.txt" >"${single_recipients}"
single_config="${temporary}/single-recipient.conf"
sed "s#age_recipients=${temporary}/recipients.txt#age_recipients=${single_recipients}#" \
    "${config}" >"${single_config}"
chmod 600 "${single_config}"
if "${repo_root}/scripts/tabs/tab-backup.sh" preflight "${single_config}" >/dev/null 2>&1; then
    echo "single recovery recipient was not rejected" >&2
    exit 1
fi

bad_config="${temporary}/bad.conf"
sed 's/destination=d-copy|device|ssh|d|d|/destination=oneplus-copy|device|ssh|oneplus|oneplus|/' \
	"${config}" >"${bad_config}"
chmod 600 "${bad_config}"
if "${repo_root}/scripts/tabs/tab-backup.sh" status "${bad_config}" "${generation}" >/dev/null 2>&1; then
	echo "wrong fixed replica topology was not rejected" >&2
	exit 1
fi

wrong_host_config="${temporary}/wrong-host.conf"
sed -e 's/source_device=da/source_device=d/' \
	-e 's/key_id=da-tabs-v1/key_id=d-tabs-v1/' \
	-e 's/destination=d-copy|device|ssh|d|d|/destination=da-copy|device|ssh|da|da|/' \
	"${config}" >"${wrong_host_config}"
chmod 600 "${wrong_host_config}"
if "${repo_root}/scripts/tabs/tab-backup.sh" preflight "${wrong_host_config}" >/dev/null 2>&1; then
	echo "tab operations ran from a different source host" >&2
	exit 1
fi

printf '%s\n' \
	'age1rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr' \
	'age1ssssssssssssssssssssssssssssssssssssssssssssssssssssss' \
	>"${temporary}/d.recipients"
printf '%s\n' \
	'age1tttttttttttttttttttttttttttttttttttttttttttttttttttt' \
	'age1uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' \
	>"${temporary}/oneplus.recipients"
chmod 600 "${temporary}/d.recipients" "${temporary}/oneplus.recipients"

make_fleet_config() {
	local source_device=$1 peer=$2 recipients=$3 output=$4
	cat >"${output}" <<EOF
version=2
source_device=${source_device}
key_id=${source_device}-tabs-v1
profile=default
snapshot_store=${temporary}/snapshots-${source_device}
state_root=${temporary}/state-${source_device}
helium_tabs=${temporary}/bin/helium-tabs
exporter=${temporary}/bin/exporter
browser_export=${browser_export}
browser_export_max_age_seconds=420
browser_version=fixture
chromium_version=fixture
interval_seconds=60
age_recipients=${recipients}
age_identity=${temporary}/${source_device}.identity
destination_reserve_bytes=1
destination=nas-on-lm|nas|ssh|lm|lm|/srv/nas/helium-tab-backups
destination=${peer}-copy|device|ssh|${peer}|${peer}|${temporary}/fleet-${peer}
EOF
	chmod 600 "${output}"
}

d_config="${temporary}/d.conf"
oneplus_config="${temporary}/oneplus.conf"
make_fleet_config d da "${temporary}/d.recipients" "${d_config}"
make_fleet_config oneplus da "${temporary}/oneplus.recipients" "${oneplus_config}"
fleet_output=$("${repo_root}/scripts/tabs/tab-fleet-audit.sh" \
	"${d_config}" "${config}" "${oneplus_config}")
grep -q '^fleet_health=configuration_verified$' <<<"${fleet_output}"

reused_key_config="${temporary}/oneplus-reused-key.conf"
sed "s#age_recipients=${temporary}/oneplus.recipients#age_recipients=${temporary}/recipients.txt#" \
	"${oneplus_config}" >"${reused_key_config}"
chmod 600 "${reused_key_config}"
if "${repo_root}/scripts/tabs/tab-fleet-audit.sh" \
	"${d_config}" "${config}" "${reused_key_config}" >/dev/null 2>&1; then
	echo "fleet audit accepted a reused recovery recipient set" >&2
	exit 1
fi

cat >"${temporary}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --user ] && [ "$2" = daemon-reload ] && [ "$#" -eq 2 ]
EOF
chmod 700 "${temporary}/bin/systemctl"
installer_output=$(HOME="${temporary}/home" \
    "${repo_root}/scripts/tabs/install-linux-tab-scheduler.sh" install "${config}")
grep -q '^enabled=false$' <<<"${installer_output}"
test -x "${temporary}/home/.local/libexec/helium-tab-ops/tab-backup.sh"
test -x "${temporary}/home/.local/libexec/helium-tab-exporter"
test -f "${temporary}/home/.config/systemd/user/helium-tab-cycle.timer"
grep -q 'ExecCondition=.*tab-backup.sh preflight' \
    "${temporary}/home/.config/systemd/user/helium-tab-cycle.service"
grep -q 'unshare" -u' "${repo_root}/scripts/tabs/oneplus-tab-cycle-service.sh"
grep -q 'run_in_oneplus_uts cycle' "${repo_root}/scripts/tabs/oneplus-tab-cycle-service.sh"

printf 'tab_backup_operations=passed\ngeneration=%s\n' "${generation}"
