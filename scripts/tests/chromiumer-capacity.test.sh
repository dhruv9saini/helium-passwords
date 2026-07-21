#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../chromiumer-worker.sh
source "${root_dir}/scripts/chromiumer-worker.sh"

profile production
gib_bytes=$((1024 * 1024 * 1024))

[ "${workspace_limit_bytes}" -eq "$((100 * gib_bytes))" ]
[ "${filesystem_reserve_bytes}" -eq "$((20 * gib_bytes))" ]
[ "$(required_available_bytes \
    "${workspace_limit_bytes}" 0 "${filesystem_reserve_bytes}")" \
    -eq "$((120 * gib_bytes))" ]
[ "$(required_available_bytes \
    "${workspace_limit_bytes}" "$((10 * gib_bytes))" \
    "${filesystem_reserve_bytes}")" -eq "$((110 * gib_bytes))" ]
[ "$(required_available_bytes \
    "${workspace_limit_bytes}" "${workspace_limit_bytes}" \
    "${filesystem_reserve_bytes}")" -eq "$((20 * gib_bytes))" ]

if required_available_bytes \
    "${workspace_limit_bytes}" "$((workspace_limit_bytes + 1))" \
    "${filesystem_reserve_bytes}" >/dev/null; then
    echo "over-limit workspace unexpectedly passed capacity arithmetic" >&2
    exit 1
fi

echo "chromiumer capacity arithmetic passed"
