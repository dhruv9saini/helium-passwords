#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 SERIES_FILE PATCH_ROOT SOURCE_TREE" >&2
  exit 64
fi

series_file=$(realpath "$1")
patch_root=$(realpath "$2")
source_tree=$(realpath "$3")

[[ -f "$series_file" ]] || { echo "missing patch series: $series_file" >&2; exit 1; }
[[ -d "$source_tree/.git" ]] || { echo "not a Git checkout: $source_tree" >&2; exit 1; }

while IFS= read -r entry || [[ -n "$entry" ]]; do
  entry=${entry%$'\r'}
  case "$entry" in
    ""|\#*) continue ;;
    /*|*../*)
      echo "unsafe patch series entry: $entry" >&2
      exit 1
      ;;
  esac
  patch_file="$patch_root/$entry"
  [[ -f "$patch_file" && ! -L "$patch_file" ]] || {
    echo "missing regular patch: $patch_file" >&2
    exit 1
  }
  printf 'Applying Git patch: %s\n' "$entry"
  git -C "$source_tree" apply --check "$patch_file"
  git -C "$source_tree" apply "$patch_file"
done < "$series_file"
