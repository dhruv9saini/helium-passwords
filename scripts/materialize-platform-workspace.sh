#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/materialize-platform-workspace.sh <linux|macos|windows>

Replace the GitHub Actions workspace with a prepared platform checkout.
This is intentionally CI-only because it deletes workspace files.
EOF
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

if [ "${GITHUB_ACTIONS:-}" != "true" ] || [ -z "${GITHUB_WORKSPACE:-}" ]; then
    echo "refusing to replace a workspace outside GitHub Actions" >&2
    exit 2
fi

platform="$1"
case "${platform}" in
    linux|macos|windows) ;;
    *)
        echo "unknown platform: ${platform}" >&2
        usage
        exit 2
        ;;
esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
platform_parent="${RUNNER_TEMP:-/tmp}/helium-passwords-platform"
platform_checkout="${platform_parent}/${platform}"

rm -rf "${platform_parent}"
mkdir -p "${platform_parent}"

"${root_dir}/scripts/prepare-platform.sh" "${platform}" "${platform_checkout}" >/dev/null

if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='/.git' "${platform_checkout}/" "${GITHUB_WORKSPACE}/"
else
    find "${GITHUB_WORKSPACE}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    (
        cd "${platform_checkout}"
        tar --exclude='./.git' -cf - .
    ) | (
        cd "${GITHUB_WORKSPACE}"
        tar -xf -
    )
fi
