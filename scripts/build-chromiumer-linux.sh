#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: scripts/build-chromiumer-linux.sh PRODUCT ARCH TARGET BUILD-JOB-ID" >&2
}

[ "$#" -eq 4 ] || {
    usage
    exit 2
}

product=$1
arch=$2
target=$3
build_job_id=$4
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
checkout="${root_dir}/build/platforms/linux"
artifact="${root_dir}/.build/artifacts/${product}-linux-${arch}.tar.xz"
receipt="${root_dir}/.build/artifacts/${product}-linux-${arch}.receipt.env"

"${root_dir}/scripts/linux-product-provenance.sh" \
    "${product}" "${arch}" "${target}" >/dev/null
[[ "${build_job_id}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || {
    echo "invalid build job id" >&2
    exit 2
}

[ "$(uname -n | cut -d. -f1)" = chromiumer ] || {
    echo "Linux Chromium builds run only on chromiumer" >&2
    exit 1
}
for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do
    [ "${!variable:-}" = 1 ] || {
        echo "Linux Chromium build requires ${variable}=1" >&2
        exit 1
    }
done
grep -Eq '/helium-job-[a-z0-9-]+\.service(/|$)' /proc/self/cgroup || {
    echo "Linux Chromium build is outside an isolated Helium cgroup" >&2
    exit 1
}
case "${TMPDIR:-}" in
    "${HOME}/helium-builds/work/"*/tmp) ;;
    *) echo "Linux Chromium build TMPDIR is outside its job workspace" >&2; exit 1 ;;
esac
for tool in git node ninja python3; do
    command -v "${tool}" >/dev/null || {
        echo "pinned Linux build environment is missing ${tool}" >&2
        exit 1
    }
done
real_ninja=$(realpath -e "$(command -v ninja)")
ninja_shim_dir="${root_dir}/scripts/chromiumer-bin"
[ -x "${ninja_shim_dir}/ninja" ] || {
    echo "bounded Chromiumer Ninja shim is missing" >&2
    exit 1
}
[ "${real_ninja}" != "$(realpath -e "${ninja_shim_dir}/ninja")" ] || {
    echo "real Ninja resolved to the Chromiumer shim" >&2
    exit 1
}
[ ! -e "${artifact}" ] && [ ! -e "${receipt}" ] || {
    echo "refusing to replace existing Linux artifact or receipt" >&2
    exit 1
}
[ -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ] || {
    echo "Helium source must be clean before a provenance-bound build" >&2
    exit 1
}

"${root_dir}/scripts/prepare-platform.sh" linux "${checkout}" >/dev/null
(
    cd "${checkout}"
    env -u CI ARCH="${arch}" HELIUM_BUILD_JOBS=1 \
        HELIUM_REAL_NINJA="${real_ninja}" \
        PATH="${ninja_shim_dir}:${PATH}" \
        bash scripts/build.sh -c
)
"${root_dir}/scripts/package-linux-runtime.sh" \
    "${product}" "${arch}" "${target}" "${build_job_id}" \
    "${checkout}" "${artifact}" "${receipt}"

printf 'linux_artifact=%s\nlinux_receipt=%s\n' \
    "${artifact#"${root_dir}"/}" "${receipt#"${root_dir}"/}"
