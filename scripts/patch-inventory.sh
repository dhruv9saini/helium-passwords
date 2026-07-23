#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
patches=()

while IFS= read -r patch || [ -n "${patch}" ]; do
    patch="${patch%$'\r'}"
    case "${patch}" in
        ""|\#*) continue ;;
        /*|*../*)
            echo "unsafe patch series entry: ${patch}" >&2
            exit 1
            ;;
    esac
    [ -f "${root_dir}/patches/${patch}" ] && \
        [ ! -L "${root_dir}/patches/${patch}" ] || {
        echo "invalid patch series entry: ${patch}" >&2
        exit 1
    }
    patches+=("patches/${patch}")
done <"${root_dir}/patches/series"

[ "${#patches[@]}" -gt 0 ] || {
    echo "patch series is empty" >&2
    exit 1
}
patches+=("patches/series")

(
    cd "${root_dir}"
    sha256sum "${patches[@]}"
)
