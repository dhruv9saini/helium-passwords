#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/helium-linux /path/to/helium-sync" >&2
  exit 2
fi

linux_repo=$1
sync_repo=$2
target_dir="$linux_repo/patches/helium-sync"

mkdir -p "$target_dir"

for patch in "$sync_repo"/chromium/patches/*.patch; do
  [[ -e "$patch" ]] || continue
  name=$(basename "$patch")
  cp "$patch" "$target_dir/$name"
  series_entry="helium-sync/$name"
  if ! grep -qxF "$series_entry" "$linux_repo/patches/series"; then
    printf '%s\n' "$series_entry" >> "$linux_repo/patches/series"
  fi
done
