#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
acceptance=${HELIUM_NATIVE_RECOVERY_ACCEPTANCE:-$script_dir/acceptance.mjs}
backup_tool=${HELIUM_PROFILE_BACKUP_TOOL:-$repo_root/scripts/profile-backup/helium-profile-backup.sh}
config=${1:-}
generation=${2:-}

[[ $# -ge 1 && $# -le 2 ]] || {
  echo "usage: native-recovery/backup.sh CONFIG [GENERATION]" >&2
  exit 64
}
config=$(realpath -e -- "$config")
[[ -f "$config" && ! -L "$config" && "$(stat -c %a "$config")" == 600 ]] || {
  echo "native recovery backup config must be a private real file" >&2
  exit 1
}
device_count=$(awk -F= '$1 == "source_device" {count++} END {print count+0}' "$config")
source_count=$(awk -F= '$1 == "source_path" {count++} END {print count+0}' "$config")
device=$(awk -F= '$1 == "source_device" {print $2}' "$config")
source_path=$(awk -F= '$1 == "source_path" {print substr($0,13)}' "$config")
[[ "$device_count" == 1 && "$source_count" == 1 &&
  "$device" =~ ^(d|da)$ &&
  "$source_path" == "/home/d/.local/share/helium-native-recovery/$device/default" &&
  "$(uname -n | cut -d. -f1)" == "$device" ]] || {
  echo "native recovery backup namespace is invalid for this desktop" >&2
  exit 1
}
[[ -d "$source_path" && ! -L "$source_path" &&
  "$(stat -c %a "$source_path")" == 700 ]] || {
  echo "native recovery source directory is invalid" >&2
  exit 1
}
inventory=$(find "$source_path" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[[ "$inventory" == $'.helium-native-recovery-root-v1\ncookies.current.json\npasswords.current.json' ]] || {
  echo "native recovery source inventory is invalid" >&2
  exit 1
}
for kind in passwords cookies; do
  node "$acceptance" verify-snapshot --kind "$kind" --device "$device" \
    --snapshot "$source_path/$kind.current.json" --max-age-seconds 600 \
    >/dev/null
done

if [[ -n "$generation" ]]; then
  exec "$backup_tool" backup "$config" "$generation"
fi
exec "$backup_tool" backup "$config"
