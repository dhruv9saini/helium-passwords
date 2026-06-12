#!/usr/bin/env bash
set -euo pipefail

home_dir=${HOME:-/root}
profile=${HELIUM_CHROOT_PROFILE:-$home_dir/.config/helium-passwords}
state_dir=${XDG_STATE_HOME:-$home_dir/.local/state}/helium-sync
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-$home_dir/.local/share/helium-sync}
cookiecloud_config=${HELIUM_COOKIECLOUD_CONFIG:-$home_dir/.local/share/helium-local-sync/cookiecloud-client.json}
cookiecloud_server=${HELIUM_COOKIECLOUD_SERVER:-http://127.0.0.1:8088}
password_server=${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}
cdp=${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}

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

mkdir -p "$profile" "$state_dir" /dev/shm
cleanup_stale_chromium_singletons
sync_config_dir=$profile/Default/helium-sync
mkdir -p "$sync_config_dir"
if [ -s "$password_data_dir/token" ]; then
  cp "$password_data_dir/token" "$sync_config_dir/token"
  printf '%s\n' "$password_server" >"$sync_config_dir/base_url"
  printf '%s\n' "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" >"$sync_config_dir/device_name"
  chmod 600 "$sync_config_dir/token" "$sync_config_dir/base_url" "$sync_config_dir/device_name"
fi
chmod 1777 /dev/shm 2>/dev/null || true
mkdir -p "$home_dir/.local/share/pki/nssdb"
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
  cdp_password_sync=true
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
  --disable-gpu-sandbox \
  --in-process-gpu \
  --disable-dev-shm-usage \
  --no-zygote \
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

if [ "$cdp_password_sync" = true ] && [ -s "$password_data_dir/token" ]; then
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
