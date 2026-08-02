#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 SYNC_ACCEPTANCE SYNC_EVIDENCE CONTROL_ACCEPTANCE CONTROL_EVIDENCE NEW_RECEIPT" >&2
  exit 64
fi

sync_acceptance=$(realpath "$1")
sync_evidence=$(realpath "$2")
control_acceptance=$(realpath "$3")
control_evidence=$(realpath "$4")
receipt=$(realpath -m "$5")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
auditor="$script_dir/audit-probe-pair.mjs"

command -v node >/dev/null
command -v sha256sum >/dev/null
[[ -f "$auditor" && ! -L "$auditor" && ! -e "$receipt" && ! -L "$receipt" ]] || {
  echo "offline auditor is unsafe or pair receipt already exists" >&2
  exit 1
}

audit=$(
  node "$auditor" verify \
    --sync-acceptance "$sync_acceptance" \
    --sync-evidence "$sync_evidence" \
    --control-acceptance "$control_acceptance" \
    --control-evidence "$control_evidence"
)
declare -A values=()
allowed=(
  helium_sync_commit chromium_commit sync_archive_sha256 sync_apk_sha256
  sync_result_sha256 control_archive_sha256 control_apk_sha256
  control_result_sha256 shared_flags_gn_sha256
  shared_locked_gn_args_sha256 fixture_receipt_sha256 media_manifest_sha256
  physical_identity_sha256 offline_auditor_sha256
)
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([a-z][a-z0-9_]*)=(.+)$ ]] || {
    echo "offline auditor emitted a malformed line" >&2
    exit 1
  }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  admitted=false
  for candidate in "${allowed[@]}"; do
    if [[ "$key" == "$candidate" ]]; then admitted=true; break; fi
  done
  [[ "$admitted" == true && ! -v "values[$key]" ]] || {
    echo "offline auditor emitted an unexpected or duplicate field" >&2
    exit 1
  }
  values[$key]=$value
done <<<"$audit"
[[ "${#values[@]}" -eq "${#allowed[@]}" ]] || {
  echo "offline auditor output is incomplete" >&2
  exit 1
}
for key in "${allowed[@]}"; do
  [[ -v "values[$key]" ]] || { echo "offline auditor omitted $key" >&2; exit 1; }
done
[[ "${values[offline_auditor_sha256]}" == \
    "$(sha256sum "$auditor" | cut -d' ' -f1)" ]] || {
  echo "offline auditor did not bind its executing source" >&2
  exit 1
}

receipt_parent=$(dirname "$receipt")
mkdir -p "$receipt_parent"
temporary=$(mktemp "$receipt_parent/.helium-media-pair.XXXXXX")
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT
chmod 600 "$temporary"
{
  printf 'schema_version=2\n'
  for key in "${allowed[@]}"; do
    printf '%s=%s\n' "$key" "${values[$key]}"
  done
  printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$temporary"
ln "$temporary" "$receipt"
rm "$temporary"
trap - EXIT
printf 'pair_receipt=%s\n' "$receipt"
printf 'pair_receipt_sha256=%s\n' "$(sha256sum "$receipt" | cut -d' ' -f1)"
