#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 RUNTIME_KIT_SOURCE EXPECTED_COMMIT EXPECTED_SHA256SUMS_SHA256" >&2
  exit 64
fi

source_root=$(realpath -e "$1")
expected_commit=$2
expected_inventory_sha256=$3

[[ -d "$source_root" && ! -L "$1" ]] || {
  echo "Android runtime-kit source must be one real directory" >&2
  exit 1
}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ &&
    "$expected_inventory_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Android runtime-kit source bindings are invalid" >&2
  exit 64
}

required=(
  fixture-server.mjs
  generate-fixtures.sh
  run-cdp-probe.mjs
  disposable-browser.sh
  prepare-cookie-acceptance-profile.sh
  run-device-probe.sh
  audit-probe-pair.mjs
  verify-probe-pair.sh
  kit-source.env
)

for file in "${required[@]}" SHA256SUMS; do
  [[ -f "$source_root/$file" && ! -L "$source_root/$file" ]] || {
    echo "Android runtime-kit source is missing regular file: $file" >&2
    exit 1
  }
done
[[ "$(find "$source_root" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == \
  "$(printf '%s\n' "${required[@]}" SHA256SUMS | LC_ALL=C sort)" ]] || {
  echo "Android runtime-kit source has an unexpected inventory" >&2
  exit 1
}
[[ "$(sha256sum "$source_root/SHA256SUMS" | cut -d' ' -f1)" == \
    "$expected_inventory_sha256" ]] || {
  echo "Android runtime-kit source inventory does not match its command binding" >&2
  exit 1
}
[[ "$(wc -l < "$source_root/SHA256SUMS")" -eq "${#required[@]}" ]] || {
  echo "Android runtime-kit source checksum inventory has the wrong size" >&2
  exit 1
}
for file in "${required[@]}"; do
  grep -Eq "^[0-9a-f]{64}  ${file}$" "$source_root/SHA256SUMS" || {
    echo "Android runtime-kit source checksum inventory is missing: $file" >&2
    exit 1
  }
done
(
  cd "$source_root"
  sha256sum -c SHA256SUMS >/dev/null
)
[[ "$(cat "$source_root/kit-source.env")" == $'schema_version=1\nruntime_kit_commit='"$expected_commit" ]] || {
  echo "Android runtime-kit source metadata does not match its expected commit" >&2
  exit 1
}

printf 'runtime_kit_commit=%s\n' "$expected_commit"
printf 'runtime_kit_source_sha256=%s\n' "$expected_inventory_sha256"
