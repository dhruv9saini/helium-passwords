#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/chromium/src" >&2
  exit 2
fi

src=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

for patch in "$repo_root"/chromium/patches/*.patch; do
  [[ -e "$patch" ]] || continue
  git -C "$src" apply --check "$patch"
  git -C "$src" apply "$patch"
done

"$repo_root/scripts/chromium/copy-overlay.sh" "$src"
