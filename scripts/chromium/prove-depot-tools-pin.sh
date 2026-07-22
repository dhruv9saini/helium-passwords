#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo "usage: prove-depot-tools-pin.sh OUTPUT_DIR" >&2
  exit 64
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
output_dir=$(realpath -m "$1")
if [[ -e "$output_dir" && -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
  echo "depot_tools proof output directory is not empty: $output_dir" >&2
  exit 1
fi
mkdir -p "$output_dir"

depot_tools=$output_dir/depot_tools
depot_tools_url=https://chromium.googlesource.com/chromium/tools/depot_tools.git
mkdir "$depot_tools"
git -C "$depot_tools" init
git -C "$depot_tools" remote add origin "$depot_tools_url"
git -C "$depot_tools" fetch --depth=1 origin \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT"
git -C "$depot_tools" checkout --detach \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT"

verify="$repo_root/scripts/chromium/verify-depot-tools-cache-contract.sh"
"$verify" "$depot_tools" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" >/dev/null
head_before=$(git -C "$depot_tools" rev-parse HEAD)

version_output=$(mktemp "$output_dir/.gclient-version.XXXXXX")
cleanup() {
  [[ ! -e "$version_output" ]] || find "$version_output" -delete
}
trap cleanup EXIT
export DEPOT_TOOLS_UPDATE=0
"$depot_tools/gclient" --version >"$version_output"

"$verify" "$depot_tools" "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" >/dev/null
head_after=$(git -C "$depot_tools" rev-parse HEAD)
[[ "$head_after" == "$head_before" ]] || {
  echo "gclient launcher moved the pinned depot_tools checkout" >&2
  exit 1
}

proof=$output_dir/depot-tools-pin-proof.env
proof_temp=$proof.tmp
{
  printf 'schema_version=1\n'
  printf 'depot_tools_origin=%s\n' "$depot_tools_url"
  printf 'depot_tools_commit=%s\n' "$head_after"
  printf 'depot_tools_update_policy=DEPOT_TOOLS_UPDATE=0\n'
  printf 'gclient_version_sha256=%s\n' \
    "$(sha256sum "$version_output" | cut -d' ' -f1)"
  printf 'verified_at=%s\n' "$(date --iso-8601=seconds)"
} >"$proof_temp"
mv "$proof_temp" "$proof"
find "$version_output" -delete
trap - EXIT

printf 'depot_tools_pin_proof=passed\n'
printf 'depot_tools_commit=%s\n' "$head_after"
printf 'proof=%s\n' "$proof"
