#!/usr/bin/env bash
set -euo pipefail

home_dir=${HOME:-/root}
profile=${HELIUM_LOCAL_CHROMIUM_PROFILE:-$home_dir/.config/helium-passwords}
sync_config_dir=$profile/Default/helium-sync
state_dir=${HELIUM_SYNC_STATE_DIR:-$home_dir/.local/state/helium-sync}
mkdir -p "$state_dir"

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
if [ ! -s "$sync_config_dir/token" ] ||
  [ ! -s "$sync_config_dir/client.json" ] ||
  [ ! -s "$sync_config_dir/base_url" ] ||
  ! grep -Eq '^https://[^[:space:]]+$' "$sync_config_dir/base_url"; then
  echo "Helium enrollment is missing or invalid in $sync_config_dir" >&2
  exit 1
fi

mkdir -p /dev/shm
chmod 1777 /dev/shm 2>/dev/null || true
mkdir -p "$home_dir/.local/share/pki/nssdb"
runtime_dir=${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
export TMPDIR=/tmp
export XDG_RUNTIME_DIR=$runtime_dir

browser=/usr/local/bin/helium
[ -x "$browser" ] && [ -x /opt/helium-sync/helium ] || {
  echo "The built Helium Sync browser is not installed in the chroot" >&2
  exit 1
}
pids=
cleanup() {
  for pid in $pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

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

profile_extension_path() {
  local extension_id=$1
  local extension_base=$profile/Default/Extensions/$extension_id
  [ -d "$extension_base" ] || return 0
  find "$extension_base" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1
}

patch_dark_reader_startup_tab() {
  local extension_base extension_path background_file patched

  extension_base=$profile/Default/Extensions/eimadpbcbfnmbkopoojfekhnkhdbieeh
  [ -d "$extension_base" ] || return 0
  patched=0

  while IFS= read -r extension_path; do
    background_file=$extension_path/background/index.js
    [ -f "$background_file" ] || continue

    if grep -Fq 'chrome.tabs.create({url: getHelpURL()});' "$background_file"; then
      cp -n "$background_file" "$background_file.helium-pre-startup-tab-patch" 2>/dev/null || true
      sed -i 's#chrome\.tabs\.create({url: getHelpURL()});#return; // Helium chroot: suppress Dark Reader install help tab.#' "$background_file"
    fi
    if grep -Fq 'Helium chroot: suppress Dark Reader install help tab' "$background_file"; then
      patched=1
    fi
  done < <(find "$extension_base" -mindepth 1 -maxdepth 1 -type d | sort -V)

  if [ "$patched" = 1 ]; then
    rm -rf "$profile/Default/Service Worker/ScriptCache" "$profile/Default/Code Cache/js"
  fi
}

patch_dark_reader_startup_tab

add_extension_path "$home_dir/.local/share/google-ai-overview-blocker"
add_extension_path "$home_dir/.local/share/blank-new-tab-extension"
add_extension_path "$home_dir/.local/share/tab-pin-helper-extension"
for extension_id in \
  eimadpbcbfnmbkopoojfekhnkhdbieeh \
  mmcgnaachjapbbchcpjihhgjhpfcnoan \
  bimiahgcjenkoacmdfggckkaflnnebki; do
  extension_path=$(profile_extension_path "$extension_id" || true)
  [ -z "$extension_path" ] || add_extension_path "$extension_path"
done
browser_args=()
if [ -n "$extension_paths" ]; then
  browser_args+=(--load-extension="$extension_paths")
fi

"$browser" \
  --user-data-dir="$profile" \
  --no-first-run \
  --no-default-browser-check \
  --disable-search-engine-choice-screen \
  --no-sandbox \
  --disable-gpu-sandbox \
  --in-process-gpu \
  --disable-dev-shm-usage \
  --no-zygote \
  --password-store=basic \
  --extension-mime-request-handling=always-prompt-for-install \
  "${browser_args[@]}" \
  "$@"
status=$?
exit "$status"
