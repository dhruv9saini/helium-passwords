#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: create-chromiumer-linux-preflight.sh PLATFORM-ROOT CHROMIUM-SOURCE OUT-DIR" >&2
}

[ "$#" -eq 3 ] || {
    usage
    exit 2
}

platform_root=$(realpath -e "$1")
source_root=$(realpath -e "$2")
out_dir=$(realpath -e "$3")
product_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
job=${HELIUM_FULL_GRAPH_JOB:-}
state=/home/d/.local/state/helium-builds/${job}
manifest=${state}/source.manifest
policy=${state}/policy.env
health=${state}/health.env
destination=${state}/low-memory-link-preflight
real_ninja=$(realpath -e "${HELIUM_REAL_NINJA:-$(command -v ninja)}")

exact_value() {
    local file=$1
    local key=$2
    [ -f "${file}" ] && [ ! -L "${file}" ] || return 1
    awk -F= -v key="${key}" '
        $1 == key { count++; value=substr($0,length(key)+2) }
        END { if (count == 1 && value != "") print value; else exit 1 }
    ' "${file}"
}

require_one_arg() {
    local value=$1
    [ "$(grep -Fxc "${value}" "${out_dir}/args.gn")" -eq 1 ] || {
        echo "Linux GN argument is missing or duplicated: ${value}" >&2
        exit 1
    }
}

