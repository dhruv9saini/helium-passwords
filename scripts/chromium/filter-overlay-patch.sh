#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/patch" >&2
  exit 2
fi

patch=$1

awk '
function clean_path(path) {
  sub(/^[ab]\//, "", path)
  return path
}
BEGIN {
  skip_path["chrome/browser/password_manager/factories/password_store_backend_factory.cc"] = 1
  skip_path["components/password_manager/core/browser/password_store/BUILD.gn"] = 1
  skip_path["components/password_manager/core/browser/password_store/password_store_built_in_backend.cc"] = 1
  skip_path["components/password_manager/core/browser/password_store_factory_util.cc"] = 1
  skip_path["components/password_manager/core/browser/password_store_factory_util.h"] = 1
}
/^diff --git / {
  from_path = clean_path($3)
  to_path = clean_path($4)
  skip = ((from_path in skip_path) || (to_path in skip_path))
}
!skip { print }
' "$patch"
