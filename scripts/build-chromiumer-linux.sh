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
full_graph="${root_dir}/.build/artifacts/${product}-linux-${arch}.full-graph"
graph_boundary="/home/d/.local/state/helium-builds/${build_job_id}/full-graph-boundary.env"
linux_phase=${HELIUM_LINUX_PHASE:-fresh}

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
[ -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ] || {
    echo "Helium source must be clean before a provenance-bound build" >&2
    exit 1
}
[ "${linux_phase}" = fresh ] || [ "${linux_phase}" = retained ] || {
    echo "HELIUM_LINUX_PHASE must be fresh or retained" >&2
    exit 2
}
[ ! -e "${artifact}" ] && [ ! -e "${receipt}" ] && \
    [ ! -e "${full_graph}" ] || {
    echo "refusing to replace existing Linux artifact, receipt, or full-graph evidence" >&2
    exit 1
}
mkdir -p "$(dirname "${artifact}")"

if [ "${linux_phase}" = fresh ]; then
    [ ! -e "${graph_boundary}" ] && [ ! -L "${graph_boundary}" ] || {
        echo "fresh Linux build refuses an existing graph boundary" >&2
        exit 1
    }
    "${root_dir}/scripts/prepare-platform.sh" linux "${checkout}" >/dev/null
    graph_boundary_epoch=$(date +%s)
    (
        cd "${checkout}"
        env -u CI ARCH="${arch}" HELIUM_BUILD_JOBS=1 \
            HELIUM_REAL_NINJA="${real_ninja}" \
            HELIUM_FULL_GRAPH_JOB="${build_job_id}" \
            HELIUM_FULL_GRAPH_BOUNDARY_EPOCH="${graph_boundary_epoch}" \
            HELIUM_FULL_GRAPH_SOURCE_ROOT="${checkout}/build/src" \
            HELIUM_FULL_GRAPH_RECEIPT="${graph_boundary}" \
            HELIUM_FULL_GRAPH_AUDIT_TOOL="${root_dir}/scripts/linux-full-graph-audit.mjs" \
            PATH="${ninja_shim_dir}:${PATH}" \
            bash scripts/build.sh -c
    )
else
    [ -f "${graph_boundary}" ] && [ ! -L "${graph_boundary}" ] && \
        [ "$(stat -c %a "${graph_boundary}")" = 400 ] || {
        echo "retained Linux build requires its immutable graph boundary" >&2
        exit 1
    }
    boundary_value() {
        awk -F= -v key="$1" \
            '$1 == key { count++; value=substr($0,length(key)+2) }
             END { if (count == 1 && value != "") print value; else exit 1 }' \
            "${graph_boundary}"
    }
    out="${checkout}/build/src/out/Default"
    source_root="${checkout}/build/src"
    gni="${source_root}/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni"
    generator="${source_root}/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js"
    ai_skills="${source_root}/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs"
    expected_chromium_commit=$("${root_dir}/scripts/linux-product-provenance.sh" \
        "${product}" "${arch}" "${target}" | \
        awk -F= '$1 == "chromium_commit" { print $2; exit }')
    [ "$(boundary_value schema)" = helium-fresh-full-graph-boundary-v1 ] && \
        [ "$(boundary_value job)" = "${build_job_id}" ] && \
        [ "$(boundary_value source_root)" = "${source_root}" ] && \
        [ "$(boundary_value node_version)" = v22.14.0 ] && \
        [ "$(node --version)" = v22.14.0 ] && \
        [ "$(boundary_value full_targets)" = chrome,chromedriver ] && \
        [ "$(boundary_value graph_validation)" = passed ] && \
        [ "$(git -C "${source_root}" rev-parse HEAD)" = \
            "${expected_chromium_commit}" ] && \
        [ "$(sha256sum "${out}/build.ninja" | awk '{print $1}')" = \
            "$(boundary_value build_ninja_sha256)" ] && \
        [ "$(sha256sum "${out}/toolchain.ninja" | awk '{print $1}')" = \
            "$(boundary_value toolchain_ninja_sha256)" ] && \
        [ "$(sha256sum "${gni}" | awk '{print $1}')" = \
            "$(boundary_value generate_css_gni_sha256)" ] && \
        [ "$(sha256sum "${generator}" | awk '{print $1}')" = \
            "$(boundary_value generate_css_js_sha256)" ] && \
        [ "$(sha256sum "${ai_skills}" | awk '{print $1}')" = \
            "$(boundary_value build_ai_skills_sha256)" ] || {
        echo "retained Linux build graph no longer matches its boundary" >&2
        exit 1
    }
    "${real_ninja}" -j 1 -C "${out}" chrome chromedriver
fi

HELIUM_BUILD_OPERATOR="${root_dir}/scripts/build-chromiumer-linux.sh" \
HELIUM_NINJA_SHIM="${ninja_shim_dir}/ninja" \
HELIUM_REAL_NINJA="${real_ninja}" \
    "${root_dir}/scripts/capture-linux-full-graph-evidence.sh" \
        "${product}" "${arch}" "${target}" "${build_job_id}" \
        "${checkout}" "${graph_boundary}" "${full_graph}"
"${root_dir}/scripts/package-linux-runtime.sh" \
    "${product}" "${arch}" "${target}" "${build_job_id}" \
    "${checkout}" "${full_graph}" "${artifact}" "${receipt}"

printf 'linux_artifact=%s\nlinux_receipt=%s\nlinux_full_graph=%s\n' \
    "${artifact#"${root_dir}"/}" "${receipt#"${root_dir}"/}" \
    "${full_graph#"${root_dir}"/}"
