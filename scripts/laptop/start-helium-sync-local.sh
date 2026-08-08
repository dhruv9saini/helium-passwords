#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PATH="$script_dir:$PATH"

home_dir=${HOME:?HOME is required}
profile=${HELIUM_LAPTOP_PROFILE:-$home_dir/.config/net.imput.helium}
sync_config_dir=$profile/Default/helium-sync
state_dir=${HELIUM_SYNC_STATE_DIR:-$home_dir/.local/state/helium-sync}
services_only=0

if [[ "${1:-}" == "--services-only" ]]; then
  services_only=1
  shift
fi

find_browser() {
  local candidate
  if [[ -n "${HELIUM_BROWSER_BIN:-}" ]]; then
    printf '%s\n' "$HELIUM_BROWSER_BIN"
    return 0
  fi
  for candidate in \
    "$home_dir/.local/opt/helium-sync-app/helium" \
    "$home_dir/.local/opt/helium-sync-app/opt/helium/helium" \
    "$home_dir/.local/opt/helium-app/opt/helium/helium"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v helium >/dev/null 2>&1; then
    command -v helium
    return 0
  fi
  return 1
}

mkdir -p "$state_dir"
if [[ ! -s "$sync_config_dir/token" ||
      ! -s "$sync_config_dir/client.json" ||
      ! -s "$sync_config_dir/base_url" ]]; then
  echo "Helium enrollment is missing or invalid in $sync_config_dir" >&2
  exit 1
fi
base_url=$(tr -d '\r\n' <"$sync_config_dir/base_url")
[[ "$base_url" =~ ^http://100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):44719/?$ &&
    ${BASH_REMATCH[1]} -ge 64 && ${BASH_REMATCH[1]} -le 127 &&
    ${BASH_REMATCH[2]} -le 255 && ${BASH_REMATCH[3]} -le 255 ]] || {
  echo "Helium base_url must be lm's direct Tailnet HTTP endpoint" >&2
  exit 1
}

device_id=$(jq -r '.device_id // empty' "$sync_config_dir/client.json")
case "$device_id" in
  d|da) ;;
  *) echo "Helium desktop enrollment has an invalid device identity" >&2; exit 1 ;;
esac
recovery_root=$home_dir/.local/share/helium-native-recovery/$device_id/default
recovery_marker=$recovery_root/.helium-native-recovery-root-v1
mkdir -p "$recovery_root"
chmod 0700 "$recovery_root"
if [[ ! -e "$recovery_marker" ]]; then
  (umask 077; printf 'helium-native-recovery-root-v1\n' >"$recovery_marker")
fi
[[ -f "$recovery_marker" && ! -L "$recovery_marker" &&
  "$(stat -c %a "$recovery_marker")" == 600 &&
  "$(cat "$recovery_marker")" == helium-native-recovery-root-v1 ]] || {
  echo "Helium native recovery root marker is invalid" >&2
  exit 1
}
if [[ -e "$sync_config_dir/native_recovery_root" ]]; then
  [[ -f "$sync_config_dir/native_recovery_root" &&
    ! -L "$sync_config_dir/native_recovery_root" &&
    "$(tr -d '\r\n' <"$sync_config_dir/native_recovery_root")" == "$recovery_root" ]] || {
    echo "Helium native recovery configuration changed unexpectedly" >&2
    exit 1
  }
else
  (umask 077; printf '%s\n' "$recovery_root" >"$sync_config_dir/native_recovery_root")
fi
chmod 0600 "$sync_config_dir/native_recovery_root"

if [[ "$services_only" -eq 1 ]]; then
  exit 0
fi

browser=$(find_browser) || {
  echo "Helium browser binary not found" >&2
  exit 1
}

exts=()
if [[ "${HELIUM_NO_EXTENSIONS:-}" != "1" ]]; then
  [[ -d "$home_dir/.local/share/helium-extensions/pitch-black-theme" ]] &&
    exts+=("$home_dir/.local/share/helium-extensions/pitch-black-theme")
fi

browser_args=(
  "$browser"
  "--user-data-dir=$profile"
  "--no-first-run"
  "--no-default-browser-check"
)
if [[ ${#exts[@]} -gt 0 ]]; then
  ext_list=$(IFS=,; printf '%s' "${exts[*]}")
  browser_args+=("--load-extension=$ext_list")
fi

exec "${browser_args[@]}" "$@"
