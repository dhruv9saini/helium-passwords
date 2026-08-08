#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-ownership.XXXXXX")
trap 'find "${test_root}" -depth -delete' EXIT
export HELIUM_CHROMIUMER_STATE_ROOT="${test_root}/state"
export HELIUM_CHROMIUMER_WORK_ROOT="${test_root}/work"
mkdir -p "${HELIUM_CHROMIUMER_STATE_ROOT}" \
    "${HELIUM_CHROMIUMER_WORK_ROOT}"

# shellcheck source=../chromiumer-worker.sh
source "${repo_root}/scripts/chromiumer-worker.sh"

job='ownership-proof'
owner='/root/helium_sync'
generation='ownership-proof-20260808-r1'
state_dir="${HELIUM_CHROMIUMER_STATE_ROOT}/${job}"
job_root="${HELIUM_CHROMIUMER_WORK_ROOT}/${job}"
mkdir -p "${state_dir}" "${job_root}/source"
printf 'profile=test\ndisk_budget_gib=1\ndisk_budget_bytes=1073741824\nworkspace_owner=%s\n' \
    "${job}" >"${state_dir}/stage.env"
printf 'artifact\n' >"${job_root}/source/proof.txt"

claim_job_ownership "${job}" "${owner}" "${generation}" \
    >"${test_root}/claim.out"
grep -Fqx "job=${job}" "${state_dir}/owner.env"
grep -Fqx "owner=${owner}" "${state_dir}/owner.env"
grep -Fqx "generation=${generation}" "${state_dir}/owner.env"
claim_job_ownership "${job}" "${owner}" "${generation}" \
    >"${test_root}/claim-retry.out"
grep -Fqx 'existing=true' "${test_root}/claim-retry.out"

if (artifact_info "${job}" proof.txt) \
    >"${test_root}/stale-artifact.out" 2>"${test_root}/stale-artifact.error"; then
    echo "stale controller read a claimed artifact" >&2
    exit 1
fi
grep -Fq 'job ownership mismatch' "${test_root}/stale-artifact.error"
if (artifact_info "${job}" proof.txt "${owner}" ownership-proof-wrong-r1) \
    >"${test_root}/wrong-artifact.out" 2>"${test_root}/wrong-artifact.error"; then
    echo "wrong generation read a claimed artifact" >&2
    exit 1
fi
grep -Fq 'job ownership mismatch' "${test_root}/wrong-artifact.error"
cp "${state_dir}/owner.env" "${test_root}/owner.valid"
printf 'job=%s\n' "${job}" >"${state_dir}/owner.env"
if (artifact_info "${job}" proof.txt "${owner}" "${generation}") \
    >"${test_root}/malformed-artifact.out" \
    2>"${test_root}/malformed-artifact.error"; then
    echo "malformed remote ownership record failed open" >&2
    exit 1
fi
cp "${test_root}/owner.valid" "${state_dir}/owner.env"
artifact_info "${job}" proof.txt "${owner}" "${generation}" \
    >"${test_root}/artifact.out"
grep -Fq 'path='"${job_root}"'/source/proof.txt' "${test_root}/artifact.out"

sha=$(sha256sum "${job_root}/source/proof.txt" | awk '{ print $1 }')
if (mark_returned "${job}" "${sha}") \
    >"${test_root}/stale-return.out" 2>"${test_root}/stale-return.error"; then
    echo "stale controller marked a claimed artifact returned" >&2
    exit 1
fi
grep -Fq 'job ownership mismatch' "${test_root}/stale-return.error"
mark_returned "${job}" "${sha}" "${owner}" "${generation}"
grep -Fqx "sha256=${sha}" "${state_dir}/artifact-returned.env"

if (cleanup_job "${job}") \
    >"${test_root}/stale-cleanup.out" 2>"${test_root}/stale-cleanup.error"; then
    echo "stale controller cleaned a claimed workspace" >&2
    exit 1
fi
grep -Fq 'job ownership mismatch' "${test_root}/stale-cleanup.error"

# No real unit is active in this isolated function test.
systemctl() {
    [ "$*" = '--user --quiet is-active helium-job-ownership-proof.service' ] ||
        [ "$*" = '--user --quiet is-active helium-job-*.service' ]
    return 1
}
cleanup_job "${job}" "${owner}" "${generation}" \
    >"${test_root}/cleanup.out"
[ ! -e "${job_root}" ]
grep -Fqx "cleaned_by_job=${job}" "${state_dir}/workspace-cleaned-by.env"

printf 'chromiumer_ownership=passed\n'
