#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
LOCK="$STATE_DIR/controller.lock"
LOG="$STATE_DIR/controller.log"
STATE="$STATE_DIR/session.state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

state_is_busy() {
  case "$(cat "$STATE" 2>/dev/null || true)" in
    hibernating|stopping) return 0 ;;
    *) return 1 ;;
  esac
}

lock_owner_alive() {
  [ -s "$LOCK/pid" ] || return 1
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$pid" ]
}

release_lock() {
  rm -f "$LOCK/pid" >/dev/null 2>&1 || true
  rmdir "$LOCK" >/dev/null 2>&1 || true
}

arch_desktop_processes_running() {
  pgrep -f '[t]ermux-x11 com.termux.x11 :1|[x]monad-aarch64-linux|[d]bus-run-session -- sh -lc|[c]hromium --user-data-dir=/root/.config/helium-passwords|[h]elium --user-data-dir=/root/.config/helium-passwords' >/dev/null 2>&1 ||
    [ -S "$ROOT/tmp/.X11-unix/X1" ]
}

if state_is_busy; then
  log "attach deferred; session is hibernating/stopping"
  exit 75
fi

if ! arch_desktop_processes_running; then
  log "attach failed; no running X11 session"
  exit 1
fi

if [ "${ARCH_DESKTOP_ATTACH_LOCKLESS:-0}" != 1 ]; then
  while ! mkdir "$LOCK" 2>/dev/null; do
    if state_is_busy; then
      log "attach deferred; session is hibernating/stopping"
      exit 75
    fi
    if lock_owner_alive; then
      log "attach deferred; controller lock busy"
      exit 75
    fi
    rm -f "$LOCK/pid" >/dev/null 2>&1 || true
    if rmdir "$LOCK" >/dev/null 2>&1; then
      log "attach removed stale controller lock"
      continue
    fi
    log "attach deferred; controller lock busy"
    exit 75
  done
  printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
  trap 'release_lock' EXIT
fi

log "attach requested"
"$ROOT/arch-desktop-display-mode-root.sh" apply >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/chroot-tailnet-dns-root.sh" ] || "$ROOT/chroot-tailnet-dns-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/fix-magic-keyboard-layout-root.sh" ] || "$ROOT/fix-magic-keyboard-layout-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/input-display-assoc-root.sh" ] || "$ROOT/input-display-assoc-root.sh" apply >>"$LOG" 2>&1 &
[ ! -x "$ROOT/termux-x11-session-focus-root.sh" ] || "$ROOT/termux-x11-session-focus-root.sh" >>"$LOG" 2>&1 || true

if [ -S "$ROOT/tmp/.X11-unix/X1" ]; then
  /system/bin/chroot "$ROOT" /usr/bin/env DISPLAY=:1 XDG_RUNTIME_DIR=/tmp/runtime-root PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin sh -lc \
    'x11-lorie-input-setup >/dev/null 2>&1 || true' >>"$LOG" 2>&1 || true
fi

printf 'running\n' >"$STATE"
log "attach completed"
