#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
core_root="$repo_root/helium-chromium"
password_root="$repo_root/patches"
sync_root="$repo_root/chromium/patches"
lock_file="$repo_root/chromium/android-build.lock"
# shellcheck source=../../chromium/android-build.lock
. "$lock_file"

temporary_resource_tree=
cleanup() {
  if [[ -n "$temporary_resource_tree" && "$temporary_resource_tree" == /tmp/helium-android-resources.* ]]; then
    find "$temporary_resource_tree" -depth -delete
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: $0 <plan|apply> [CHROMIUM_SRC]" >&2
}

read_series() {
  local series_file=$1
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry=${entry%$'\r'}
    case "$entry" in
      ""|\#*) continue ;;
      /*|*../*)
        echo "unsafe patch series entry: $entry" >&2
        exit 1
        ;;
    esac
    printf '%s\n' "$entry"
  done < "$series_file"
}

validate_backbone() {
  "$repo_root/scripts/chromium/validate-android-build-lock.sh" >/dev/null
  [[ "$HELIUM_ANDROID_CHROMIUM_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Android Chromium lock is not an immutable SHA-1" >&2
    exit 1
  }
  [[ "$HELIUM_ANDROID_CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Android Helium core lock is not an immutable SHA-1" >&2
    exit 1
  }
  [[ "$(tr -d '\r\n' < "$core_root/chromium_version.txt")" == "$HELIUM_ANDROID_CHROMIUM_VERSION" ]] || {
    echo "Helium core Chromium version does not match android-build.lock" >&2
    exit 1
  }
  [[ "$(git -C "$core_root" rev-parse HEAD)" == "$HELIUM_ANDROID_CORE_COMMIT" ]] || {
    echo "Helium core commit does not match android-build.lock" >&2
    exit 1
  }
}

emit_plan() {
  local entry
  while IFS= read -r entry; do
    [[ "$entry" == "helium/hop/disable-password-manager.patch" ]] && continue
    printf 'core\t%s\n' "$entry"
  done < <(read_series "$core_root/patches/series")
  while IFS= read -r entry; do
    printf 'passwords\t%s\n' "$entry"
  done < <(read_series "$password_root/series")
  while IFS= read -r patch_file; do
    printf 'sync\t%s\n' "$(basename "$patch_file")"
  done < <(find "$sync_root" -maxdepth 1 -type f -name '*.patch' | sort)
}

apply_series() {
  local layer=$1
  local patch_root=$2
  local source_tree=$3
  local entry patch_file
  while IFS= read -r entry; do
    if [[ "$layer" == core && "$entry" == "helium/hop/disable-password-manager.patch" ]]; then
      continue
    fi
    patch_file="$patch_root/$entry"
    [[ -f "$patch_file" ]] || {
      echo "missing $layer patch: $patch_file" >&2
      exit 1
    }
    printf 'Applying %s patch: %s\n' "$layer" "$entry"
    patch -p1 --ignore-whitespace --forward --fuzz=0 \
      --no-backup-if-mismatch -i "$patch_file" -d "$source_tree"
  done < <(read_series "$patch_root/series")
}

apply_transforms() {
  local source_tree=$1
  temporary_resource_tree=$(mktemp -d /tmp/helium-android-resources.XXXXXX)

  "$core_root/utils/domain_substitution.py" apply \
    -r "$core_root/domain_regex.list" \
    -f "$core_root/domain_substitution.list" \
    "$source_tree"
  "$core_root/utils/name_substitution.py" --sub -t "$source_tree" --workers 2
  "$core_root/utils/i18n_apply.py" -t "$source_tree"
  "$core_root/utils/helium_version.py" \
    --tree "$core_root" --chromium-tree "$source_tree"

  cp -a "$core_root/resources/." "$temporary_resource_tree/"
  "$core_root/utils/generate_resources.py" \
    "$temporary_resource_tree/generate_resources.txt" "$temporary_resource_tree"
  "$core_root/utils/replace_resources.py" \
    "$temporary_resource_tree/helium_resources.txt" "$temporary_resource_tree" "$source_tree"
}

apply_backbone() {
  local source_tree=$1
  [[ -d "$source_tree/.git" && -f "$source_tree/OWNERS" ]] || {
    echo "not a Chromium source checkout: $source_tree" >&2
    exit 1
  }
  [[ "$(git -C "$source_tree" rev-parse HEAD)" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
    echo "Chromium source commit does not match android-build.lock" >&2
    exit 1
  }
  command -v patch >/dev/null

  "$core_root/utils/prune_binaries.py" --keep-contingent-paths \
    "$source_tree" "$core_root/pruning.list"
  "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
    "$source_tree" "$HELIUM_ANDROID_CHROMIUM_COMMIT" "$core_root/pruning.list"
  apply_series core "$core_root/patches" "$source_tree"
  "$repo_root/scripts/chromium/apply-git-series.sh" \
    "$password_root/series" "$password_root" "$source_tree"
  "$repo_root/scripts/chromium/apply-patches.sh" "$source_tree"
  apply_transforms "$source_tree"
  "$repo_root/scripts/chromium/validate-android-java-pref-inputs.sh" \
    "$source_tree" "$HELIUM_ANDROID_CHROMIUM_COMMIT"
  "$repo_root/scripts/chromium/validate-android-pruned-service-consumers.sh" \
    "$source_tree"
}

command=${1:-}
case "$command" in
  plan)
    [[ $# -eq 1 ]] || { usage; exit 64; }
    validate_backbone
    emit_plan
    ;;
  apply)
    [[ $# -eq 2 ]] || { usage; exit 64; }
    validate_backbone
    apply_backbone "$(cd "$2" && pwd)"
    ;;
  *)
    usage
    exit 64
    ;;
esac
