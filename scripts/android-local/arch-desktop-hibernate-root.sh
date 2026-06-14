#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
LOCK="$STATE_DIR/controller.lock"
LOG="$STATE_DIR/controller.log"
STATE="$STATE_DIR/session.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
printf 'hibernating\n' >"$STATE"

while ! mkdir "$LOCK" 2>/dev/null; do
  if [ -s "$LOCK/pid" ]; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) [ -d "/proc/$pid" ] && { sleep 1; continue; } ;;
    esac
  fi
  rm -f "$LOCK/pid" >/dev/null 2>&1 || true
  rmdir "$LOCK" >/dev/null 2>&1 || true
  sleep 1
done
printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
trap 'rm -f "$LOCK/pid" >/dev/null 2>&1 || true; rmdir "$LOCK" 2>/dev/null || true' EXIT

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

log "hibernate requested"

pkill -f '[a]rch-desktop-display-watch-root.sh' >/dev/null 2>&1 || true
pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true

"$ROOT/stop-arch-x11-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/input-display-assoc-root.sh" ] || "$ROOT/input-display-assoc-root.sh" clear >>"$LOG" 2>&1 || true
"$ROOT/arch-desktop-display-mode-root.sh" reset >>"$LOG" 2>&1 || true

printf 'stopped\n' >"$STATE"
log "hibernate completed"
