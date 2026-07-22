#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: scripts/package-linux-runtime.sh x86_64 PLATFORM_CHECKOUT OUTPUT.tar.xz" >&2
}

[ "$#" -eq 3 ] && [ "$1" = x86_64 ] || {
    usage
    exit 2
}

arch=$1
checkout=$(realpath -e "$2")
output=$3
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
output_parent=$(realpath -m "$(dirname "${output}")")
output="${output_parent}/$(basename "${output}")"
bundle_name="helium-passwords-linux-${arch}"
source_dir="${checkout}/build/src"
out_dir="${source_dir}/out/Default"

[[ "$(basename "${output}")" = *.tar.xz ]] || {
    echo "output must end in .tar.xz" >&2
    exit 2
}
[ ! -e "${output}" ] || {
    echo "refusing to replace existing artifact: ${output}" >&2
    exit 1
}
for path in "${checkout}/.helium-platform-source.env" "${out_dir}/args.gn" \
    "${out_dir}/helium" "${source_dir}/.git"; do
    [ -e "${path}" ] || {
        echo "missing completed Linux build input: ${path}" >&2
        exit 1
    }
done
[ -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ] || {
    echo "public source must be clean before packaging" >&2
    exit 1
}

source_commit=$(git -C "${root_dir}" rev-parse HEAD)
source_tree=$(git -C "${root_dir}" rev-parse 'HEAD^{tree}')
core_commit=$(git -C "${root_dir}" rev-parse HEAD:helium-chromium)
[ "$(git -C "${root_dir}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "public Helium checkout does not match its committed gitlink" >&2
    exit 1
}
[ "$(git -C "${checkout}/helium-chromium" rev-parse HEAD)" = "${core_commit}" ] || {
    echo "prepared Linux checkout uses the wrong Helium core" >&2
    exit 1
}

build_config="${root_dir}/helium-passwords.conf"
[ ! -f "${root_dir}/go.mod" ] || build_config="${root_dir}/helium-sync.conf"
# shellcheck source=/dev/null
. "${build_config}"
platform_commit=$(git -C "${checkout}" rev-parse HEAD)
[ "${platform_commit}" = "${HELIUM_LINUX_PLATFORM_COMMIT}" ] || {
    echo "prepared Linux checkout uses the wrong platform commit" >&2
    exit 1
}
chromium_version=$(tr -d '\r\n' <"${root_dir}/helium-chromium/chromium_version.txt")
chromium_commit=$(awk -F= '$1 == "HELIUM_ANDROID_CHROMIUM_COMMIT" { print $2; exit }' \
    "${root_dir}/chromium/android-build.lock")
[ "$(git -C "${source_dir}" rev-parse HEAD)" = "${chromium_commit}" ] || {
    echo "built Chromium source does not match the locked commit" >&2
    exit 1
}
grep -Fqx 'target_cpu = "x64"' "${out_dir}/args.gn" || {
    echo "Linux GN args do not identify x86_64" >&2
    exit 1
}

mkdir -p "${output_parent}"
temporary=$(mktemp -d "${output_parent}/.helium-linux-package.XXXXXX")
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT
bundle="${temporary}/${bundle_name}"
runtime="${bundle}/runtime"
provenance="${bundle}/provenance"
mkdir -p "${runtime}" "${provenance}"

runtime_entries=(
    helium
    chrome_100_percent.pak
    chrome_200_percent.pak
    helium_crashpad_handler
    chromedriver
    icudtl.dat
    libEGL.so
    libGLESv2.so
    libqt5_shim.so
    libqt6_shim.so
    libvk_swiftshader.so
    libvulkan.so.1
    locales
    product_logo_256.png
    resources.pak
    v8_context_snapshot.bin
    vk_swiftshader_icd.json
    xdg-mime
    xdg-settings
)
for entry in "${runtime_entries[@]}"; do
    [ -e "${out_dir}/${entry}" ] || {
        echo "built Linux runtime is missing ${entry}" >&2
        exit 1
    }
    cp -a "${out_dir}/${entry}" "${runtime}/"
done
cp -a "${checkout}/package/helium.desktop" "${runtime}/"
cp -a "${checkout}/package/apparmor.cfg" "${runtime}/"
cp -a "${checkout}/package/helium-wrapper.sh" "${runtime}/helium-wrapper"
ln -s helium "${runtime}/chrome"
[ -x "${runtime}/helium" ] && [ -x "${runtime}/helium-wrapper" ] || {
    echo "packaged Helium browser or wrapper is not executable" >&2
    exit 1
}

cp "${out_dir}/args.gn" "${provenance}/gn-args.txt"
"${root_dir}/scripts/chromiumer-nix.sh" provenance >"${provenance}/chromiumer-nix.env"
(
    cd "${root_dir}"
    sha256sum patches/helium-passwords/restore-password-autofill.patch \
        patches/helium-passwords/restore-password-ui.patch \
        patches/series >"${provenance}/patches.sha256"
)
(
    cd "${bundle}"
    find runtime -type f -print0 | sort -z | xargs -0 sha256sum >provenance/runtime.sha256
)
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
cat >"${provenance}/manifest.env" <<EOF
schema_version=1
product=helium-passwords
platform=linux
arch=${arch}
source_commit=${source_commit}
source_tree=${source_tree}
helium_core_commit=${core_commit}
chromium_version=${chromium_version}
chromium_commit=${chromium_commit}
platform_repository=${HELIUM_LINUX_REPO}
platform_commit=${platform_commit}
gn_args_sha256=${gn_args_sha256}
nix_provenance_sha256=${nix_provenance_sha256}
patch_inventory_sha256=${patch_inventory_sha256}
runtime_inventory_sha256=${runtime_inventory_sha256}
EOF

archive="${temporary}/$(basename "${output}")"
tar --create --xz --file="${archive}" --directory="${temporary}" "${bundle_name}"
mv --no-clobber "${archive}" "${output}"
[ -f "${output}" ] || {
    echo "failed to publish Linux artifact" >&2
    exit 1
}
printf 'artifact=%s\nsha256=%s\n' "${output}" "$(sha256sum "${output}" | awk '{ print $1 }')"
