#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/controller.log"
INTERVAL=${ARCH_DESKTOP_SESSION_WATCH_INTERVAL:-5}
STARTUP_GRACE_SECONDS=${ARCH_DESKTOP_SESSION_STARTUP_GRACE_SECONDS:-60}

seen_x11=0
misses=0
start_time=$(date +%s)

mkdir -p "$STATE_DIR" 2>/dev/null || true
printf '%s session watcher started\n' "$(date '+%F %T')" >>"$LOG"

termux_x11_activity_visible() {
  dumpsys activity activities 2>/dev/null |
    grep -Eq 'topResumedActivity=.*com[.]termux[.]x11/[.]MainActivity|Resumed: ActivityRecord[{].* com[.]termux[.]x11/[.]MainActivity|windows=[[]Window[{].*com[.]termux[.]x11/com[.]termux[.]x11[.]MainActivity'
}

termux_x11_process_running() {
  pgrep -f '[t]ermux-x11 com.termux.x11 :1' >/dev/null 2>&1
}

hibernate_and_exit() {
  reason=$1
  printf '%s %s; hibernating\n' "$(date '+%F %T')" "$reason" >>"$LOG"
  "$ROOT/arch-desktop-hibernate-root.sh" >>"$LOG" 2>&1 || true
  printf '%s session watcher exited\n' "$(date '+%F %T')" >>"$LOG"
  exit 0
}

while :; do
  if termux_x11_activity_visible; then
    if [ "$seen_x11" = 0 ]; then
      printf '%s Termux:X11 visible on a display; watcher armed\n' "$(date '+%F %T')" >>"$LOG"
    fi
    seen_x11=1
    misses=0
  else
    if [ "$seen_x11" = 1 ]; then
      misses=$((misses + 1))
      if [ "$misses" -ge 3 ]; then
        hibernate_and_exit "Termux:X11 left all displays"
      fi
    elif [ $(( $(date +%s) - start_time )) -ge "$STARTUP_GRACE_SECONDS" ]; then
      printf '%s Termux:X11 never became visible; watcher exited unarmed\n' "$(date '+%F %T')" >>"$LOG"
      exit 0
    fi
  fi

  if ! termux_x11_process_running; then
    if [ "$seen_x11" = 1 ]; then
      hibernate_and_exit "Termux:X11 process exited"
    elif [ $(( $(date +%s) - start_time )) -ge "$STARTUP_GRACE_SECONDS" ]; then
      printf '%s Termux:X11 process never appeared; watcher exited unarmed\n' "$(date '+%F %T')" >>"$LOG"
      exit 0
    fi
  fi

  sleep "$INTERVAL"
done
