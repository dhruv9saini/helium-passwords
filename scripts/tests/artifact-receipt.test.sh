#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-artifact-receipt.XXXXXX)
trap 'find "$test_root" -depth -delete' EXIT

artifact=$test_root/helium.tar.xz
receipt=$test_root/helium.receipt.env
printf 'synthetic artifact\n' >"$artifact"
artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
commit=0123456789abcdef0123456789abcdef01234567
"$repo_root/scripts/write-deployment-artifact-receipt.sh" \
  "$artifact" linux-arm64-chroot \
  "$commit" "$commit" "$commit" "$commit" \
  synthetic-admission-01 \
  "$(printf provenance | sha256sum | awk '{print $1}')" \
  "$receipt" >/dev/null

output=$("$repo_root/scripts/verify-deployment-artifact-receipt.sh" \
  "$artifact" "$receipt" linux-arm64-chroot)
grep -qx 'artifact_admission=verified' <<<"$output"
grep -qx "artifact_sha256=$artifact_sha" <<<"$output"

cp "$receipt" "$test_root/tampered.receipt.env"
sed -i 's/target=linux-arm64-chroot/target=linux-x86_64/' "$test_root/tampered.receipt.env"
if "$repo_root/scripts/verify-deployment-artifact-receipt.sh" \
  "$artifact" "$test_root/tampered.receipt.env" linux-arm64-chroot >/dev/null 2>&1; then
  echo 'wrong artifact target passed admission' >&2
  exit 1
fi

printf tamper >>"$artifact"
if "$repo_root/scripts/verify-deployment-artifact-receipt.sh" \
  "$artifact" "$receipt" linux-arm64-chroot >/dev/null 2>&1; then
  echo 'tampered artifact passed admission' >&2
  exit 1
fi

printf 'artifact_receipt=passed\n'
