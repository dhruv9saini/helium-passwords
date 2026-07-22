#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/collect-artifacts.sh <linux|macos|windows> <x86_64|arm64> <platform-checkout> <output-dir>

Collect packaged Helium build outputs from a prepared platform checkout.
EOF
}

if [ "$#" -ne 4 ]; then
    usage
    exit 2
fi

platform="$1"
arch="$2"
checkout="$3"
output_dir="$4"

case "${platform}" in
    linux|macos|windows) ;;
    *)
        echo "unknown platform: ${platform}" >&2
        usage
        exit 2
        ;;
esac

case "${arch}" in
    x86_64|arm64) ;;
    *)
        echo "unsupported arch: ${arch}" >&2
        usage
        exit 2
        ;;
esac

if [ ! -d "${checkout}" ]; then
    echo "missing platform checkout: ${checkout}" >&2
    exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

shopt -s nullglob
artifacts=()
case "${platform}" in
    linux)
        artifacts+=(
            "${checkout}/build/release/"*.AppImage
            "${checkout}/build/release/"*.AppImage.zsync
            "${checkout}/build/release/"*.tar.xz
            "${checkout}/build/release/"*.tar.xz.asc
            "${checkout}/build/release/"*.deb
        )
        ;;
    macos)
        artifacts+=("${checkout}/build/"*.dmg)
        ;;
    windows)
        artifacts+=(
            "${checkout}/build/"helium*.zip
            "${checkout}/build/"helium*-installer.exe
        )
        ;;
esac
shopt -u nullglob

if [ "${#artifacts[@]}" -eq 0 ]; then
    echo "no packaged artifacts found for ${platform} ${arch} in ${checkout}" >&2
    exit 1
fi

for artifact in "${artifacts[@]}"; do
    [ -f "${artifact}" ] || continue
    cp -v "${artifact}" "${output_dir}/"
done

version="$(
    python3 "${checkout}/helium-chromium/utils/helium_version.py" \
        --tree "${checkout}/helium-chromium" \
        --platform-tree "${checkout}" \
        --print
)"

{
    printf 'version=%s\n' "${version}"
    printf 'platform=%s\n' "${platform}"
    printf 'arch=%s\n' "${arch}"
    cat "${checkout}/.helium-platform-source.env"
} > "${output_dir}/manifest.env"

printf '%s\n' "${version}" > "${output_dir}/version.txt"
