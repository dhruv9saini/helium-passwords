#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
LOG="$ROOT/root/.local/state/x11/stop.log"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

kill_pattern() {
  pattern=$1
  /system/bin/pkill -TERM -f "$pattern" >/dev/null 2>&1 || true
}

kill_pattern_hard() {
  pattern=$1
  /system/bin/pkill -KILL -f "$pattern" >/dev/null 2>&1 || true
}

kill_arg_contains() {
  needle=$1
  signal=${2:-TERM}
  ps -A -o PID,ARGS 2>/dev/null | while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = "PID" ] && continue
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$needle"*) kill "-$signal" "$pid" >/dev/null 2>&1 || true ;;
    esac
  done
}

log "stopping Termux:X11 Arch desktop"

am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11 >/dev/null 2>&1 || true

kill_pattern '[s]tart-arch-xmonad-root.sh'
kill_pattern '[t]ermux-x11-preference'
kill_pattern '[x]monad-aarch64-linux'
kill_pattern '[d]bus-run-session -- sh -lc'
kill_pattern '[z]utty'
kill_pattern '[t]mux new-session -A -s x11'
kill_pattern '[x]settingsd'
kill_pattern '[x]11-clip-watch'
kill_pattern '[x]11-phone-trackpad'
kill_pattern '[x]11-pointer-helper'
kill_pattern '[c]lipnotify'
kill_pattern '[c]hromium --user-data-dir=/root/.config/helium-passwords'
kill_pattern '[h]elium-passwords'
kill_pattern '[t]ermux-x11 com.termux.x11 :1'
kill_pattern '[s]u -g 10409.*termux-x11 :1'
kill_pattern '[s]u -M.*10409.*termux-x11'
kill_pattern '[s]u -M.*10409.*termux-x11-preference'
kill_arg_contains 'x11-clip-watch' TERM
kill_arg_contains 'x11-phone-trackpad' TERM

sleep 2

kill_pattern_hard '[s]tart-arch-xmonad-root.sh'
kill_pattern_hard '[t]ermux-x11-preference'
kill_pattern_hard '[x]monad-aarch64-linux'
kill_pattern_hard '[z]utty'
kill_pattern_hard '[t]ermux-x11 com.termux.x11 :1'
kill_pattern_hard '[s]u -g 10409.*termux-x11 :1'
kill_pattern_hard '[s]u -M.*10409.*termux-x11'
kill_pattern_hard '[s]u -M.*10409.*termux-x11-preference'
kill_arg_contains 'x11-clip-watch' KILL
kill_arg_contains 'x11-phone-trackpad' KILL

umount -l "$ROOT/tmp/.X11-unix" >/dev/null 2>&1 || true
rm -rf "$ROOT/tmp/.X11-unix" "$ROOT/tmp/.X1-lock" >/dev/null 2>&1 || true
setenforce 1 || true
am force-stop com.termux.x11 >/dev/null 2>&1 || true
am force-stop org.lineageos.jelly >/dev/null 2>&1 || true

log "Termux:X11 Arch desktop stopped"
