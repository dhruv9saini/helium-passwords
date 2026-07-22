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

cat >"${temporary}/bin/exporter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --output ] && [ "$#" -eq 2 ]
cat >"$2" <<'JSON'
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
EOF

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
install -m 600 "${source_file}" "${destination_file}"
EOF
chmod 700 "${temporary}/bin/exporter" "${temporary}/bin/age" \
    "${temporary}/bin/ssh" "${temporary}/bin/rsync"
printf '%s\n' \
    'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' \
    'age1pppppppppppppppppppppppppppppppppppppppppppppppppppp' \
    >"${temporary}/recipients.txt"
printf 'AGE-SECRET-KEY-SYNTHETIC\n' >"${temporary}/identity.txt"
chmod 600 "${temporary}/recipients.txt" "${temporary}/identity.txt"

local_host=$(uname -n | cut -d. -f1)
config="${temporary}/tab-ops.conf"
cat >"${config}" <<EOF
version=1
source_device=fixture-source
profile=default
snapshot_store=${temporary}/snapshots
state_root=${temporary}/state
helium_tabs=${temporary}/bin/helium-tabs
exporter=${temporary}/bin/exporter
browser_version=fixture
chromium_version=fixture
interval_seconds=60
age_recipients=${temporary}/recipients.txt
age_identity=${temporary}/identity.txt
destination_reserve_bytes=1
destination=lm-copy|local|${local_host}|-|${temporary}/destination-lm
destination=backup-two|ssh|backup-two|backup-two|${temporary}/destination-two
EOF
chmod 600 "${config}"
export PATH="${temporary}/bin:${PATH}"

cycle_output=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" cycle "${config}")
generation=$(awk -F= '$1 == "generation" { print $2; exit }' <<<"${cycle_output}")
[[ "${generation}" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]]
scheduler_status=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" status "${config}")
grep -q '^state=healthy$' <<<"${scheduler_status}"

grep -q '^status=healthy$' <<<"${cycle_output}"
for destination_root in "${temporary}/destination-lm" "${temporary}/destination-two"; do
    test -f "${destination_root}/fixture-source/default/generations/${generation}.tar.age"
    test -f "${destination_root}/fixture-source/default/generations/${generation}.backup.env"
done

first_generation=${generation}
cycle_output=$("${repo_root}/scripts/tabs/tab-snapshot-scheduler.sh" cycle "${config}")
generation=$(awk -F= '$1 == "generation" { print $2; exit }' <<<"${cycle_output}")
[ "${generation}" != "${first_generation}" ]
test ! -e "${temporary}/snapshots/generations/${first_generation}"
test ! -e "${temporary}/state/fixture-source/default/encrypted/${first_generation}.tar.age"
for destination_root in "${temporary}/destination-lm" "${temporary}/destination-two"; do
    test ! -e "${destination_root}/fixture-source/default/generations/${first_generation}.tar.age"
    find "${destination_root}/fixture-source/default/quarantine" \
        -name "*-${first_generation}-retention.tar.age" -print -quit | grep -q .
    test -f "${destination_root}/fixture-source/default/generations/${generation}.tar.age"
done

restore_directory="${temporary}/disposable-restore"
"${repo_root}/scripts/tabs/tab-backup.sh" restore-to-disposable "${config}" \
    backup-two "${generation}" "${restore_directory}" >/dev/null
test -f "${restore_directory}/session.json"
test -f "${restore_directory}/restore-manifest.json"
grep -q 'fixture.invalid' "${restore_directory}/session.json"

printf 'corrupt\n' >"${temporary}/destination-two/fixture-source/default/generations/${generation}.tar.age"
if "${repo_root}/scripts/tabs/tab-backup.sh" status "${config}" "${generation}" >/dev/null 2>&1; then
    echo "corrupt destination unexpectedly reported healthy" >&2
    exit 1
fi
"${repo_root}/scripts/tabs/tab-backup.sh" quarantine "${config}" \
    backup-two "${generation}" synthetic-corruption >/dev/null
"${repo_root}/scripts/tabs/tab-backup.sh" backup "${config}" "${generation}" >/dev/null
backup_status=$("${repo_root}/scripts/tabs/tab-backup.sh" status "${config}" "${generation}")
grep -q '^status=healthy$' <<<"${backup_status}"
find "${temporary}/destination-two/fixture-source/default/quarantine" \
    -name "*-${generation}-synthetic-corruption.tar.age" -print -quit | grep -q .

plan="${temporary}/retention.plan"
"${repo_root}/scripts/tabs/tab-backup.sh" retention-plan "${config}" "${plan}" >/dev/null
grep -q '^schema_version=1$' "${plan}"
grep -q '^source_device=fixture-source$' "${plan}"

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
sed "s/source_device=fixture-source/source_device=${local_host}/" "${config}" >"${bad_config}"
chmod 600 "${bad_config}"
if "${repo_root}/scripts/tabs/tab-backup.sh" status "${bad_config}" "${generation}" >/dev/null 2>&1; then
    echo "source-local destination was not rejected" >&2
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
test -f "${temporary}/home/.config/systemd/user/helium-tab-cycle.timer"
grep -q 'ExecCondition=.*tab-backup.sh preflight' \
    "${temporary}/home/.config/systemd/user/helium-tab-cycle.service"
grep -q 'chroot.*scheduler.*cycle' "${repo_root}/scripts/tabs/oneplus-tab-cycle-service.sh"

printf 'tab_backup_operations=passed\ngeneration=%s\n' "${generation}"
