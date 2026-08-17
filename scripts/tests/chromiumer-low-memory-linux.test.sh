#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
prepare=${root_dir}/scripts/prepare-platform.sh
builder=${root_dir}/scripts/build-chromiumer-linux.sh
preflight=${root_dir}/scripts/create-chromiumer-linux-preflight.sh

for required in "${prepare}" "${builder}" "${preflight}"; do
    [ -f "${required}" ] && [ ! -L "${required}" ] || {
        echo "missing Chromiumer low-memory input: ${required}" >&2
        exit 1
    }
    bash -n "${required}"
done

for value in \
    'symbol_level=0' \
    'blink_symbol_level=0' \
    'v8_symbol_level=0' \
    'use_thin_lto=false' \
    'is_cfi=false'; do
    grep -Fq "${value}" "${prepare}"
    grep -Fq "${value}" "${preflight}"
done

grep -Fq 'HELIUM_CHROMIUMER_LOW_MEMORY_LINK_V1' "${prepare}"
grep -Fq 'HELIUM_LINUX_PREFLIGHT_HOOK_V1' "${prepare}"
grep -Fq 'create-chromiumer-linux-preflight.sh' "${builder}"
grep -Fq 'memory_high=4G' "${preflight}"
grep -Fq 'memory_max=5G' "${preflight}"
grep -Fq 'memory_swap_max=0' "${preflight}"
grep -Fq 'wall_seconds=28800' "${preflight}"
grep -Fq 'ninja-input-paths.txt' "${preflight}"
grep -Fq 'ninja-commands.txt' "${preflight}"
grep -Fq -- '-flto=thin|--thinlto' "${preflight}"

if "${preflight}" >/dev/null 2>&1; then
    echo "low-memory preflight accepted missing arguments" >&2
    exit 1
fi

echo "chromiumer_low_memory_linux=passed"
