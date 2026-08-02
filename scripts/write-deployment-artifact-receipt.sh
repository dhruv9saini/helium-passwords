#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: write-deployment-artifact-receipt.sh ARTIFACT TARGET SYNC-COMMIT PASSWORDS-COMMIT CORE-COMMIT CHROMIUM-COMMIT BUILD-JOB-ID PROVENANCE-SHA256 FULL-GRAPH-RECEIPT-SHA256 FULL-GRAPH-INVENTORY-SHA256 NEW-RECEIPT
EOF
}

[ "$#" -eq 11 ] || {
    usage
    exit 2
}
artifact=$(realpath -e -- "$1")
target=$2
sync_commit=$3
passwords_commit=$4
core_commit=$5
chromium_commit=$6
build_job_id=$7
provenance_sha256=$8
full_graph_receipt_sha256=$9
full_graph_inventory_sha256=${10}
receipt=$(realpath -m -- "${11}")

[ -f "${artifact}" ] && [ ! -L "${artifact}" ] && [ -s "${artifact}" ] || {
    echo "artifact must be a regular non-symlink file" >&2
    exit 1
}
case "${target}" in
    linux-x86_64|linux-arm64|linux-arm64-chroot|android-arm64) ;;
    *) echo "invalid deployment target: ${target}" >&2; exit 2 ;;
esac
for commit in "${sync_commit}" "${passwords_commit}" "${core_commit}" \
    "${chromium_commit}"; do
    [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || {
        echo "deployment receipt requires full commits" >&2
        exit 1
    }
done
[[ "${build_job_id}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || {
    echo "invalid build job id" >&2
    exit 2
}
for digest in "${provenance_sha256}" "${full_graph_receipt_sha256}" \
    "${full_graph_inventory_sha256}"; do
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || {
        echo "invalid deployment provenance SHA-256" >&2
        exit 1
    }
done
[ ! -e "${receipt}" ] || {
    echo "refusing to replace existing deployment receipt: ${receipt}" >&2
    exit 1
}
parent=$(dirname "${receipt}")
mkdir -p "${parent}"
parent=$(realpath -e "${parent}")
temporary=$(mktemp "${parent}/.helium-deployment-receipt.XXXXXX")
cleanup() {
    find "${temporary}" -delete 2>/dev/null || true
}
trap cleanup EXIT
cat >"${temporary}" <<EOF
schema_version=2
artifact_sha256=$(sha256sum "${artifact}" | awk '{ print $1 }')
artifact_size=$(stat -c %s "${artifact}")
target=${target}
helium_sync_commit=${sync_commit}
helium_passwords_commit=${passwords_commit}
helium_core_commit=${core_commit}
chromium_commit=${chromium_commit}
build_job_id=${build_job_id}
provenance_sha256=${provenance_sha256}
full_graph_receipt_sha256=${full_graph_receipt_sha256}
full_graph_inventory_sha256=${full_graph_inventory_sha256}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 "${temporary}"
mv --no-clobber "${temporary}" "${receipt}"
trap - EXIT
printf 'deployment_receipt=%s\n' "${receipt}"
