#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 CHROMIUM_SRC OUT_DIR EXPECTED_COMMIT PRUNING_LIST TARGET" >&2
  exit 64
fi

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_root=$(realpath "$1")
out_dir=$(realpath "$2")
expected_commit=$3
pruning_list=$(realpath "$4")
target=$5

[[ "$out_dir" == "$source_root"/* ]] || {
  echo "Android output directory is outside Chromium source: $out_dir" >&2
  exit 1
}
[[ "$target" =~ ^[A-Za-z0-9_./:+-]+$ ]] || {
  echo "invalid Android Ninja target: $target" >&2
  exit 64
}
command -v ninja >/dev/null || {
  echo 'ninja is required to validate the Android input graph' >&2
  exit 1
}

"$script_root/restore-android-pruned-build-inputs.sh" validate \
  "$source_root" "$expected_commit" "$pruning_list" >/dev/null

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-pruned-graph.XXXXXX")
cleanup() {
  find "$temporary_root" -depth -delete
}
trap cleanup EXIT

out_relative=$(realpath --relative-to="$source_root" "$out_dir")
source_prefix=
IFS=/ read -r -a out_parts <<< "$out_relative"
for _ in "${out_parts[@]}"; do
  source_prefix="../$source_prefix"
done

ninja -C "$out_dir" -t inputs "$target" > "$temporary_root/inputs.raw"
awk -v prefix="$source_prefix" -v root="$source_root/" '
  index($0, prefix) == 1 { print substr($0, length(prefix) + 1); next }
  index($0, root) == 1 { print substr($0, length(root) + 1) }
' "$temporary_root/inputs.raw" | LC_ALL=C sort -u > "$temporary_root/inputs.relative"
LC_ALL=C sort -u "$pruning_list" > "$temporary_root/pruning.sorted"
LC_ALL=C comm -12 "$temporary_root/inputs.relative" "$temporary_root/pruning.sorted" \
  > "$temporary_root/reachable-pruned.sorted"

cat > "$temporary_root/expected.sorted" <<'EOF'
components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat
components/safe_browsing/core/common/safe_browsing_prefs.h
components/signin/public/base/signin_pref_names.cc
third_party/r8/custom_d8.jar
third_party/r8/custom_r8.jar
EOF

unexpected=$(LC_ALL=C comm -13 "$temporary_root/expected.sorted" \
  "$temporary_root/reachable-pruned.sorted")
missing=$(LC_ALL=C comm -23 "$temporary_root/expected.sorted" \
  "$temporary_root/reachable-pruned.sorted")
if [[ -n "$unexpected" ]]; then
  printf 'unexpected pruned Android target input:\n%s\n' "$unexpected" >&2
  exit 1
fi
if [[ -n "$missing" ]]; then
  printf 'expected pruned Android target input is unreachable:\n%s\n' "$missing" >&2
  exit 1
fi

while IFS= read -r relative_path; do
  printf 'android_pruned_graph_input=%s\n' "$relative_path"
done < "$temporary_root/reachable-pruned.sorted"
printf 'android_pruned_build_graph=verified target=%s count=5\n' "$target"
