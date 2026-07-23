#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 CHROMIUM_SRC EXPECTED_COMMIT PRUNING_LIST" >&2
  exit 64
fi

source_root=$(realpath "$1")
expected_commit=$2
pruning_list=$(realpath "$3")

[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'expected Chromium commit must be a full SHA-1' >&2
  exit 64
}
[[ -d "$source_root/.git" && -f "$source_root/OWNERS" ]] || {
  echo "not a Chromium source checkout: $source_root" >&2
  exit 1
}
[[ -f "$pruning_list" && ! -L "$pruning_list" ]] || {
  echo "invalid pruning list: $pruning_list" >&2
  exit 1
}
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$expected_commit" ]] || {
  echo 'Chromium source does not match the expected commit' >&2
  exit 1
}

readonly_paths=(
  components/safe_browsing/core/common/safe_browsing_prefs.cc
  components/safe_browsing/core/common/safe_browsing_prefs.h
  components/signin/public/base/signin_pref_names.cc
  components/signin/public/base/signin_pref_names.h
  third_party/r8/custom_d8.jar
  third_party/r8/custom_r8.jar
)

temporary=
cleanup() {
  if [[ -n "$temporary" && "$temporary" == "$source_root"/.helium-android-input-restore.* ]]; then
    find "$temporary" -maxdepth 0 -type f -delete
  fi
}
trap cleanup EXIT

for relative_path in "${readonly_paths[@]}"; do
  grep -Fxq "$relative_path" "$pruning_list" || {
    echo "Android build input is not declared by the pruning list: $relative_path" >&2
    exit 1
  }
  [[ ! -e "$source_root/$relative_path" && ! -L "$source_root/$relative_path" ]] || {
    echo "Android build input was not pruned before restoration: $relative_path" >&2
    exit 1
  }

  read -r mode object_type expected_blob _ < <(
    git -C "$source_root" ls-tree "$expected_commit" -- "$relative_path"
  )
  [[ "$mode" == 100644 && "$object_type" == blob &&
      "$expected_blob" =~ ^[0-9a-f]{40,64}$ ]] || {
    echo "pinned Chromium input is not a regular blob: $relative_path" >&2
    exit 1
  }

  temporary=$(mktemp "$source_root/.helium-android-input-restore.XXXXXX")
  git -C "$source_root" cat-file blob "$expected_blob" > "$temporary"
  chmod 644 "$temporary"
  mkdir -p "$(dirname "$source_root/$relative_path")"
  mv "$temporary" "$source_root/$relative_path"
  temporary=

  [[ "$(git -C "$source_root" hash-object "$relative_path")" == "$expected_blob" ]] || {
    echo "restored Android build input does not match its pinned blob: $relative_path" >&2
    exit 1
  }
  git -C "$source_root" diff --quiet -- "$relative_path" || {
    echo "restored Android build input differs from pinned Chromium: $relative_path" >&2
    exit 1
  }
  printf 'restored_android_build_input=%s blob=%s\n' \
    "$relative_path" "$expected_blob"
done
