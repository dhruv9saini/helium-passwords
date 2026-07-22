#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-artifact-receipt.sh ARTIFACT RECEIPT EXPECTED_TARGET

Verify a build-produced, secret-free Helium artifact receipt.  The receipt is
strict: one key per line, no shell evaluation, and no unknown fields.
EOF
}

[[ $# -eq 3 ]] || { usage; exit 64; }

artifact=$(realpath -e -- "$1")
receipt=$(realpath -e -- "$2")
expected_target=$3

[[ -f "$artifact" && ! -L "$artifact" ]] || {
  echo "artifact must be a regular non-symlink file" >&2
  exit 1
}
[[ -f "$receipt" && ! -L "$receipt" ]] || {
  echo "receipt must be a regular non-symlink file" >&2
  exit 1
}
[[ "$expected_target" =~ ^(linux-(x86_64|arm64)|linux-arm64-chroot|android-arm64)$ ]] || {
  echo "invalid expected target: $expected_target" >&2
  exit 64
}

declare -A values=()
allowed=' schema_version artifact_sha256 artifact_size target helium_sync_commit helium_passwords_commit helium_core_commit chromium_commit build_job_id provenance_sha256 created_at '
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || {
    echo "invalid artifact receipt line" >&2
    exit 1
  }
  key=${line%%=*}
  value=${line#*=}
  [[ "$key" =~ ^[a-z][a-z0-9_]*$ && "$allowed" == *" $key "* ]] || {
    echo "unknown artifact receipt field: $key" >&2
    exit 1
  }
  [[ -z "${values[$key]+set}" ]] || {
    echo "duplicate artifact receipt field: $key" >&2
    exit 1
  }
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || {
    echo "empty or malformed artifact receipt value: $key" >&2
    exit 1
  }
  values[$key]=$value
done <"$receipt"

required=(schema_version artifact_sha256 artifact_size target
  helium_sync_commit helium_passwords_commit helium_core_commit chromium_commit
  build_job_id provenance_sha256 created_at)
for key in "${required[@]}"; do
  [[ -n "${values[$key]:-}" ]] || {
    echo "missing artifact receipt field: $key" >&2
    exit 1
  }
done
[[ ${#values[@]} -eq ${#required[@]} ]] || exit 1

[[ "${values[schema_version]}" == 1 ]] || { echo "unsupported artifact receipt schema" >&2; exit 1; }
[[ "${values[target]}" == "$expected_target" ]] || { echo "artifact target mismatch" >&2; exit 1; }
[[ "${values[artifact_sha256]}" =~ ^[a-f0-9]{64}$ ]] || { echo "invalid artifact SHA-256" >&2; exit 1; }
[[ "${values[provenance_sha256]}" =~ ^[a-f0-9]{64}$ ]] || { echo "invalid provenance SHA-256" >&2; exit 1; }
[[ "${values[artifact_size]}" =~ ^[1-9][0-9]*$ ]] || { echo "invalid artifact size" >&2; exit 1; }
for key in helium_sync_commit helium_passwords_commit helium_core_commit chromium_commit; do
  [[ "${values[$key]}" =~ ^[a-f0-9]{40}$ ]] || {
    echo "invalid full commit in $key" >&2
    exit 1
  }
done
[[ "${values[build_job_id]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || {
  echo "invalid build job id" >&2
  exit 1
}
[[ "${values[created_at]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
  echo "invalid receipt timestamp" >&2
  exit 1
}

actual_size=$(stat -c %s -- "$artifact")
actual_sha=$(sha256sum -- "$artifact" | awk '{print $1}')
[[ "$actual_size" == "${values[artifact_size]}" ]] || { echo "artifact size mismatch" >&2; exit 1; }
[[ "$actual_sha" == "${values[artifact_sha256]}" ]] || { echo "artifact SHA-256 mismatch" >&2; exit 1; }

printf 'artifact_admission=verified\nartifact_sha256=%s\ntarget=%s\nhelium_sync_commit=%s\nbuild_job_id=%s\n' \
  "$actual_sha" "${values[target]}" "${values[helium_sync_commit]}" "${values[build_job_id]}"
