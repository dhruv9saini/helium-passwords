#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 CHROMIUM_SRC EXPECTED_COMMIT" >&2
  exit 64
fi

source_root=$(realpath "$1")
expected_commit=$2
build_file="$source_root/chrome/browser/preferences/BUILD.gn"

[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'expected Chromium commit must be a full SHA-1' >&2
  exit 64
}
[[ -d "$source_root/.git" && -f "$source_root/OWNERS" ]] || {
  echo "not a Chromium source checkout: $source_root" >&2
  exit 1
}
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$expected_commit" ]] || {
  echo 'Chromium source does not match the expected commit' >&2
  exit 1
}
[[ -f "$build_file" && ! -L "$build_file" ]] || {
  echo 'missing chrome/browser/preferences/BUILD.gn' >&2
  exit 1
}

restored_paths=(
  components/safe_browsing/core/common/safe_browsing_prefs.cc
  components/safe_browsing/core/common/safe_browsing_prefs.h
  components/signin/public/base/signin_pref_names.cc
  components/signin/public/base/signin_pref_names.h
)
for relative_path in "${restored_paths[@]}"; do
  [[ -f "$source_root/$relative_path" && ! -L "$source_root/$relative_path" ]] || {
    echo "missing restored Android pref input: $relative_path" >&2
    exit 1
  }
  expected_blob=$(git -C "$source_root" rev-parse "$expected_commit:$relative_path")
  [[ "$(git -C "$source_root" hash-object "$relative_path")" == "$expected_blob" ]] || {
    echo "restored Android pref input does not match pinned Chromium: $relative_path" >&2
    exit 1
  }
done

target_re='^java_cpp_strings\("java_pref_names_srcjar"\)[[:space:]]*\{[[:space:]]*$'
sources_re='^[[:space:]]*sources[[:space:]]*=[[:space:]]*\[[[:space:]]*$'
source_re='^[[:space:]]*"//([^"]+)",[[:space:]]*$'
end_re='^[[:space:]]*\][[:space:]]*$'
blank_re='^[[:space:]]*(#.*)?$'
in_target=false
in_sources=false
target_count=0
source_count=0
declare -A seen_sources=()

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ $target_re ]]; then
    [[ "$in_target" == false ]] || {
      echo 'nested java_pref_names_srcjar target' >&2
      exit 1
    }
    in_target=true
    ((target_count += 1))
    continue
  fi
  [[ "$in_target" == true ]] || continue
  if [[ "$in_sources" == false && "$line" =~ $sources_re ]]; then
    in_sources=true
    continue
  fi
  [[ "$in_sources" == true ]] || continue
  if [[ "$line" =~ $end_re ]]; then
    in_sources=false
    in_target=false
    continue
  fi
  [[ "$line" =~ $blank_re ]] && continue
  [[ "$line" =~ $source_re ]] || {
    echo "unrecognized java_pref_names_srcjar source entry: $line" >&2
    exit 1
  }
  relative_path=${BASH_REMATCH[1]}
  [[ -z "${seen_sources[$relative_path]:-}" ]] || {
    echo "duplicate java_pref_names_srcjar source: $relative_path" >&2
    exit 1
  }
  seen_sources[$relative_path]=1
  ((source_count += 1))
  [[ -f "$source_root/$relative_path" && ! -L "$source_root/$relative_path" ]] || {
    echo "missing java_pref_names_srcjar source: $relative_path" >&2
    exit 1
  }
done < "$build_file"

[[ "$target_count" -eq 1 && "$in_target" == false &&
    "$in_sources" == false && "$source_count" -gt 0 ]] || {
  echo 'invalid java_pref_names_srcjar source inventory' >&2
  exit 1
}

printf 'android_java_pref_inputs=verified count=%s\n' "$source_count"
