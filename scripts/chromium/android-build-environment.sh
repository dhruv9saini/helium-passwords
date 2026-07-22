#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"

usage() {
  echo "usage: $0 <record|verify> PROVENANCE_DIRECTORY" >&2
}

[[ $# -eq 2 ]] || { usage; exit 64; }
action=$1
provenance=$(realpath "$2")
[[ -d "$provenance" && ! -L "$provenance" ]] || {
  echo "Android build provenance directory is missing or unsafe" >&2
  exit 1
}

metadata() {
  local name=$1 file=$2 value
  value=$(sed -n "s/^${name}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${name}=" "$file")" -eq 1 ]] || {
    echo "Chromiumer Nix provenance is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

verify_environment() {
  local nix_file="$provenance/chromiumer-nix.env"
  local command_file="$provenance/build-command.txt"
  for file in "$nix_file" "$command_file"; do
    [[ -f "$file" && ! -L "$file" ]] || {
      echo "Android build environment provenance is incomplete" >&2
      exit 1
    }
  done
  [[ "$(wc -l < "$command_file")" -eq 1 && -s "$command_file" ]] || {
    echo "Android build command must be one nonempty shell-escaped line" >&2
    exit 1
  }

  local expected_keys actual_keys
  expected_keys=$(printf '%s\n' \
    chromium_commit closure_bytes closure_sha256 nix_environment nix_version \
    nixpkgs_commit post_realise_floor_bytes realise_budget_bytes \
    realise_consumed_bytes realise_start_gate_bytes root_end_available_bytes \
    root_start_available_bytes | sort)
  actual_keys=$(cut -d= -f1 "$nix_file" | sort)
  [[ "$actual_keys" == "$expected_keys" ]] || {
    echo "Chromiumer Nix provenance has an unexpected field inventory" >&2
    exit 1
  }

  local nix_environment closure_sha256 closure_bytes chromium_commit
  local nixpkgs_commit nix_version start_available end_available consumed
  local budget post_floor start_gate
  nix_environment=$(metadata nix_environment "$nix_file")
  closure_sha256=$(metadata closure_sha256 "$nix_file")
  closure_bytes=$(metadata closure_bytes "$nix_file")
  chromium_commit=$(metadata chromium_commit "$nix_file")
  nixpkgs_commit=$(metadata nixpkgs_commit "$nix_file")
  nix_version=$(metadata nix_version "$nix_file")
  start_available=$(metadata root_start_available_bytes "$nix_file")
  end_available=$(metadata root_end_available_bytes "$nix_file")
  consumed=$(metadata realise_consumed_bytes "$nix_file")
  budget=$(metadata realise_budget_bytes "$nix_file")
  post_floor=$(metadata post_realise_floor_bytes "$nix_file")
  start_gate=$(metadata realise_start_gate_bytes "$nix_file")

  [[ "$nix_environment" =~ ^/nix/store/[a-z0-9]{32}-helium-chromium-150-env$ ]]
  [[ "$closure_sha256" =~ ^[0-9a-f]{64}$ ]]
  [[ "$chromium_commit" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]]
  [[ "$nixpkgs_commit" == "$HELIUM_ANDROID_NIXPKGS_COMMIT" ]]
  [[ "$nix_version" == nix\ \(Nix\)\ * && "$nix_version" != *$'\n'* ]]
  for value in "$closure_bytes" "$start_available" "$end_available" \
    "$consumed" "$budget" "$post_floor" "$start_gate"; do
    [[ "$value" =~ ^[0-9]+$ ]]
  done
  (( closure_bytes > 0 && start_available >= start_gate && \
     consumed <= budget && end_available >= post_floor && \
     start_gate == post_floor + budget )) || {
    echo "Chromiumer Nix provenance failed its recorded capacity arithmetic" >&2
    exit 1
  }
}

record_environment() {
  [[ "${HELIUM_BUILD_JOBS:-}" == 2 ]] || {
    echo "Android build must inherit HELIUM_BUILD_JOBS=2" >&2
    exit 1
  }
  [[ -n "${HELIUM_NIX_RUN_COMMAND:-}" && \
      "$HELIUM_NIX_RUN_COMMAND" != *$'\n'* ]] || {
    echo "Android build must run through the pinned Chromiumer Nix entry point" >&2
    exit 1
  }
  local nix_temporary sums_temporary
  nix_temporary=$(mktemp "$provenance/.chromiumer-nix.XXXXXX")
  sums_temporary=$(mktemp "$provenance/.provenance-sha256.XXXXXX")
  trap 'rm -f -- "$nix_temporary" "$sums_temporary"' EXIT
  "$repo_root/scripts/chromiumer-nix.sh" provenance > "$nix_temporary"
  mv "$nix_temporary" "$provenance/chromiumer-nix.env"
  printf '%s\n' "$HELIUM_NIX_RUN_COMMAND" > "$provenance/build-command.txt"
  verify_environment
  (
    cd "$provenance"
    find . -maxdepth 1 -type f \
      ! -name provenance.sha256 \
      ! -name '.provenance-sha256.*' \
      -printf '%P\0' | sort -z | xargs -0 sha256sum
  ) > "$sums_temporary"
  mv "$sums_temporary" "$provenance/provenance.sha256"
  trap - EXIT
}

case "$action" in
  record) record_environment ;;
  verify) verify_environment ;;
  *) usage; exit 64 ;;
esac
