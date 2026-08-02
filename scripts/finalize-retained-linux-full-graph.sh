#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: $0 PRODUCT ARCH TARGET BUILD-JOB-ID PRODUCT-SOURCE PLATFORM-CHECKOUT GRAPH-BOUNDARY-RECEIPT OUTPUT.tar.xz OUTPUT.receipt.env" >&2
  exit 64
fi

product=$1
arch=$2
target=$3
job=$4
product_source=$(realpath -e "$5")
checkout=$(realpath -e "$6")
boundary=$(realpath -e "$7")
artifact=$(realpath -m "$8")
receipt=$(realpath -m "$9")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
evidence_parent=$(dirname "$artifact")
evidence="$evidence_parent/${product}-linux-${arch}.full-graph"

[[ ! -e "$artifact" && ! -e "$receipt" && ! -e "$evidence" ]] || {
  echo "external full-graph finalizer refuses to replace any output" >&2
  exit 1
}
HELIUM_PRODUCT_SOURCE_ROOT="$product_source" \
  "$script_dir/capture-linux-full-graph-evidence.sh" \
    "$product" "$arch" "$target" "$job" "$checkout" "$boundary" "$evidence"
HELIUM_PRODUCT_SOURCE_ROOT="$product_source" \
  "$script_dir/package-linux-runtime.sh" \
    "$product" "$arch" "$target" "$job" "$checkout" "$evidence" \
    "$artifact" "$receipt"
printf 'artifact=%s\nreceipt=%s\nfull_graph_evidence=%s\n' \
  "$artifact" "$receipt" "$evidence"
