#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
STATE_DIR="$ROOT/root/.local/state/x11"
PID_FILE="$STATE_DIR/hibernate-hold-osd.pid"
LOG="$STATE_DIR/hibernate-hold-osd.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

kill_osd() {
  if [ -s "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill "$pid" >/dev/null 2>&1 || true ;;
    esac
  fi
  rm -f "$PID_FILE"
}

show_message() {
  text=$1
  timeout=${2:-4}
  kill_osd
  (
    /system/bin/chroot "$ROOT" /usr/bin/env \
      DISPLAY=:1 \
      XDG_RUNTIME_DIR=/tmp/runtime-root \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
      /usr/bin/xmessage -center -timeout "$timeout" "$text" >>"$LOG" 2>&1 || true
  ) &
  printf '%s\n' "$!" >"$PID_FILE"
}

case "${1:-show}" in
  show)
    show_message "Hold Hibernate on the phone for 3 seconds. Release to cancel." 4
    ;;
  commit)
    show_message "Hibernating Arch Desktop..." 2
    ;;
  cancel)
    kill_osd
    ;;
  *)
    echo "usage: $0 [show|commit|cancel]" >&2
    exit 2
    ;;
esac
