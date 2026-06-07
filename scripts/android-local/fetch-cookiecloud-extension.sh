#!/usr/bin/env bash
set -euo pipefail

repo=${COOKIECLOUD_REPO:-easychen/CookieCloud}
tag=${COOKIECLOUD_TAG:-release-v1.0.3}
asset=${COOKIECLOUD_ASSET:-cookie-cloud-1.0.3-chrome.zip}
output=${COOKIECLOUD_EXT:-/tmp/cookiecloud-extension-chrome-mv3.tar.xz}

command -v gh >/dev/null
command -v unzip >/dev/null
command -v tar >/dev/null

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

gh release download "$tag" \
  --repo "$repo" \
  --pattern "$asset" \
  --dir "$work_dir" \
  --clobber

mkdir -p "$work_dir/unpacked"
unzip -q "$work_dir/$asset" -d "$work_dir/unpacked"

mkdir -p "$(dirname "$output")"
tar -C "$work_dir/unpacked" -cJf "$output" .
echo "$output"
