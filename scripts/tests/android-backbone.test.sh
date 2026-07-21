#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-backbone.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
[[ "$HELIUM_ANDROID_CHROMIUM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$HELIUM_ANDROID_CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$HELIUM_ANDROID_CORE_COMMIT" == "$(git -C "$repo_root/helium-chromium" rev-parse HEAD)" ]]
[[ "$HELIUM_ANDROID_CHROMIUM_VERSION" == "$(tr -d '\r\n' < "$repo_root/helium-chromium/chromium_version.txt")" ]]

plan="$test_root/plan.tsv"
"$repo_root/scripts/chromium/apply-android-backbone.sh" plan > "$plan"

expected_core=$(awk '
  /^[[:space:]]*($|#)/ { next }
  $0 == "helium/hop/disable-password-manager.patch" { next }
  { count++ }
  END { print count + 0 }
' "$repo_root/helium-chromium/patches/series")
expected_passwords=$(awk '/^[[:space:]]*($|#)/ { next } { count++ } END { print count + 0 }' \
  "$repo_root/patches/series")
expected_sync=$(find "$repo_root/chromium/patches" -maxdepth 1 -type f -name '*.patch' | wc -l)
[[ "$(grep -c '^core' "$plan")" -eq "$expected_core" ]]
[[ "$(grep -c '^passwords' "$plan")" -eq "$expected_passwords" ]]
[[ "$(grep -c '^sync' "$plan")" -eq "$expected_sync" ]]

grep -qx $'core\tupstream-fixes/missing-dependencies.patch' "$plan"
! grep -q 'disable-password-manager.patch' "$plan"
grep -qx $'passwords\thelium-passwords/restore-password-autofill.patch' "$plan"
grep -qx $'passwords\thelium-passwords/restore-password-ui.patch' "$plan"
grep -qx $'sync\t0001-helium-sync-overlay-files.patch' "$plan"
grep -qx $'sync\t0006-helium-sync-android-ai-overview-blocker.patch' "$plan"

last_core=$(grep -n '^core' "$plan" | tail -1 | cut -d: -f1)
first_password=$(grep -n '^passwords' "$plan" | head -1 | cut -d: -f1)
last_password=$(grep -n '^passwords' "$plan" | tail -1 | cut -d: -f1)
first_sync=$(grep -n '^sync' "$plan" | head -1 | cut -d: -f1)
[[ "$last_core" -lt "$first_password" ]]
[[ "$last_password" -lt "$first_sync" ]]

grep -Fq 'prune_binaries.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"
grep -Fq 'domain_substitution.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"
grep -Fq 'name_substitution.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"
grep -Fq 'i18n_apply.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"
grep -Fq 'helium_version.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"
grep -Fq 'replace_resources.py' "$repo_root/scripts/chromium/apply-android-backbone.sh"

if GITHUB_WORKSPACE="$test_root" HELIUM_SYNC_REPO="$repo_root" CHROMIUM_REF=main \
  "$repo_root/scripts/chromium/build-android-ci.sh" >"$test_root/moving.out" 2>&1; then
  echo 'moving Chromium ref unexpectedly passed' >&2
  exit 1
fi
grep -q 'CHROMIUM_REF must be the immutable commit' "$test_root/moving.out"

! grep -q 'chromium_ref=${CHROMIUM_REF:-main}' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
! grep -q 'default: main' "$repo_root/.github/workflows/chromium-android.yml"
grep -q 'submodules: recursive' "$repo_root/.github/workflows/chromium-android.yml"
! grep -q '3fdd848305cc4c7a7cf1775e295b2d31054d19d3' \
  "$repo_root/scripts/chromium/dispatch-cached-remote-builds.sh"
grep -Fq 'apply-android-backbone.sh" apply' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'helium-chromium/flags.gn' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'gn gen "$out_dir" --fail-on-unused-args' \
  "$repo_root/scripts/chromium/build-android-ci.sh"

echo 'Android shared-backbone composition contract passed'
