#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay=$repo_root/chromium/overlay
patch=$repo_root/chromium/patches/0001-helium-sync-overlay-files.patch
mode=${1:-write}

case "$mode" in
  write|--check) ;;
  *)
    echo "usage: $0 [write|--check]" >&2
    exit 2
    ;;
esac

patch_work=$(mktemp -d "${TMPDIR:-/tmp}/helium-overlay-patch.XXXXXX")
case "$patch_work" in
  /tmp/helium-overlay-patch.*) ;;
  *) exit 1 ;;
esac
cleanup() {
  find "$patch_work" -depth -delete
}
trap cleanup EXIT

git -C "$patch_work" init -q
cp -a "$overlay/." "$patch_work/"
git -C "$patch_work" add .
git -C "$patch_work" -c core.safecrlf=false diff \
  --cached --no-ext-diff --binary >"$patch_work/generated.patch"

if [[ "$mode" == --check ]]; then
  cmp "$patch_work/generated.patch" "$patch"
else
  cp "$patch_work/generated.patch" "$patch"
fi
