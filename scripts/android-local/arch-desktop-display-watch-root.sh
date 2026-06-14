#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/display-watch.log"
DISPLAY_MODE="$ROOT/arch-desktop-display-mode-root.sh"
START_X11="$ROOT/start-arch-xmonad-root.sh"
STOP_X11="$ROOT/stop-arch-x11-root.sh"
SESSION_WATCH="$ROOT/arch-desktop-session-watch.sh"
FOCUS_X11="$ROOT/termux-x11-session-focus-root.sh"
INTERVAL=${ARCH_DESKTOP_DISPLAY_WATCH_INTERVAL:-30}

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

fingerprint() {
  "$DISPLAY_MODE" fingerprint 2>/dev/null || printf 'unknown 0 reset reset unknown\n'
}

target_env_record() {
  target_file="$STATE_DIR/android-display-target.env"
  if [ ! -f "$target_file" ]; then
    printf 'missing 0 reset reset unknown native\n'
    return 0
  fi

  target_source=missing
  target_display_id=0
  target_size=reset
  target_density=reset
  target_x11_resolution=unknown
  target_android_display_mode=native
  # shellcheck disable=SC1090
  . "$target_file" 2>/dev/null || true
  printf '%s %s %s %s %s %s\n' \
    "${target_source:-missing}" \
    "${target_display_id:-0}" \
    "${target_size:-reset}" \
    "${target_density:-reset}" \
    "${target_x11_resolution:-unknown}" \
    "${target_android_display_mode:-native}"
}

session_running() {
  [ "$(cat "$STATE_DIR/session.state" 2>/dev/null || true)" = running ]
}

termux_x11_activity_visible() {
  dumpsys activity activities 2>/dev/null |
    grep -Eq 'topResumedActivity=.*com[.]termux[.]x11/[.]MainActivity|Resumed: ActivityRecord[{].* com[.]termux[.]x11/[.]MainActivity|windows=[[]Window[{].*com[.]termux[.]x11/com[.]termux[.]x11[.]MainActivity'
}

restart_session_watch() {
  [ -x "$SESSION_WATCH" ] || return 0
  pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true
  nohup "$SESSION_WATCH" >>"$STATE_DIR/controller.log" 2>&1 &
}

ensure_termux_preferences() {
  session_running || return 0
  [ -x "$FOCUS_X11" ] || return 0
  "$FOCUS_X11" prefs >>"$LOG" 2>&1 || true
}

ensure_target_env_current() {
  current=$1
  saved=$(target_env_record)
  [ "$saved" = "$current" ] && return 0

  log "display target env stale: $saved -> $current"
  "$DISPLAY_MODE" apply >>"$LOG" 2>&1 || true
}

restart_x11_for_display() {
  old=$1
  new=$2

  log "display target changed: $old -> $new"

  if ! session_running || ! termux_x11_activity_visible; then
    log "Termux:X11 is not visible; hibernating instead of reopening"
    "$ROOT/arch-desktop-hibernate-root.sh" >>"$LOG" 2>&1 || true
    exit 0
  fi

  pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true
  "$DISPLAY_MODE" apply >>"$LOG" 2>&1 || true
  "$STOP_X11" >>"$LOG" 2>&1 || true
  ARCH_X11_OPEN_ACTIVITY=1 "$START_X11" >>"$LOG" 2>&1 || true
  restart_session_watch
  log "display target restart completed"
}

last=$(fingerprint)
log "display watcher started: $last"
ensure_target_env_current "$last"
last=$(fingerprint)
ensure_termux_preferences

while :; do
  sleep "$INTERVAL"
  current=$(fingerprint)
  if [ "$current" = "$last" ]; then
    ensure_target_env_current "$current"
    ensure_termux_preferences
    continue
  fi

  restart_x11_for_display "$last" "$current"
  last=$(fingerprint)
  ensure_target_env_current "$last"
  ensure_termux_preferences
done
