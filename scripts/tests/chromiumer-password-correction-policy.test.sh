#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../chromiumer-worker.sh
# shellcheck disable=SC1091
. "${repo_root}/scripts/chromiumer-worker.sh"

owner=corrected-linux-owner
command=(
  scripts/chromiumer-nix.sh
  run
  --
  env
  HELIUM_LINUX_PHASE=retained
  'CCC_OVERRIDE_OPTIONS=# +-Wl,--threads=1'
  bash
  scripts/correct-retained-linux-password-generation.sh
  helium-passwords
  x86_64
  linux-x86_64
  "${owner}"
  baseline-build
  baseline-return
)

retained_password_generation_correction_command "${owner}" "${command[@]}"
if retained_password_generation_correction_command wrong-owner "${command[@]}"; then
  echo "correction matcher accepted the wrong workspace owner" >&2
  exit 1
fi
wrong_command=("${command[@]}")
wrong_command[5]='CCC_OVERRIDE_OPTIONS=# +-Wl,--threads=2'
if retained_password_generation_correction_command \
    "${owner}" "${wrong_command[@]}"; then
  echo "correction matcher accepted two linker threads" >&2
  exit 1
fi
wrong_command=("${command[@]}" extra)
if retained_password_generation_correction_command \
    "${owner}" "${wrong_command[@]}"; then
  echo "correction matcher accepted an extra argument" >&2
  exit 1
fi

build_jobs=''
memory_high=''
memory_max=''
memory_swap_max=''
wall_seconds=''
wall_class=''
profile production
apply_retained_password_generation_correction_policy
[[ "${build_jobs}" == 1 ]]
[[ "${memory_high}" == 3328M ]]
[[ "${memory_max}" == 6G ]]
[[ "${memory_swap_max}" == 3G ]]
[[ "${wall_seconds}" == 172800 ]]
[[ "${wall_class}" == retained-password-generation-correction ]]

printf 'chromiumer password correction policy tests passed\n'
