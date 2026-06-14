#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
JAR="$ROOT/connected-display-auto-enable.jar"
CLASS=net.dhruv.displayautoenable.ConnectedDisplayAutoEnable
PID_FILE=/data/local/tmp/helium-connected-display-auto-enable.pid
LOG_FILE=/data/local/tmp/helium-connected-display-auto-enable.log

run_helper() {
  /system/bin/app_process -Djava.class.path="$JAR" /system/bin "$CLASS" "$@"
}

is_running() {
  pid=${1:-}
  [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q "$CLASS"
}

start() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if is_running "$pid"; then
      exit 0
    fi
  fi

  run_helper once >>"$LOG_FILE" 2>&1 || true
  nohup /system/bin/sh -c "exec /system/bin/app_process -Djava.class.path='$JAR' /system/bin '$CLASS' watch" >>"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
}

stop() {
  if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if is_running "$pid"; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE"
  fi
  pkill -f "$CLASS" >/dev/null 2>&1 || true
}

case "${1:-start}" in
  start)
    start
    ;;
  once)
    run_helper once
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  status)
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if is_running "$pid"; then
      echo "running $pid"
    else
      echo "stopped"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [start|once|stop|restart|status]" >&2
    exit 2
    ;;
esac
