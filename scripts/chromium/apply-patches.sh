#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/chromium/src" >&2
  exit 2
fi

src=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

apply_patch_file() {
  local patch=$1
  local patch_to_apply=$patch
  local temp_patch=

  if [[ "$(basename "$patch")" == "0001-helium-sync-overlay-files.patch" ]]; then
    temp_patch=$(mktemp)
    "$repo_root/scripts/chromium/filter-overlay-patch.sh" "$patch" >"$temp_patch"
    patch_to_apply=$temp_patch
  fi

  git -C "$src" apply --check "$patch_to_apply"
  git -C "$src" apply "$patch_to_apply"

  if [[ -n "$temp_patch" ]]; then
    rm -f "$temp_patch"
  fi
}

for patch in "$repo_root"/chromium/patches/*.patch; do
  [[ -e "$patch" ]] || continue
  apply_patch_file "$patch"
done

"$repo_root/scripts/chromium/copy-overlay.sh" "$src"
