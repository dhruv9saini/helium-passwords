#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ -f "$repo_root/go.mod" ]]; then
  build_config="$repo_root/helium-sync.conf"
else
  build_config="$repo_root/helium-passwords.conf"
fi
[[ -f "$build_config" ]]
# shellcheck source=/dev/null
. "$build_config"

[[ "$HELIUM_LINUX_PLATFORM_REF" == \
  9fbdff55283c9275f285c49dc054a1ff38dcdc96 ]]
[[ "$HELIUM_LINUX_PLATFORM_COMMIT" == \
  9fbdff55283c9275f285c49dc054a1ff38dcdc96 ]]
[[ "$HELIUM_LINUX_PLATFORM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$HELIUM_LINUX_CORE_COMMIT" == \
  81bb0219ad6df2adefd12f42ca79198f049f1497 ]]
[[ "$HELIUM_LINUX_DEPOT_TOOLS_COMMIT" == \
  980d6af16e06ff993a52029019dc0628c0a0e1f0 ]]
[[ "$HELIUM_MACOS_PLATFORM_REF" == \
  cea3455bbc70c8c4641110779f600e9ffea8e994 ]]
[[ "$HELIUM_MACOS_PLATFORM_COMMIT" == \
  cea3455bbc70c8c4641110779f600e9ffea8e994 ]]
[[ "$HELIUM_MACOS_CORE_COMMIT" == \
  2c97e8c5d180d5703ef0e54ed4f9768d60b952e3 ]]
[[ "$HELIUM_MACOS_DEPOT_TOOLS_COMMIT" == \
  a6626e7885df3617f2c921d5bde0a9a79599bf53 ]]
[[ "$HELIUM_WINDOWS_PLATFORM_REF" == \
  0b3809883205dd55d29f5f062afaee8490d0dea2 ]]
[[ "$HELIUM_WINDOWS_PLATFORM_COMMIT" == \
  0b3809883205dd55d29f5f062afaee8490d0dea2 ]]
[[ "$HELIUM_WINDOWS_CORE_COMMIT" == \
  81bb0219ad6df2adefd12f42ca79198f049f1497 ]]
[[ "$HELIUM_WINDOWS_DEPOT_TOOLS_COMMIT" == \
  980d6af16e06ff993a52029019dc0628c0a0e1f0 ]]
[[ -z "$HELIUM_PLATFORM_REF" ]]

prepare="$repo_root/scripts/prepare-platform.sh"
grep -Fq 'actual_platform_commit=$(git -C "${destination}" rev-parse HEAD)' \
  "$prepare"
grep -Fq 'fetch --depth 1 origin "${platform_ref}"' "$prepare"
grep -Fq 'checkout --quiet --detach FETCH_HEAD' "$prepare"
grep -Fq '[ "${actual_platform_commit}" != "${expected_platform_commit}" ]' \
  "$prepare"
grep -Fq 'actual_core_commit=$(git -C "${destination}" ls-tree HEAD helium-chromium' \
  "$prepare"
grep -Fq '[ "${actual_core_commit}" != "${expected_core_commit}" ]' \
  "$prepare"
grep -Fq "'git', 'fetch', '--depth=1', 'origin', '\${expected_depot_tools_commit}'" \
  "$prepare"
grep -Fq 'sed -i.bak' "$prepare"
grep -Fq 'rm -f -- "${clone_helper}.bak"' "$prepare"
grep -Fq "str(gcpath), 'sync', '--jobs=1', '-f', '-D', '-R', '--no-history', '--nohooks'," \
  "$prepare"
grep -Fq 'serialize-depot-tools-git-cache.patch' "$prepare"
grep -Fq "+                    code = gsutil.call('cp', '-r', latest_dir + \"/*\"," \
  "$repo_root/chromium/tooling/serialize-depot-tools-git-cache.patch"
grep -Fq -- "-                    code = gsutil.call('-m', 'cp', '-r', latest_dir + \"/*\"," \
  "$repo_root/chromium/tooling/serialize-depot-tools-git-cache.patch"
grep -Fq 'helium-passwords/android-search-engine-api-compat.patch' "$prepare"
grep -Fq 'helium-passwords/disable-android-safe-browsing-bridges.patch' "$prepare"
grep -Fq 'platform_commit=${actual_platform_commit}' "$prepare"
grep -Fq 'helium_core_commit=${actual_core_commit}' "$prepare"
grep -Fq 'depot_tools_commit=${expected_depot_tools_commit}' "$prepare"
target_check="$repo_root/scripts/ci-check-target.sh"
grep -Fq 'chromium/tools/depot_tools' "$target_check"
grep -Fq 'apply --check --ignore-whitespace' "$target_check"
grep -Fq 'cat "${checkout}/.helium-platform-source.env"' \
  "$repo_root/scripts/collect-artifacts.sh"
grep -Fq 'cat .helium-platform-source.env' \
  "$repo_root/.github/workflows/linux-build.yml"

echo 'Desktop platform immutable source contract passed'
