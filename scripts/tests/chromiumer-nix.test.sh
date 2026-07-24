#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
script="${repo_root}/scripts/chromiumer-nix.sh"
expression="${repo_root}/chromium/nix/chromiumer-shell.nix"

bash -n "${script}"
grep -q '24b04c927b23c39cf9c5227cc8dc6f64a744c8e9' "${expression}"
grep -q 'a793ee3962cf3be3d0e9ed1022147ea9cd34eea9' "${expression}"
grep -q '023d699q0s9rzx87x6fp4jpar7pd2y3h4gjrdmhznxbbg76yhp9b' "${expression}"
grep -q 'Return the FHS derivation itself' "${expression}"
if tail -n 1 "${expression}" | grep -q '\.env'; then
    echo "chromiumer Nix expression returned the interactive shell attribute" >&2
    exit 1
fi
grep -Fqx \
    '    for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do' \
    "${script}"
grep -Fqx '        [ "${!variable:-}" = 1 ] || {' "${script}"
grep -q 'helium-job-' "${script}"
grep -q 'environment is not realised' "${script}"
grep -q 'helium-chromium-150-env' "${script}"
grep -q 'environment_source_sha256=' "${script}"
grep -q 'chromium-150-${environment_source_sha256:0:16}' "${script}"
grep -q 'nix-store --query --outputs' "${script}"
grep -q 'nodejs_22' "${expression}"
grep -q 'ninja' "${expression}"
if grep -q 'helium-chromium-148-env' "${script}"; then
    echo "stale Chromium 148 environment entry point survived" >&2
    exit 1
fi
grep -q 'future_build_budget_bytes=.*80' "${script}"
grep -q 'realise_budget_bytes=.*20' "${script}"
grep -q 'realise_start_gate_bytes=' "${script}"
grep -q 'realise_consumed_bytes=' "${script}"
grep -q 'post_realise_floor_bytes=' "${script}"
grep -q 'setsid nix-build' "${script}"

printf 'chromiumer_nix_contract=passed\n'
