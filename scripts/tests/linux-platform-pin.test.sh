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

[[ "$HELIUM_LINUX_PLATFORM_REF" == 0.12.4.1 ]]
[[ "$HELIUM_LINUX_PLATFORM_COMMIT" == \
  105d2f4d32f863094eaa27789e82ddc3e42f7106 ]]
[[ "$HELIUM_LINUX_PLATFORM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ -z "$HELIUM_PLATFORM_REF" ]]

prepare="$repo_root/scripts/prepare-platform.sh"
grep -Fq 'actual_platform_commit=$(git -C "${destination}" rev-parse HEAD)' \
  "$prepare"
grep -Fq '[ "${actual_platform_commit}" != "${expected_platform_commit}" ]' \
  "$prepare"
grep -Fq 'platform_commit=${actual_platform_commit}' "$prepare"
grep -Fq 'cat "${checkout}/.helium-platform-source.env"' \
  "$repo_root/scripts/collect-artifacts.sh"
grep -Fq 'cat .helium-platform-source.env' \
  "$repo_root/.github/workflows/linux-build.yml"

echo 'Linux platform immutable commit contract passed'
