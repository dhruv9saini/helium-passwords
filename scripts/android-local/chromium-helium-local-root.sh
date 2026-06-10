#!/usr/bin/env bash
set -euo pipefail

start-helium-local-sync

home_dir=${HOME:-/root}
profile=${HELIUM_LOCAL_CHROMIUM_PROFILE:-$home_dir/.config/helium-passwords}
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-$home_dir/.local/share/helium-sync}
sync_config_dir=$profile/Default/helium-sync

cleanup_stale_chromium_singletons() {
  local lock_target lock_pid

  lock_target=$(readlink "$profile/SingletonLock" 2>/dev/null || true)
  [ -n "$lock_target" ] || return 0
  lock_pid=${lock_target##*-}
  case "$lock_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if ! ps -p "$lock_pid" >/dev/null 2>&1; then
    rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie"
  fi
}

mkdir -p "$profile"
cleanup_stale_chromium_singletons
mkdir -p "$sync_config_dir"
cp "$password_data_dir/token" "$sync_config_dir/token"
printf '%s\n' "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" >"$sync_config_dir/base_url"
printf '%s\n' "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" >"$sync_config_dir/device_name"
chmod 600 "$sync_config_dir/token" "$sync_config_dir/base_url" "$sync_config_dir/device_name"
mkdir -p /dev/shm
chmod 1777 /dev/shm
runtime_dir=${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
export TMPDIR=/tmp
export XDG_RUNTIME_DIR=$runtime_dir

browser=${HELIUM_CHROOT_BROWSER:-}
if [ -z "$browser" ]; then
  if command -v helium >/dev/null 2>&1; then
    browser=helium
  elif command -v chromium >/dev/null 2>&1; then
    browser=chromium
  else
    echo "Neither helium nor chromium is installed in the chroot" >&2
    exit 1
  fi
fi
browser_name=$(basename "$browser")
cdp_password_sync=${HELIUM_CHROOT_CDP_PASSWORD_SYNC:-auto}
if [ "$cdp_password_sync" = auto ]; then
  if [ "$browser_name" = helium ]; then
    cdp_password_sync=false
  else
    cdp_password_sync=true
  fi
fi

pids=
cleanup() {
  for pid in $pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

state_dir=${HELIUM_SYNC_STATE_DIR:-$home_dir/.local/state/helium-sync}
mkdir -p "$state_dir"

if [ "$cdp_password_sync" = true ] && command -v cdp-password-sync >/dev/null 2>&1; then
  cdp-password-sync daemon \
    --cdp "${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}" \
    --server "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" \
    --token-file "$password_data_dir/token" \
    --device "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" \
    --state-file "$state_dir/cdp-password-sync-state.json" \
    >>"$state_dir/cdp-password-sync.log" 2>&1 &
  pids="$pids $!"
fi

cookiecloud_config=${HELIUM_COOKIECLOUD_CONFIG:-$home_dir/.local/share/helium-local-sync/cookiecloud-client.json}
if command -v cdp-cookiecloud >/dev/null 2>&1 && [ -f "$cookiecloud_config" ]; then
  cdp-cookiecloud daemon \
    --android-cdp "${HELIUM_ANDROID_CDP_URL:-http://127.0.0.1:9222}" \
    --chroot-cdp "${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}" \
    --server "${HELIUM_COOKIECLOUD_SERVER:-http://127.0.0.1:8088}" \
    --config-file "$cookiecloud_config" \
    >>"$state_dir/cdp-cookiecloud.log" 2>&1 &
  pids="$pids $!"
fi

extension_paths=
cookiecloud_extension=$home_dir/.local/share/cookiecloud-extension/chrome-mv3
if [ -d "$cookiecloud_extension" ]; then
  extension_paths=$cookiecloud_extension
fi
ai_overview_extension=$home_dir/.local/share/google-ai-overview-blocker
if [ -d "$ai_overview_extension" ]; then
  if [ -n "$extension_paths" ]; then
    extension_paths="$extension_paths,$ai_overview_extension"
  else
    extension_paths=$ai_overview_extension
  fi
fi

browser_args=()
if [ -n "$extension_paths" ]; then
  browser_args+=(--load-extension="$extension_paths")
fi

"$browser" \
  --user-data-dir="$profile" \
  --no-sandbox \
  --password-store=basic \
  --remote-debugging-port=9223 \
  "${browser_args[@]}" \
  "$@"
status=$?
exit "$status"
