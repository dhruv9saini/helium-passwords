#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
LOCK="$STATE_DIR/controller.lock"
LOG="$STATE_DIR/controller.log"
STATE="$STATE_DIR/session.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
printf 'hibernating\n' >"$STATE"

pkill -f '[a]rch-desktop-resume-root.sh' >/dev/null 2>&1 || true
pkill -f '[s]tart-arch-xmonad-root.sh' >/dev/null 2>&1 || true

lock_waits=0
while ! mkdir "$LOCK" 2>/dev/null; do
  lock_waits=$((lock_waits + 1))
  if [ -s "$LOCK/pid" ]; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if [ -d "/proc/$pid" ] && [ "$lock_waits" -lt 8 ]; then
          sleep 1
          continue
        fi
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        kill -KILL "$pid" >/dev/null 2>&1 || true
        ;;
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
if [ "${ARCH_DESKTOP_THERMAL_GUARD_ALWAYS:-1}" = 0 ]; then
  [ ! -x "$ROOT/arch-desktop-thermal-guard-root.sh" ] || "$ROOT/arch-desktop-thermal-guard-root.sh" stop >>"$LOG" 2>&1 || true
fi

printf 'stopped\n' >"$STATE"
log "hibernate completed"
