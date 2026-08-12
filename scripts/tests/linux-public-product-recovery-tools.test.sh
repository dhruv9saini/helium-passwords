#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-linux-product-tools-test.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

mkdir -p "$test_root/product" "$test_root/checkout" "$test_root/output"
printf 'synthetic\n' >"$test_root/boundary.env"
printf 'synthetic\n' >"$test_root/failure.env"
chmod 400 "$test_root/boundary.env" "$test_root/failure.env"
failure_sha=$(sha256sum "$test_root/failure.env" | awk '{print $1}')

expect_status() {
  local expected=$1
  shift
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [[ "$actual" == "$expected" ]] || {
    printf 'expected status %s, got %s: %q' "$expected" "$actual" "$1" >&2
    printf ' %q' "${@:2}" >&2
    printf '\n' >&2
    exit 1
  }
}

# A supported public product advances past each product guard and fails at the
# deliberately incomplete synthetic evidence. An unknown product stops at the
# usage guard with status 64.
capture="$repo_root/scripts/capture-linux-full-graph-evidence.sh"
expect_status 1 "$capture" helium-passwords x86_64 linux-x86_64 test-job \
  "$test_root/checkout" "$test_root/boundary.env" "$test_root/capture"
expect_status 64 "$capture" unsupported-product x86_64 linux-x86_64 test-job \
  "$test_root/checkout" "$test_root/boundary.env" "$test_root/capture"

graph_repair="$repo_root/scripts/continue-retained-linux-full-graph-failure.sh"
expect_status 1 "$graph_repair" helium-passwords x86_64 linux-x86_64 \
  test-job "$test_root/product" "$test_root/checkout" \
  "$test_root/failure.env" "$failure_sha" \
  "$test_root/output/helium-passwords-linux-x86_64.tar.xz" \
  "$test_root/output/helium-passwords-linux-x86_64.receipt.env"
expect_status 64 "$graph_repair" unsupported-product x86_64 linux-x86_64 \
  test-job "$test_root/product" "$test_root/checkout" \
  "$test_root/failure.env" "$failure_sha" \
  "$test_root/output/unsupported-product-linux-x86_64.tar.xz" \
  "$test_root/output/unsupported-product-linux-x86_64.receipt.env"

node_repair="$repo_root/scripts/continue-retained-linux-node22-mts-failure.sh"
node_inputs=()
for name in graph-failure first-preflight first-failure node-failure-log \
  first-continuation-log; do
  printf 'synthetic %s\n' "$name" >"$test_root/$name"
  chmod 400 "$test_root/$name"
  node_inputs+=("$test_root/$name")
done
node_hashes=()
for input in "${node_inputs[@]}"; do
  node_hashes+=("$(sha256sum "$input" | awk '{print $1}')")
done
previous_output_sha=$(printf 'a%.0s' {1..64})

run_node_repair() {
  local product=$1
  HELIUM_NODE22_FIRST_CONTINUATION_LOG="${node_inputs[4]}" \
  HELIUM_NODE22_FIRST_CONTINUATION_LOG_SHA256="${node_hashes[4]}" \
  HELIUM_NODE22_PREVIOUS_ACTION_OUTPUT_SHA256="$previous_output_sha" \
    "$node_repair" "$product" x86_64 linux-x86_64 test-job \
      "$test_root/product" "$test_root/checkout" \
      "${node_inputs[0]}" "${node_hashes[0]}" \
      "${node_inputs[1]}" "${node_hashes[1]}" \
      "${node_inputs[2]}" "${node_hashes[2]}" \
      "${node_inputs[3]}" "${node_hashes[3]}" \
      "$test_root/output/${product}-linux-x86_64.tar.xz" \
      "$test_root/output/${product}-linux-x86_64.receipt.env"
}
expect_status 1 run_node_repair helium-passwords
expect_status 64 run_node_repair unsupported-product

printf 'linux public product recovery tool guards passed\n'