[[ "${job}" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
    echo "invalid full-graph job identity" >&2
    exit 1
}
[ "$(uname -n | cut -d. -f1)" = chromiumer ] && [ "$(uname -m)" = x86_64 ] || {
    echo "Linux low-memory preflight requires chromiumer x86_64" >&2
    exit 1
}
grep -Eq "/helium-job-${job}\\.service(/|$)" /proc/self/cgroup || {
    echo "Linux low-memory preflight is outside its build cgroup" >&2
    exit 1
}
for required in "${manifest}" "${policy}" "${health}" \
    "${out_dir}/args.gn" "${out_dir}/build.ninja" \
    "${out_dir}/toolchain.ninja" "${source_root}/out/Default/gn" \
    "${source_root}/third_party/llvm-build/Release+Asserts/bin/clang" \
    "${source_root}/third_party/llvm-build/Release+Asserts/bin/lld"; do
    [ -f "${required}" ] && [ ! -L "${required}" ] || {
        echo "missing low-memory preflight input: ${required}" >&2
        exit 1
    }
done
[ ! -e "${destination}" ] && [ ! -L "${destination}" ] || {
    echo "Linux low-memory preflight already exists" >&2
    exit 1
}

[ "$(exact_value "${manifest}" commit)" = \
    "$(git -C "${product_root}" rev-parse HEAD)" ]
[ "$(exact_value "${manifest}" tree)" = \
    "$(git -C "${product_root}" rev-parse 'HEAD^{tree}')" ]
[ "$(exact_value "${manifest}" helium_submodule)" = \
    "$(git -C "${product_root}" rev-parse HEAD:helium-chromium)" ]
[ -z "$(git -C "${product_root}" status --porcelain --untracked-files=all)" ]

for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do
    [ "${!variable:-}" = 1 ] || {
        echo "Linux low-memory preflight requires ${variable}=1" >&2
        exit 1
    }
done
[ "$(exact_value "${policy}" profile)" = production ]
[ "$(exact_value "${policy}" host)" = chromiumer ]
[ "$(exact_value "${policy}" build_jobs)" = 1 ]
[ "$(exact_value "${policy}" source_build_jobs)" = 1 ]
[ "$(exact_value "${policy}" cpu_quota)" = 200% ]
[ "$(exact_value "${policy}" memory_high)" = 4G ]
[ "$(exact_value "${policy}" memory_max)" = 5G ]
[ "$(exact_value "${policy}" memory_swap_max)" = 0 ]
[ "$(exact_value "${policy}" tasks_max)" = 1024 ]
[ "$(exact_value "${policy}" wall_seconds)" = 28800 ]
[ "$(exact_value "${health}" status)" = ok ]

require_one_arg 'chrome_pgo_phase=0'
require_one_arg 'is_official_build=true'
require_one_arg 'symbol_level=0'
require_one_arg 'blink_symbol_level=0'
require_one_arg 'v8_symbol_level=0'
require_one_arg 'use_thin_lto=false'
require_one_arg 'is_cfi=false'
require_one_arg 'target_cpu = "x64"'
require_one_arg 'v8_target_cpu = "x64"'

temporary=$(mktemp -d "${state}/.low-memory-link-preflight.XXXXXX")
cleanup() { find "${temporary}" -depth -delete; }
trap cleanup EXIT
chmod 700 "${temporary}"

LC_ALL=C "${real_ninja}" -C "${out_dir}" -t inputs chrome chromedriver | \
    LC_ALL=C sort -u >"${temporary}/ninja-input-paths.txt"
LC_ALL=C "${real_ninja}" -C "${out_dir}" -t commands chrome chromedriver \
    >"${temporary}/ninja-commands.txt"
[ -s "${temporary}/ninja-input-paths.txt" ] && \
    [ -s "${temporary}/ninja-commands.txt" ] || {
    echo "Linux low-memory graph manifests are empty" >&2
    exit 1
}
if grep -Eq -- '(^|[[:space:]])(-flto=thin|--thinlto([^[:space:]]*)?)' \
    "${temporary}/ninja-commands.txt"; then
    echo "Linux low-memory graph still contains ThinLTO flags" >&2
    exit 1
fi

input_count=$(wc -l <"${temporary}/ninja-input-paths.txt")
command_count=$(wc -l <"${temporary}/ninja-commands.txt")
mem_total=$(awk '$1 == "MemTotal:" {print $2 * 1024}' /proc/meminfo)
mem_available=$(awk '$1 == "MemAvailable:" {print $2 * 1024}' /proc/meminfo)
root_available=$(df -B1 --output=avail / | awk 'NR == 2 {print $1}')

{
    printf 'schema=helium-chromiumer-low-memory-link-preflight-v1\n'
    printf 'job=%s\n' "${job}"
    printf 'host=chromiumer\n'
    printf 'architecture=x86_64\n'
    printf 'product_commit=%s\n' "$(git -C "${product_root}" rev-parse HEAD)"
    printf 'product_tree=%s\n' "$(git -C "${product_root}" rev-parse 'HEAD^{tree}')"
    printf 'platform_commit=%s\n' "$(git -C "${platform_root}" rev-parse HEAD)"
    printf 'chromium_commit=%s\n' "$(git -C "${source_root}" rev-parse HEAD)"
    printf 'source_manifest_sha256=%s\n' "$(sha256sum "${manifest}" | awk '{print $1}')"
    printf 'policy_sha256=%s\n' "$(sha256sum "${policy}" | awk '{print $1}')"
    printf 'health_sha256=%s\n' "$(sha256sum "${health}" | awk '{print $1}')"
    printf 'args_gn_sha256=%s\n' "$(sha256sum "${out_dir}/args.gn" | awk '{print $1}')"
    printf 'build_ninja_sha256=%s\n' "$(sha256sum "${out_dir}/build.ninja" | awk '{print $1}')"
    printf 'toolchain_ninja_sha256=%s\n' "$(sha256sum "${out_dir}/toolchain.ninja" | awk '{print $1}')"
    printf 'gn_sha256=%s\n' "$(sha256sum "${source_root}/out/Default/gn" | awk '{print $1}')"
    printf 'clang_sha256=%s\n' "$(sha256sum "${source_root}/third_party/llvm-build/Release+Asserts/bin/clang" | awk '{print $1}')"
    printf 'lld_sha256=%s\n' "$(sha256sum "${source_root}/third_party/llvm-build/Release+Asserts/bin/lld" | awk '{print $1}')"
    printf 'ninja_sha256=%s\n' "$(sha256sum "${real_ninja}" | awk '{print $1}')"
    printf 'ninja_input_count=%s\n' "${input_count}"
    printf 'ninja_input_manifest_sha256=%s\n' "$(sha256sum "${temporary}/ninja-input-paths.txt" | awk '{print $1}')"
    printf 'ninja_command_count=%s\n' "${command_count}"
    printf 'ninja_command_manifest_sha256=%s\n' "$(sha256sum "${temporary}/ninja-commands.txt" | awk '{print $1}')"
    printf 'memory_total_bytes=%s\n' "${mem_total%.*}"
    printf 'memory_available_bytes=%s\n' "${mem_available%.*}"
    printf 'root_available_bytes=%s\n' "${root_available}"
    printf 'memory_high=4G\n'
    printf 'memory_max=5G\n'
    printf 'memory_swap_max=0\n'
    printf 'build_jobs=1\n'
    printf 'cpu_quota=200%%\n'
    printf 'wall_seconds=28800\n'
    printf 'thin_lto=false\n'
    printf 'cfi=false\n'
    printf 'symbol_level=0\n'
    printf 'expected_targets=chrome,chromedriver\n'
    printf 'expected_artifact=.build/artifacts/helium-passwords-linux-x86_64.tar.xz\n'
    printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
    printf 'validation=passed\n'
} >"${temporary}/receipt.env"

chmod 400 "${temporary}/ninja-input-paths.txt" \
    "${temporary}/ninja-commands.txt" "${temporary}/receipt.env"
mv "${temporary}" "${destination}"
trap - EXIT
printf 'low_memory_preflight=%s\nreceipt_sha256=%s\n' \
    "${destination}" \
    "$(sha256sum "${destination}/receipt.env" | awk '{print $1}')"
