#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PATH="$script_dir:$PATH"

home_dir=${HOME:?HOME is required}
profile=${HELIUM_LAPTOP_PROFILE:-$home_dir/.config/net.imput.helium}
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-$home_dir/.local/share/helium-sync}
local_data_dir=${HELIUM_LOCAL_SYNC_DATA:-$home_dir/.local/share/helium-local-sync}
sync_config_dir=$profile/Default/helium-sync
state_dir=${HELIUM_SYNC_STATE_DIR:-$home_dir/.local/state/helium-sync}
cookiecloud_config=${HELIUM_COOKIECLOUD_CONFIG:-$local_data_dir/cookiecloud-client.json}
password_listen=${HELIUM_PASSWORD_SYNC_LISTEN:-127.0.0.1:44719}
password_base_url=${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}
cookiecloud_listen=${HELIUM_COOKIECLOUD_LISTEN:-127.0.0.1:8088}
cookiecloud_server=${HELIUM_COOKIECLOUD_SERVER:-http://127.0.0.1:8088}
cdp_port=${HELIUM_LAPTOP_CDP_PORT:-9224}
cdp_url=${HELIUM_LAPTOP_CDP_URL:-http://127.0.0.1:$cdp_port}
device_name=${HELIUM_SYNC_DEVICE_NAME:-helium-laptop}
services_only=0

if [[ "${1:-}" == "--services-only" ]]; then
  services_only=1
  shift
fi

ensure_secret() {
  local path=$1
  local bytes=$2
  if [[ -s "$path" ]]; then
    return 0
  fi
  umask 077
  mkdir -p "$(dirname "$path")"
  head -c "$bytes" /dev/urandom | base64 >"$path"
}

start_daemon_if_needed() {
  local health_url=$1
  local log_file=$2
  shift 2

  if command -v curl >/dev/null 2>&1 &&
    curl -fsS --max-time 1 "$health_url" >/dev/null 2>&1; then
    return 0
  fi
  nohup "$@" >>"$log_file" 2>&1 &
}

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

mkdir -p "$password_data_dir" "$local_data_dir" "$sync_config_dir" "$state_dir"
ensure_secret "$password_data_dir/passphrase" 32
ensure_secret "$password_data_dir/token" 32
cp "$password_data_dir/token" "$sync_config_dir/token"
printf '%s\n' "$password_base_url" >"$sync_config_dir/base_url"
printf '%s\n' "$device_name" >"$sync_config_dir/device_name"
chmod 600 "$sync_config_dir/token" "$sync_config_dir/base_url" "$sync_config_dir/device_name"

start_daemon_if_needed "$cookiecloud_server/health" "$state_dir/helium-local-syncd.log" \
  helium-local-syncd -listen "$cookiecloud_listen" -data-dir "$local_data_dir"
start_daemon_if_needed "$password_base_url/v1/health" "$state_dir/helium-syncd.log" \
  helium-syncd -listen "$password_listen" -data-dir "$password_data_dir" \
    -passphrase-file "$password_data_dir/passphrase" \
    -token-file "$password_data_dir/token"

if [[ -f "$cookiecloud_config" ]] && command -v cdp-cookiecloud >/dev/null 2>&1; then
  if ! pgrep -f "[c]dp-cookiecloud.*--targets.*$cdp_port" >/dev/null 2>&1; then
    nohup cdp-cookiecloud daemon \
      --targets "$device_name=$cdp_url" \
      --server "$cookiecloud_server" \
      --config-file "$cookiecloud_config" \
      >>"$state_dir/cdp-cookiecloud-laptop.log" 2>&1 &
  fi
fi

if [[ "$services_only" -eq 1 ]]; then
  exit 0
fi

browser=$(find_browser) || {
  echo "Helium browser binary not found" >&2
  exit 1
}

exts=()
if [[ "${HELIUM_NO_EXTENSIONS:-}" != "1" ]]; then
  [[ -d "$home_dir/.local/share/browserpass/extension-pjmbgaakjkbhpopmakjoedenlfdmcdgm" ]] &&
    exts+=("$home_dir/.local/share/browserpass/extension-pjmbgaakjkbhpopmakjoedenlfdmcdgm")
  [[ -d "$home_dir/.local/share/helium-extensions/pitch-black-theme" ]] &&
    exts+=("$home_dir/.local/share/helium-extensions/pitch-black-theme")
  [[ -d "$home_dir/.local/share/helium-extensions/tab-sync" ]] &&
    exts+=("$home_dir/.local/share/helium-extensions/tab-sync")
fi

browser_args=(
  "$browser"
  "--user-data-dir=$profile"
  "--no-first-run"
  "--no-default-browser-check"
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=$cdp_port"
)
if [[ ${#exts[@]} -gt 0 ]]; then
  ext_list=$(IFS=,; printf '%s' "${exts[*]}")
  browser_args+=("--load-extension=$ext_list")
fi

exec "${browser_args[@]}" "$@"
