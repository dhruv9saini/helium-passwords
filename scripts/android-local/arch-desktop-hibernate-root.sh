#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
LOCK="$STATE_DIR/controller.lock"
LOG="$STATE_DIR/controller.log"
STATE="$STATE_DIR/session.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

while ! mkdir "$LOCK" 2>/dev/null; do
  sleep 1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

log "hibernate requested"
printf 'hibernating\n' >"$STATE"

pkill -f '[a]rch-desktop-display-watch-root.sh' >/dev/null 2>&1 || true
pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true

"$ROOT/stop-arch-x11-root.sh" >>"$LOG" 2>&1 || true
"$ROOT/arch-desktop-display-mode-root.sh" reset >>"$LOG" 2>&1 || true

printf 'stopped\n' >"$STATE"
log "hibernate completed"
