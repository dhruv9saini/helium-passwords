#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: verify-deployment-artifact-receipt.sh ARTIFACT RECEIPT EXPECTED-TARGET" >&2
}

[ "$#" -eq 3 ] || {
    usage
    exit 2
}
artifact=$(realpath -e -- "$1")
receipt=$(realpath -e -- "$2")
expected_target=$3

[ -f "${artifact}" ] && [ ! -L "${artifact}" ] || {
    echo "artifact must be a regular non-symlink file" >&2
    exit 1
}
[ -f "${receipt}" ] && [ ! -L "${receipt}" ] || {
    echo "receipt must be a regular non-symlink file" >&2
    exit 1
}
case "${expected_target}" in
    linux-x86_64|linux-arm64|linux-arm64-chroot|android-arm64) ;;
    *) echo "invalid expected target: ${expected_target}" >&2; exit 2 ;;
esac

declare -A values=()
allowed=' schema_version artifact_sha256 artifact_size target helium_sync_commit helium_passwords_commit helium_core_commit chromium_commit build_job_id provenance_sha256 created_at '
while IFS= read -r line || [ -n "${line}" ]; do
    [ -n "${line}" ] && [[ "${line}" == *=* ]] || {
        echo "invalid deployment receipt line" >&2
        exit 1
    }
    key=${line%%=*}
    value=${line#*=}
    [[ "${key}" =~ ^[a-z][a-z0-9_]*$ ]] && \
        [[ "${allowed}" == *" ${key} "* ]] || {
        echo "unknown deployment receipt field: ${key}" >&2
        exit 1
    }
    [ -z "${values[${key}]+set}" ] || {
        echo "duplicate deployment receipt field: ${key}" >&2
        exit 1
    }
    [ -n "${value}" ] && [[ "${value}" != *$'\r'* ]] || {
        echo "empty or malformed deployment receipt value: ${key}" >&2
        exit 1
    }
    values[${key}]=${value}
done <"${receipt}"
required=(
    schema_version
    artifact_sha256
    artifact_size
    target
    helium_sync_commit
    helium_passwords_commit
    helium_core_commit
    chromium_commit
    build_job_id
    provenance_sha256
    created_at
)
[ "${#values[@]}" -eq "${#required[@]}" ] || {
    echo "deployment receipt field inventory is incomplete" >&2
    exit 1
}
for key in "${required[@]}"; do
    [ -n "${values[${key}]:-}" ] || {
        echo "missing deployment receipt field: ${key}" >&2
        exit 1
    }
done
[ "${values[schema_version]}" = 1 ] || {
    echo "unsupported deployment receipt schema" >&2
    exit 1
}
[ "${values[target]}" = "${expected_target}" ] || {
    echo "deployment target mismatch" >&2
    exit 1
}
[[ "${values[artifact_sha256]}" =~ ^[0-9a-f]{64}$ ]] && \
    [[ "${values[provenance_sha256]}" =~ ^[0-9a-f]{64}$ ]] && \
    [[ "${values[artifact_size]}" =~ ^[1-9][0-9]*$ ]] || {
    echo "invalid deployment receipt hash or size" >&2
    exit 1
}
for key in helium_sync_commit helium_passwords_commit helium_core_commit \
    chromium_commit; do
    [[ "${values[${key}]}" =~ ^[0-9a-f]{40}$ ]] || {
        echo "invalid full commit in ${key}" >&2
        exit 1
    }
done
[[ "${values[build_job_id]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || {
    echo "invalid build job id" >&2
    exit 1
}
[[ "${values[created_at]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "invalid deployment receipt timestamp" >&2
    exit 1
}
[ "$(stat -c %s "${artifact}")" = "${values[artifact_size]}" ] && \
    [ "$(sha256sum "${artifact}" | awk '{ print $1 }')" = \
        "${values[artifact_sha256]}" ] || {
    echo "deployment artifact hash or size mismatch" >&2
    exit 1
}
printf 'artifact_admission=verified\n'
for key in artifact_sha256 target helium_sync_commit helium_passwords_commit \
    helium_core_commit chromium_commit build_job_id provenance_sha256 \
    created_at; do
    printf '%s=%s\n' "${key}" "${values[${key}]}"
done
