#!/usr/bin/env bash
set -euo pipefail

home_dir=${HOME:-/root}
profile=${HELIUM_LOCAL_CHROMIUM_PROFILE:-$home_dir/.config/helium-passwords}
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-$home_dir/.local/share/helium-sync}
sync_config_dir=$profile/Default/helium-sync
state_dir=${HELIUM_SYNC_STATE_DIR:-$home_dir/.local/state/helium-sync}
mkdir -p "$state_dir" "$password_data_dir"

ensure_secret() {
  local path=$1
  local bytes=$2
  if [ -s "$path" ]; then
    return 0
  fi
  umask 077
  head -c "$bytes" /dev/urandom | base64 >"$path"
}

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
ensure_secret "$password_data_dir/passphrase" 32
ensure_secret "$password_data_dir/token" 32
mkdir -p "$sync_config_dir"
cp "$password_data_dir/token" "$sync_config_dir/token"
printf '%s\n' "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" >"$sync_config_dir/base_url"
printf '%s\n' "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" >"$sync_config_dir/device_name"
chmod 600 "$sync_config_dir/token" "$sync_config_dir/base_url" "$sync_config_dir/device_name"

if [ "${HELIUM_START_LOCAL_SYNC:-1}" = 1 ]; then
  start-helium-local-sync >>"$state_dir/start-helium-local-sync.log" 2>&1 &
fi

profile_prepare=${HELIUM_PROFILE_PREPARE:-$home_dir/.config/x11/bin/helium-prepare-profile}
if [ -x "$profile_prepare" ] &&
  { [ "${HELIUM_PROFILE_PREPARE_ON_LAUNCH:-0}" = 1 ] ||
    [ ! -f "$profile/Default/Preferences" ] ||
    [ ! -f "$profile/Local State" ]; }; then
  "$profile_prepare" "$profile" >>"$state_dir/profile-prepare.log" 2>&1 || true
fi

mkdir -p /dev/shm
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
  cdp_password_sync=once
elif [ "$cdp_password_sync" = true ]; then
  cdp_password_sync=once
fi

pids=
cleanup() {
  for pid in $pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

start_password_sync_once() {
  (
    cdp_url=${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}
    for _ in $(seq 1 30); do
      if curl -fsS --max-time 1 "$cdp_url/json/version" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    cdp-password-sync once \
      --cdp "$cdp_url" \
      --server "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" \
      --token-file "$password_data_dir/token" \
      --device "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" \
      --state-file "$state_dir/cdp-password-sync-state.json"
  ) >>"$state_dir/cdp-password-sync.log" 2>&1 &
  pids="$pids $!"
}

if [ "$cdp_password_sync" = daemon ] && command -v cdp-password-sync >/dev/null 2>&1; then
  cdp-password-sync daemon \
    --cdp "${HELIUM_CHROOT_CDP_URL:-http://127.0.0.1:9223}" \
    --server "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" \
    --token-file "$password_data_dir/token" \
    --device "${HELIUM_SYNC_DEVICE_NAME:-helium-chroot}" \
    --state-file "$state_dir/cdp-password-sync-state.json" \
    >>"$state_dir/cdp-password-sync.log" 2>&1 &
  pids="$pids $!"
elif [ "$cdp_password_sync" = once ] && command -v cdp-password-sync >/dev/null 2>&1; then
  start_password_sync_once
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
blocked_extension_ids=${HELIUM_BLOCKED_EXTENSION_IDS:-eakpippijmmohmdlpgcjnipolcgciaga}
is_blocked_extension_path() {
  local extension_path=$1
  local extension_id
  for extension_id in $blocked_extension_ids; do
    case "$extension_path" in
      */Default/Extensions/"$extension_id"|*/Default/Extensions/"$extension_id"/*|*/Extensions/"$extension_id"|*/Extensions/"$extension_id"/*|*/"$extension_id"|*/"$extension_id"/*)
        return 0
        ;;
    esac
  done
  if [ -f "$extension_path/manifest.json" ] &&
    grep -qi 'Pangram' "$extension_path/manifest.json" "$extension_path"/_locales/*/messages.json 2>/dev/null; then
    return 0
  fi
  return 1
}

add_extension_path() {
  local extension_path=$1
  [ -d "$extension_path" ] || return 0
  is_blocked_extension_path "$extension_path" && return 0
  if [ -n "$extension_paths" ]; then
    extension_paths="$extension_paths,$extension_path"
  else
    extension_paths=$extension_path
  fi
}

add_extension_path "$home_dir/.local/share/cookiecloud-extension/chrome-mv3"
add_extension_path "$home_dir/.local/share/google-ai-overview-blocker"
add_extension_path "$home_dir/.local/share/blank-new-tab-extension"
add_extension_path "$home_dir/.local/share/tab-pin-helper-extension"
for extension_path in "$profile"/Default/Extensions/*/*; do
  add_extension_path "$extension_path"
done
for extension_path in "$home_dir"/.local/share/browserpass/extension-* "$home_dir"/.local/share/helium-extensions/*; do
  add_extension_path "$extension_path"
done

cleanup_startup_tabs=${HELIUM_CLEANUP_STARTUP_TABS:-$home_dir/.config/x11/bin/helium-cleanup-startup-tabs}
if [ -x "$cleanup_startup_tabs" ]; then
  (
    sleep 5
    "$cleanup_startup_tabs" >>"$state_dir/cleanup-startup-tabs.log" 2>&1 || true
  ) &
  pids="$pids $!"
fi

browser_args=()
if [ -n "$extension_paths" ]; then
  browser_args+=(--load-extension="$extension_paths")
fi

"$browser" \
  --user-data-dir="$profile" \
  --no-sandbox \
  --disable-gpu-sandbox \
  --in-process-gpu \
  --disable-dev-shm-usage \
  --no-zygote \
  --password-store=basic \
  --remote-debugging-port=9223 \
  "${browser_args[@]}" \
  "$@"
status=$?
exit "$status"
