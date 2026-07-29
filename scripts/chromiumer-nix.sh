#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
environment_file="${repo_root}/chromium/nix/chromiumer-shell.nix"
environment_source_sha256=$(sha256sum "${environment_file}" | awk '{ print $1 }')
environment_root="${HELIUM_CHROMIUMER_NIX_ROOT:-${HOME}/.local/state/helium-build-env/chromium-150-${environment_source_sha256:0:16}}"
realise_state="${environment_root}.realise.env"
expected_chromium_commit=24b04c927b23c39cf9c5227cc8dc6f64a744c8e9
expected_nixpkgs_commit=a793ee3962cf3be3d0e9ed1022147ea9cd34eea9
future_build_budget_bytes=$((80 * 1024 * 1024 * 1024))
root_floor_bytes=$((2 * 1024 * 1024 * 1024))
realise_budget_bytes=$((20 * 1024 * 1024 * 1024))
post_realise_floor_bytes=$((future_build_budget_bytes + root_floor_bytes))
realise_start_gate_bytes=$((post_realise_floor_bytes + realise_budget_bytes))

usage() {
    cat >&2 <<'EOF'
usage: scripts/chromiumer-nix.sh <check|realise|provenance|run> [-- command ...]

  check       Parse and verify the pinned expression; do not realise it.
  realise     Materialize the pinned closure and stable GC root on chromiumer.
  provenance  Print the realised environment path and closure hash.
  run         Enter the already-realised environment inside an isolated build job.
EOF
}

host_short() {
    uname -n | cut -d. -f1
}

require_chromiumer() {
    [ "$(host_short)" = chromiumer ] || {
        echo "refusing to run the chromiumer environment outside chromiumer" >&2
        exit 1
    }
}

require_isolated_job() {
    local variable
    for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do
        [ "${!variable:-}" = 1 ] || {
            echo "operation must inherit ${variable}=1 from chromiumer-worker" >&2
            exit 1
        }
    done
    grep -Eq '/helium-job-[a-z0-9-]+\.service(/|$)' /proc/self/cgroup || {
        echo "operation must execute inside an isolated helium-job systemd cgroup" >&2
        exit 1
    }
    case "${TMPDIR:-}" in
        "${HOME}/helium-builds/work/"*/tmp) ;;
        *) echo "TMPDIR is outside the isolated job workspace" >&2; exit 1 ;;
    esac
}

verify_pin() {
    grep -q "${expected_chromium_commit}" "${environment_file}" || {
        echo "Chromium environment/source lock mismatch" >&2
        exit 1
    }
    grep -q "${expected_nixpkgs_commit}" "${environment_file}" || {
        echo "Chromium environment/nixpkgs lock mismatch" >&2
        exit 1
    }
}

check_environment() {
    require_chromiumer
    verify_pin
    command -v nix-instantiate >/dev/null || {
        echo "nix-instantiate is unavailable" >&2
        exit 1
    }
    nix-instantiate --parse "${environment_file}" >/dev/null
    printf 'nix_environment=parse-ok\nchromium_commit=%s\nnixpkgs_commit=%s\n' \
        "${expected_chromium_commit}" "${expected_nixpkgs_commit}"
}

