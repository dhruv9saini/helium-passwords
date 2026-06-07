#!/usr/bin/env bash
set -euo pipefail

data_dir=${HELIUM_LOCAL_SYNC_DATA:-/root/.local/share/helium-local-sync}
password_data_dir=${HELIUM_PASSWORD_SYNC_DATA:-/root/.local/share/helium-sync}
log_dir=${XDG_STATE_HOME:-/root/.local/state}/helium-local-sync
mkdir -p "$data_dir" "$password_data_dir" "$log_dir"

ensure_secret() {
  path=$1
  bytes=$2
  if [ -s "$path" ]; then
    return 0
  fi
  umask 077
  head -c "$bytes" /dev/urandom | base64 >"$path"
}

ensure_secret "$password_data_dir/passphrase" 32
ensure_secret "$password_data_dir/token" 32

if pgrep -f 'helium-local-syncd.*127.0.0.1:8088' >/dev/null 2>&1; then
  syncd_running=1
else
  syncd_running=0
fi

if [ "$syncd_running" -eq 0 ]; then
  nohup helium-local-syncd \
    -listen 127.0.0.1:8088 \
    -data-dir "$data_dir" \
    >>"$log_dir/syncd.log" 2>&1 &
fi

if ! pgrep -f 'helium-syncd.*127.0.0.1:44719' >/dev/null 2>&1; then
  nohup helium-syncd \
    -listen 127.0.0.1:44719 \
    -data-dir "$password_data_dir" \
    -passphrase-file "$password_data_dir/passphrase" \
    -token-file "$password_data_dir/token" \
    >>"$log_dir/password-syncd.log" 2>&1 &
fi

if command -v socat >/dev/null 2>&1 && ! pgrep -f 'socat.*127.0.0.1:9222.*chrome_devtools_remote' >/dev/null 2>&1; then
  nohup socat TCP-LISTEN:9222,bind=127.0.0.1,reuseaddr,fork ABSTRACT-CONNECT:chrome_devtools_remote \
    >>"$log_dir/android-cdp-bridge.log" 2>&1 &
fi
