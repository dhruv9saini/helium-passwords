#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/chromium/src" >&2
  exit 2
fi

src=$1
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/chromium/overlay"

if [[ ! -d "$overlay" ]]; then
  exit 0
fi

cp -a "$overlay"/. "$src"/
