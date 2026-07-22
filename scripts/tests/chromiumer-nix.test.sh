#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
script="${repo_root}/scripts/chromiumer-nix.sh"
expression="${repo_root}/chromium/nix/chromiumer-shell.nix"

bash -n "${script}"
grep -q 'd096af1c9e98c45c3596e59620622b1a049bfecb' "${expression}"
grep -q 'bd85f316bebe290b96b35ddb5c0be62d1f0c9137' "${expression}"
grep -q '1qxr70li1biw260rccm6hjvmn1ysgq2h60pmpq1ww9h6fdv4y884' "${expression}"
grep -q 'Return the FHS derivation itself' "${expression}"
if tail -n 1 "${expression}" | grep -q '\.env'; then
    echo "chromiumer Nix expression returned the interactive shell attribute" >&2
    exit 1
fi
grep -q 'HELIUM_BUILD_JOBS=2' "${script}"
grep -q 'helium-job-' "${script}"
grep -q 'environment is not realised' "${script}"
grep -q 'future_build_budget_bytes=.*80' "${script}"
grep -q 'realise_budget_bytes=.*20' "${script}"
grep -q 'realise_start_gate_bytes=' "${script}"
grep -q 'realise_consumed_bytes=' "${script}"
grep -q 'post_realise_floor_bytes=' "${script}"
grep -q 'setsid nix-build' "${script}"

printf 'chromiumer_nix_contract=passed\n'
