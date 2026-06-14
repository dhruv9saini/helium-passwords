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

exit_busy() {
  log "$1"
  exit 75
}

release_lock() {
  rm -f "$LOCK/pid" >/dev/null 2>&1 || true
  rmdir "$LOCK" >/dev/null 2>&1 || true
}

arch_desktop_processes_running() {
  pgrep -f '[t]ermux-x11 com.termux.x11 :1|[x]monad-aarch64-linux|[d]bus-run-session -- sh -lc|[x]11-phone-trackpad|[c]hromium --user-data-dir=/root/.config/helium-passwords|[h]elium --user-data-dir=/root/.config/helium-passwords' >/dev/null 2>&1 ||
    [ -S "$ROOT/tmp/.X11-unix/X1" ]
}

lock_owner_alive() {
  [ -s "$LOCK/pid" ] || return 1
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$pid" ]
}

acquire_lock_or_skip_duplicate() {
  while ! mkdir "$LOCK" 2>/dev/null; do
    if state_is_busy; then
      exit_busy "resume deferred; session is hibernating/stopping"
    fi
    if arch_desktop_processes_running; then
      log "resume skipped; existing session is already running"
      printf 'running\n' >"$STATE"
      exit 0
    fi
    if lock_owner_alive; then
      exit_busy "resume deferred; another start is already in progress"
    fi
    rm -f "$LOCK/pid" >/dev/null 2>&1 || true
    if rmdir "$LOCK" >/dev/null 2>&1; then
      log "resume removed stale controller lock"
      continue
    fi
    exit_busy "resume deferred; controller lock busy"
  done
  printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
  trap 'release_lock' EXIT
}

acquire_lock_or_skip_duplicate

if state_is_busy; then
  exit_busy "resume deferred after lock; session is hibernating/stopping"
fi

log "resume requested"
printf 'resuming\n' >"$STATE"

pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true
pkill -f '[a]rch-desktop-display-watch-root.sh' >/dev/null 2>&1 || true

"$ROOT/arch-desktop-display-mode-root.sh" apply >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/chroot-tailnet-dns-root.sh" ] || "$ROOT/chroot-tailnet-dns-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/fix-magic-keyboard-layout-root.sh" ] || "$ROOT/fix-magic-keyboard-layout-root.sh" >>"$LOG" 2>&1 || true
[ ! -x "$ROOT/input-display-assoc-root.sh" ] || "$ROOT/input-display-assoc-root.sh" apply >>"$LOG" 2>&1 &

if arch_desktop_processes_running; then
  "$ROOT/stop-arch-x11-root.sh" >>"$LOG" 2>&1 || true
else
  rm -rf "$ROOT/tmp/.X11-unix" "$ROOT/tmp/.X1-lock" >/dev/null 2>&1 || true
fi

ARCH_X11_OPEN_ACTIVITY=1 "$ROOT/start-arch-xmonad-root.sh" >>"$LOG" 2>&1
[ ! -x "$ROOT/termux-x11-session-focus-root.sh" ] || "$ROOT/termux-x11-session-focus-root.sh" >>"$LOG" 2>&1 || true

nohup "$ROOT/arch-desktop-session-watch.sh" >>"$LOG" 2>&1 &
nohup "$ROOT/arch-desktop-display-watch-root.sh" >>"$LOG" 2>&1 &

printf 'running\n' >"$STATE"
log "resume completed"
