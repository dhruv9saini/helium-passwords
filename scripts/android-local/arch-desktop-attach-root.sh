#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
LOCK="$STATE_DIR/controller.lock"
LOG="$STATE_DIR/controller.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [ "${ARCH_DESKTOP_ATTACH_LOCKLESS:-0}" != 1 ]; then
  while ! mkdir "$LOCK" 2>/dev/null; do
    printf '%s attach skipped; controller lock busy\n' "$(date '+%F %T')" >>"$LOG"
    exit 0
  done
  printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
  trap 'release_lock' EXIT
fi

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

release_lock() {
  rm -f "$LOCK/pid" >/dev/null 2>&1 || true
  rmdir "$LOCK" >/dev/null 2>&1 || true
}

log "attach requested"
"$ROOT/arch-desktop-display-mode-root.sh" apply >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/chroot-tailnet-dns-root.sh" ] || "$ROOT/chroot-tailnet-dns-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/fix-magic-keyboard-layout-root.sh" ] || "$ROOT/fix-magic-keyboard-layout-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/input-display-assoc-root.sh" ] || "$ROOT/input-display-assoc-root.sh" apply >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/termux-x11-session-focus-root.sh" ] || "$ROOT/termux-x11-session-focus-root.sh" >>"$LOG" 2>&1 || true

if [ -S "$ROOT/tmp/.X11-unix/X1" ]; then
  /system/bin/chroot "$ROOT" /usr/bin/env DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-root PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin sh -lc \
    'x11-lorie-input-setup >/dev/null 2>&1 || true' >>"$LOG" 2>&1 || true
fi

printf 'running\n' >"$STATE_DIR/session.state"
log "attach completed"
