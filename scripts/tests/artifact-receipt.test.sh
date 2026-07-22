#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-artifact-receipt.XXXXXX)
trap 'find "$test_root" -depth -delete' EXIT

artifact=$test_root/helium.tar.xz
receipt=$test_root/helium.receipt.env
printf 'synthetic artifact\n' >"$artifact"
artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
artifact_size=$(stat -c %s "$artifact")
commit=0123456789abcdef0123456789abcdef01234567
cat >"$receipt" <<EOF
schema_version=1
artifact_sha256=$artifact_sha
artifact_size=$artifact_size
target=linux-arm64-chroot
helium_sync_commit=$commit
helium_passwords_commit=$commit
helium_core_commit=$commit
chromium_commit=$commit
build_job_id=synthetic-admission-01
provenance_sha256=$(printf provenance | sha256sum | awk '{print $1}')
created_at=2026-07-22T12:00:00Z
EOF

output=$("$repo_root/scripts/deployment/verify-artifact-receipt.sh" \
  "$artifact" "$receipt" linux-arm64-chroot)
grep -qx 'artifact_admission=verified' <<<"$output"
grep -qx "artifact_sha256=$artifact_sha" <<<"$output"

cp "$receipt" "$test_root/tampered.receipt.env"
sed -i 's/target=linux-arm64-chroot/target=linux-x86_64/' "$test_root/tampered.receipt.env"
if "$repo_root/scripts/deployment/verify-artifact-receipt.sh" \
  "$artifact" "$test_root/tampered.receipt.env" linux-arm64-chroot >/dev/null 2>&1; then
  echo 'wrong artifact target passed admission' >&2
  exit 1
fi

printf tamper >>"$artifact"
if "$repo_root/scripts/deployment/verify-artifact-receipt.sh" \
  "$artifact" "$receipt" linux-arm64-chroot >/dev/null 2>&1; then
  echo 'tampered artifact passed admission' >&2
  exit 1
fi

printf 'artifact_receipt=passed\n'