realise_environment() {
    require_chromiumer
    require_isolated_job
    verify_pin
    command -v nix-build >/dev/null || {
        echo "nix-build is unavailable" >&2
        exit 1
    }
    [ ! -e "${environment_root}" ] || {
        echo "environment root already exists; inspect it instead of replacing it" >&2
        exit 1
    }
    local start_available available consumed nix_pid state_temporary
    local failure_reason=''
    start_available=$(df -PB1 / | awk 'NR == 2 { print $4 }')
    [ "${start_available}" -ge "${realise_start_gate_bytes}" ] || {
        echo "environment realization requires 102 GiB free: 80 GiB future build + 2 GiB root floor + 20 GiB Nix budget" >&2
        exit 1
    }
    mkdir -p "$(dirname "${environment_root}")"
    setsid nix-build "${environment_file}" --out-link "${environment_root}" &
    nix_pid=$!
    while kill -0 "${nix_pid}" 2>/dev/null; do
        available=$(df -PB1 / | awk 'NR == 2 { print $4 }')
        consumed=$((start_available - available))
        [ "${consumed}" -ge 0 ] || consumed=0
        if [ "${consumed}" -gt "${realise_budget_bytes}" ]; then
            failure_reason="Nix realization exceeded its 20 GiB root-space budget"
            kill -TERM -- "-${nix_pid}" 2>/dev/null || true
            break
        elif [ "${available}" -lt "${post_realise_floor_bytes}" ]; then
            failure_reason="Nix realization breached the 82 GiB post-realization floor"
            kill -TERM -- "-${nix_pid}" 2>/dev/null || true
            break
        fi
        sleep 2
    done
    if ! wait "${nix_pid}"; then
        [ -z "${failure_reason}" ] || echo "${failure_reason}" >&2
        exit 1
    fi
    available=$(df -PB1 / | awk 'NR == 2 { print $4 }')
    consumed=$((start_available - available))
    [ "${consumed}" -ge 0 ] || consumed=0
    [ "${consumed}" -le "${realise_budget_bytes}" ] && \
        [ "${available}" -ge "${post_realise_floor_bytes}" ] || {
        echo "realized environment failed final disk accounting" >&2
        exit 1
    }
    state_temporary="${realise_state}.tmp"
    {
        printf 'root_start_available_bytes=%s\n' "${start_available}"
        printf 'root_end_available_bytes=%s\n' "${available}"
        printf 'realise_consumed_bytes=%s\n' "${consumed}"
        printf 'realise_budget_bytes=%s\n' "${realise_budget_bytes}"
        printf 'post_realise_floor_bytes=%s\n' "${post_realise_floor_bytes}"
        printf 'realise_start_gate_bytes=%s\n' "${realise_start_gate_bytes}"
    } >"${state_temporary}"
    mv "${state_temporary}" "${realise_state}"
    provenance
}

provenance() {
    require_chromiumer
    verify_pin
    [ -L "${environment_root}" ] || {
        echo "pinned Chromium environment is not realised: ${environment_root}" >&2
        exit 1
    }
    local realised expected_derivation expected_output closure_hash closure_bytes
    realised=$(readlink -f "${environment_root}")
    [ -x "${realised}/bin/helium-chromium-150-env" ] || {
        echo "realised environment entry point is missing" >&2
        exit 1
    }
    expected_derivation=$(nix-instantiate "${environment_file}")
    expected_output=$(nix-store --query --outputs "${expected_derivation}")
    [ "${realised}" = "${expected_output}" ] || {
        echo "realised environment does not match the current Nix expression" >&2
        exit 1
    }
    closure_hash=$(nix-store --query --requisites "${realised}" | sort | sha256sum | awk '{ print $1 }')
    closure_bytes=$(nix-store --query --requisites "${realised}" | \
        xargs nix-store --query --size | awk '{ total += $1 } END { print total }')
    printf 'nix_environment=%s\nclosure_sha256=%s\nclosure_bytes=%s\nchromium_commit=%s\nnixpkgs_commit=%s\nnix_version=%s\n' \
        "${realised}" "${closure_hash}" "${closure_bytes}" \
        "${expected_chromium_commit}" "${expected_nixpkgs_commit}" "$(nix --version)"
    printf 'environment_source_sha256=%s\n' "${environment_source_sha256}"
    printf 'nix_derivation=%s\n' "${expected_derivation}"
    printf 'grit_disable_multiprocessing=1\n'
    [ ! -f "${realise_state}" ] || cat "${realise_state}"
}

run_environment() {
    require_chromiumer
    verify_pin
    [ "${1:-}" = -- ] && [ "$#" -gt 1 ] || {
        usage
        exit 2
    }
    shift
    require_isolated_job
    [ -L "${environment_root}" ] || {
        echo "environment is not realised; run realise, rerun production preflight, then stage" >&2
        exit 1
    }
    local realised command_text
    realised=$(readlink -f "${environment_root}")
    printf -v command_text '%q ' "$@"
    export HELIUM_NIX_RUN_COMMAND="${command_text}"
    # GRIT otherwise forks up to one worker per CPU inside a single Ninja edge,
    # bypassing the production one-job policy and thrashing at memory.high.
    export GRIT_DISABLE_MULTIPROCESSING=1
    exec "${realised}/bin/helium-chromium-150-env"
}

command_name=${1:-}
shift || true
case "${command_name}" in
    check) [ "$#" -eq 0 ] || exit 2; check_environment ;;
    realise) [ "$#" -eq 0 ] || exit 2; realise_environment ;;
    provenance) [ "$#" -eq 0 ] || exit 2; provenance ;;
    run) run_environment "$@" ;;
    -h|--help) usage ;;
    *) usage; exit 2 ;;
esac
