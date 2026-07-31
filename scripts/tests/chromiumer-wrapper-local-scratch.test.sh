#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
wrapper="${repo_root}/scripts/chromiumer-job.sh"

grep -Fqx \
    'notification_runtime_dir="/run/user/$(id -u)"' \
    "${wrapper}"
grep -Fqx \
    'local_source_staging=/home/d/.local/state/helium-builds/source-staging' \
    "${wrapper}"
grep -Fq \
    '"${notification_runtime_dir}/helium-notification.XXXXXX"' \
    "${wrapper}"
grep -Fq \
    '"${local_source_staging}/helium-source.XXXXXX"' \
    "${wrapper}"
if rg -n 'mktemp -d /tmp/helium-(notification|source)' "${wrapper}" >&2; then
    echo 'Chromiumer wrapper still stages Helium data in quota-bound /tmp' >&2
    exit 1
fi

printf 'chromiumer_wrapper_local_scratch=passed\n'
