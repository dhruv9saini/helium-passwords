#!/usr/bin/env bash
set -euo pipefail

mode=${HELIUM_OVERLAY_MODE:-all}
if [[ $# -eq 2 && "$1" == "--desktop" ]]; then
  mode=desktop
  src=$2
elif [[ $# -eq 1 ]]; then
  src=$1
else
  echo "usage: $0 [--desktop] /path/to/chromium/src" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/chromium/overlay"

if [[ ! -d "$overlay" ]]; then
  exit 0
fi

cd "$overlay"
while IFS= read -r -d '' rel_path; do
  rel_path=${rel_path#./}
  if [[ "$mode" == desktop ]]; then
    case "$rel_path" in
      chrome/browser/password_manager/factories/password_store_backend_factory.cc|\
      components/password_manager/core/browser/password_store/BUILD.gn|\
      components/password_manager/core/browser/password_store/password_store_built_in_backend.cc|\
      components/password_manager/core/browser/password_store_factory_util.cc|\
      components/password_manager/core/browser/password_store_factory_util.h)
        continue
        ;;
    esac
  fi
  mkdir -p "$src/$(dirname "$rel_path")"
  cp -a "$overlay/$rel_path" "$src/$rel_path"
done < <(find . -type f -print0)
