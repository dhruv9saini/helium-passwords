#!/usr/bin/env bash
set -euo pipefail

start-helium-local-sync

profile=${HELIUM_LOCAL_CHROMIUM_PROFILE:-/root/.config/helium-sync}
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-/root/.local/share/helium-sync}
sync_config_dir=$profile/Default/helium-sync
mkdir -p "$profile"
mkdir -p "$sync_config_dir"
cp "$password_data_dir/token" "$sync_config_dir/token"
printf '%s\n' "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" >"$sync_config_dir/base_url"
printf '%s\n' "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" >"$sync_config_dir/device_name"
chmod 600 "$sync_config_dir/token" "$sync_config_dir/base_url" "$sync_config_dir/device_name"
mkdir -p /dev/shm
chmod 1777 /dev/shm

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

mkdir -p /root/.local/state/helium-sync

if [ "$cdp_password_sync" = true ] && command -v cdp-password-sync >/dev/null 2>&1; then
  cdp-password-sync daemon \
    --cdp "${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}" \
    --server "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" \
    --token-file "$password_data_dir/token" \
    --device "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" \
    --state-file /root/.local/state/helium-sync/cdp-password-sync-state.json \
    >>/root/.local/state/helium-sync/cdp-password-sync.log 2>&1 &
  pids="$pids $!"
fi

cookiecloud_config=${HELIUM_COOKIECLOUD_CONFIG:-/root/.local/share/helium-local-sync/cookiecloud-client.json}
if command -v cdp-cookiecloud >/dev/null 2>&1 && [ -f "$cookiecloud_config" ]; then
  cdp-cookiecloud daemon \
    --android-cdp "${HELIUM_ANDROID_CDP_URL:-http://127.0.0.1:9222}" \
    --chroot-cdp "${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}" \
    --server "${HELIUM_COOKIECLOUD_SERVER:-http://127.0.0.1:8088}" \
    --config-file "$cookiecloud_config" \
    >>/root/.local/state/helium-sync/cdp-cookiecloud.log 2>&1 &
  pids="$pids $!"
fi

"$browser" \
  --user-data-dir="$profile" \
  --no-sandbox \
  --password-store=basic \
  --remote-debugging-port=9223 \
  --load-extension=/root/.local/share/cookiecloud-extension/chrome-mv3 \
  "$@"
status=$?
exit "$status"
