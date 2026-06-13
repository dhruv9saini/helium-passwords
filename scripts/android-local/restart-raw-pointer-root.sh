#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}

kill_arg_contains() {
  needle=$1
  signal=${2:-TERM}
  ps -A -o PID,ARGS 2>/dev/null | while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    [ "$pid" = PID ] && continue
    [ "$pid" = "$$" ] && continue
    case "$args" in
      *"$needle"*) kill "-$signal" "$pid" >/dev/null 2>&1 || true ;;
    esac
  done
}

kill_arg_contains 'android-raw-pointer-forwarder-root.sh' TERM
kill_arg_contains 'getevent -l /dev/input/event' TERM
sleep 1
kill_arg_contains 'android-raw-pointer-forwarder-root.sh' KILL
kill_arg_contains 'getevent -l /dev/input/event' KILL

if [ "${1:-start}" = start ]; then
  nohup "$ROOT/android-raw-pointer-forwarder-root.sh" >/dev/null 2>&1 &
fi
