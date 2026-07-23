#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
temporary=$(mktemp -d /tmp/helium-linux-artifact-test.XXXXXX)
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT

bundle_name=helium-passwords-linux-x86_64
bundle="${temporary}/stage/${bundle_name}"
runtime="${bundle}/runtime"
provenance="${bundle}/provenance"
mkdir -p "${runtime}/locales" "${provenance}"
for file in \
    chrome_100_percent.pak chrome_200_percent.pak chromedriver \
    helium_crashpad_handler icudtl.dat libEGL.so libGLESv2.so \
    libqt5_shim.so libqt6_shim.so libvk_swiftshader.so libvulkan.so.1 \
    product_logo_256.png resources.pak v8_context_snapshot.bin \
    vk_swiftshader_icd.json xdg-mime xdg-settings; do
    printf 'synthetic %s\n' "${file}" >"${runtime}/${file}"
done
printf '#!/bin/sh\nexit 0\n' >"${runtime}/helium"
chmod 755 "${runtime}/helium"
# The synthetic wrapper must retain runtime expansion.
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec "$(dirname "$0")/helium" "$@"\n' >"${runtime}/helium-wrapper"
chmod 755 "${runtime}/helium-wrapper"
printf 'synthetic desktop entry\n' >"${runtime}/helium.desktop"
printf 'synthetic apparmor policy\n' >"${runtime}/apparmor.cfg"
printf 'synthetic locale\n' >"${runtime}/locales/en-US.pak"
ln -s helium "${runtime}/chrome"
printf 'target_cpu = "x64"\n' >"${provenance}/gn-args.txt"

source_commit=$(git -C "${repo_root}" rev-parse HEAD)
source_tree=$(git -C "${repo_root}" rev-parse 'HEAD^{tree}')
core_commit=$(git -C "${repo_root}" rev-parse HEAD:helium-chromium)
chromium_version=$(tr -d '\r\n' <"${repo_root}/helium-chromium/chromium_version.txt")
chromium_commit=$(awk -F= '$1 == "HELIUM_ANDROID_CHROMIUM_COMMIT" { print $2; exit }' \
    "${repo_root}/chromium/android-build.lock")
nix_source=$(sha256sum "${repo_root}/chromium/nix/chromiumer-shell.nix" | awk '{ print $1 }')
cat >"${provenance}/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/aaaaaaaaaaaaaaaa-synthetic
nix_derivation=/nix/store/bbbbbbbbbbbbbbbb-synthetic.drv
closure_sha256=$(printf 'a%.0s' {1..64})
closure_bytes=1
chromium_commit=${chromium_commit}
environment_source_sha256=${nix_source}
EOF
"${repo_root}/scripts/patch-inventory.sh" >"${provenance}/patches.sha256"
mapfile -t hashed_patches < <(awk '{ print $2 }' "${provenance}/patches.sha256")
mapfile -t expected_patches < <(
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' \
        -e 's#^#patches/#' "${repo_root}/patches/series"
    printf '%s\n' patches/series
)
[[ "$(printf '%s\n' "${hashed_patches[@]}")" = \
    "$(printf '%s\n' "${expected_patches[@]}")" ]]
(
    cd "${bundle}"
    find runtime -type f -print0 | sort -z | xargs -0 sha256sum >provenance/runtime.sha256
)
cat >"${provenance}/manifest.env" <<EOF
schema_version=1
product=helium-passwords
platform=linux
arch=x86_64
source_commit=${source_commit}
source_tree=${source_tree}
helium_core_commit=${core_commit}
chromium_version=${chromium_version}
chromium_commit=${chromium_commit}
platform_repository=https://github.com/imputnet/helium-linux.git
platform_commit=9fbdff55283c9275f285c49dc054a1ff38dcdc96
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
EOF
artifact="${temporary}/fixture.tar.xz"
tar -cJf "${artifact}" -C "${temporary}/stage" "${bundle_name}"
verification="${temporary}/verified"
output=$("${repo_root}/scripts/verify-linux-runtime.sh" "${artifact}" "${verification}")
grep -Fq "browser=${verification}/${bundle_name}/runtime/helium-wrapper" <<<"${output}"
grep -Fq "receipt=${verification}/artifact-receipt.env" <<<"${output}"
grep -Fqx "source_commit=${source_commit}" "${verification}/artifact-receipt.env"
grep -Fqx "schema_version=2" "${verification}/artifact-receipt.env"
grep -Fqx "browser_executable=${bundle_name}/runtime/helium-wrapper" \
    "${verification}/artifact-receipt.env"
grep -Fqx "runtime_inventory=${bundle_name}/provenance/runtime.sha256" \
    "${verification}/artifact-receipt.env"
grep -Eq '^runtime_inventory_sha256=[0-9a-f]{64}$' \
    "${verification}/artifact-receipt.env"

bad_stage="${temporary}/bad-stage"
cp -a "${temporary}/stage" "${bad_stage}"
sed -i 's/^source_commit=.*/source_commit=0000000000000000000000000000000000000000/' \
    "${bad_stage}/${bundle_name}/provenance/manifest.env"
bad_artifact="${temporary}/bad.tar.xz"
tar -cJf "${bad_artifact}" -C "${bad_stage}" "${bundle_name}"
if "${repo_root}/scripts/verify-linux-runtime.sh" "${bad_artifact}" \
    "${temporary}/bad-verified" >/dev/null 2>&1; then
    echo "wrong-source Linux artifact passed verification" >&2
    exit 1
fi

grep -q 'bash scripts/build.sh -c' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'HELIUM_REAL_NINJA=' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'scripts/chromiumer-bin' "${repo_root}/scripts/build-chromiumer-linux.sh"
if grep -q docker "${repo_root}/scripts/build-chromiumer-linux.sh"; then
  echo "Linux build driver must run directly in the enforced job cgroup" >&2
  exit 1
fi
grep -q 'nodejs_22' "${repo_root}/chromium/nix/chromiumer-shell.nix"
grep -q 'ninja' "${repo_root}/chromium/nix/chromiumer-shell.nix"
printf 'linux_runtime_artifact=passed\n'
