#!/usr/bin/env bash
set -euo pipefail

profile=${HELIUM_CHROOT_PROFILE:-/root/.config/helium-sync}
state_dir=${XDG_STATE_HOME:-/root/.local/state}/helium-sync
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-/root/.local/share/helium-sync}
cookiecloud_config=${HELIUM_COOKIECLOUD_CONFIG:-/root/.local/share/helium-local-sync/cookiecloud-client.json}
cookiecloud_server=${HELIUM_COOKIECLOUD_SERVER:-http://127.0.0.1:8088}
password_server=${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}
cdp=${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}

mkdir -p "$profile" "$state_dir" /dev/shm
chmod 1777 /dev/shm
mkdir -p /tmp/runtime-root
chmod 700 /tmp/runtime-root
export TMPDIR=/tmp
export XDG_RUNTIME_DIR=/tmp/runtime-root

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

existing_pids=$(ps -A -o pid,args |
  awk '/remote-debugging-port=9223/ { print $1 }')
if [ -n "$existing_pids" ]; then
  kill $existing_pids >/dev/null 2>&1 || true
fi

"$browser" \
  --headless=new \
  --user-data-dir="$profile" \
  --no-sandbox \
  --password-store=basic \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9223 \
  about:blank >>"$state_dir/headless-seed.log" 2>&1 &
browser_pid=$!

cleanup() {
  kill "$browser_pid" >/dev/null 2>&1 || true
  wait "$browser_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 30); do
  if curl -fsS "$cdp/json/version" >/tmp/helium-headless-version.json 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ ! -s /tmp/helium-headless-version.json ]; then
  echo "chroot browser CDP did not start" >&2
  exit 1
fi

cat /tmp/helium-headless-version.json

if [ -f "$cookiecloud_config" ]; then
  cdp-cookiecloud download \
    --cdp "$cdp" \
    --server "$cookiecloud_server" \
    --config-file "$cookiecloud_config"
fi

if [ -s "$password_data_dir/token" ]; then
  cdp-password-sync pull \
    --cdp "$cdp" \
    --server "$password_server" \
    --token-file "$password_data_dir/token" \
    --device helium-chroot \
    --state-file "$state_dir/cdp-password-sync-state.json" || true
fi

sqlite3 "file:$profile/Default/Cookies?mode=ro&immutable=1" \
  'select "cookies", count(*) from cookies;' 2>/dev/null || true
sqlite3 "file:$profile/Default/Login Data?mode=ro&immutable=1" \
  'select "logins", count(*) from logins;' 2>/dev/null || true
