#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/display-watch.log"
DISPLAY_MODE="$ROOT/arch-desktop-display-mode-root.sh"
START_X11="$ROOT/start-arch-xmonad-root.sh"
STOP_X11="$ROOT/stop-arch-x11-root.sh"
SESSION_WATCH="$ROOT/arch-desktop-session-watch.sh"
INTERVAL=${ARCH_DESKTOP_DISPLAY_WATCH_INTERVAL:-30}

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

fingerprint() {
  "$DISPLAY_MODE" fingerprint 2>/dev/null || printf 'unknown 0 reset reset unknown\n'
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

while :; do
  sleep "$INTERVAL"
  current=$(fingerprint)
  [ "$current" = "$last" ] && continue

  restart_x11_for_display "$last" "$current"
  last=$(fingerprint)
done
