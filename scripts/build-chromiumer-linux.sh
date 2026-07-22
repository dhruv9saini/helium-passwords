#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: scripts/build-chromiumer-linux.sh x86_64" >&2
}

[ "$#" -eq 1 ] && [ "$1" = x86_64 ] || {
    usage
    exit 2
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
checkout="${root_dir}/build/platforms/linux"
artifact="${root_dir}/.build/artifacts/helium-passwords-linux-x86_64.tar.xz"

[ "$(uname -n | cut -d. -f1)" = chromiumer ] || {
    echo "Linux Chromium builds run only on chromiumer" >&2
    exit 1
}
[ "${HELIUM_BUILD_JOBS:-}" = 2 ] || {
    echo "Linux Chromium build requires the isolated two-job policy" >&2
    exit 1
}
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
[ ! -e "${artifact}" ] || {
    echo "refusing to replace existing artifact: ${artifact}" >&2
    exit 1
}
[ -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ] || {
    echo "public source must be clean before a provenance-bound build" >&2
    exit 1
}

"${root_dir}/scripts/prepare-platform.sh" linux "${checkout}" >/dev/null
(
    cd "${checkout}"
    env -u CI ARCH=x86_64 HELIUM_BUILD_JOBS=2 bash scripts/build.sh -c
)
"${root_dir}/scripts/package-linux-runtime.sh" x86_64 "${checkout}" "${artifact}"

printf 'linux_artifact=%s\n' "${artifact#"${root_dir}"/}"
