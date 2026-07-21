#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../chromiumer-worker.sh
source "${root_dir}/scripts/chromiumer-worker.sh"

gib_bytes=$((1024 * 1024 * 1024))
budget_bytes=$((80 * gib_bytes))

[ "${root_floor_bytes}" -eq "$((2 * gib_bytes))" ]
[ "$(required_build_available_bytes \
    "${budget_bytes}" 0 yes)" -eq "$((82 * gib_bytes))" ]
[ "$(required_build_available_bytes \
    "${budget_bytes}" "$((10 * gib_bytes))" yes)" \
    -eq "$((72 * gib_bytes))" ]
[ "$(required_build_available_bytes \
    "${budget_bytes}" "${budget_bytes}" yes)" \
    -eq "$((2 * gib_bytes))" ]

[ "$(required_build_available_bytes \
    "${budget_bytes}" 0 no)" -eq "$((80 * gib_bytes))" ]
[ "$(required_build_available_bytes \
    "${budget_bytes}" "$((10 * gib_bytes))" no)" \
    -eq "$((70 * gib_bytes))" ]
[ "$(required_build_available_bytes \
    "${budget_bytes}" "${budget_bytes}" no)" -eq 0 ]

if required_build_available_bytes \
    "${budget_bytes}" "$((budget_bytes + 1))" yes >/dev/null; then
    echo "over-limit workspace unexpectedly passed capacity arithmetic" >&2
    exit 1
fi

echo "chromiumer capacity arithmetic passed"
