#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/magic-keyboard-remap.log"
PID_FILE="$STATE_DIR/magic-keyboard-remap.pid"
BIN="$ROOT/usr/local/bin/android-magic-keyboard-remap"

mkdir -p "$STATE_DIR" 2>/dev/null || true
PATH=/system/bin:/system/xbin:/apex/com.android.runtime/bin:/vendor/bin:/odm/bin:$PATH
export PATH

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

stop_existing() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
  fi
  for pid in $(pidof android-magic-keyboard-remap 2>/dev/null || true); do
    [ "$pid" = "$$" ] || kill "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$PID_FILE"
}

if [ "${1:-start}" = stop ]; then
  stop_existing
  exit 0
fi

[ -x "$BIN" ] || {
  log "missing $BIN"
  exit 0
}

stop_existing
log "starting Magic Keyboard remapper"
nohup "$BIN" >>"$LOG" 2>&1 &
printf '%s\n' "$!" >"$PID_FILE"
