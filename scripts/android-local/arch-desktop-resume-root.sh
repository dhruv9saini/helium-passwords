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

arch_desktop_processes_running() {
  pgrep -f '[t]ermux-x11 com.termux.x11 :1|[x]monad-aarch64-linux|[d]bus-run-session -- sh -lc|[x]11-phone-trackpad|[c]hromium --user-data-dir=/root/.config/helium-passwords|[h]elium --user-data-dir=/root/.config/helium-passwords' >/dev/null 2>&1 ||
    [ -S "$ROOT/tmp/.X11-unix/X1" ]
}

log "resume requested"
printf 'resuming\n' >"$STATE"

pkill -f '[a]rch-desktop-session-watch.sh' >/dev/null 2>&1 || true
pkill -f '[a]rch-desktop-display-watch-root.sh' >/dev/null 2>&1 || true

"$ROOT/arch-desktop-display-mode-root.sh" apply >>"$LOG" 2>&1 || true

if arch_desktop_processes_running; then
  "$ROOT/stop-arch-x11-root.sh" >>"$LOG" 2>&1 || true
else
  rm -rf "$ROOT/tmp/.X11-unix" "$ROOT/tmp/.X1-lock" >/dev/null 2>&1 || true
fi

ARCH_X11_OPEN_ACTIVITY=1 "$ROOT/start-arch-xmonad-root.sh" >>"$LOG" 2>&1

nohup "$ROOT/arch-desktop-session-watch.sh" >>"$LOG" 2>&1 &
nohup "$ROOT/arch-desktop-display-watch-root.sh" >>"$LOG" 2>&1 &

printf 'running\n' >"$STATE"
log "resume completed"
