#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/raw-pointer.log"
FIFO="$STATE_DIR/raw-pointer.fifo"
PID_FILE="$STATE_DIR/raw-pointer.pid"
POINTER_NUM=${ARCH_X11_RAW_POINTER_NUM:-1}
POINTER_DEN=${ARCH_X11_RAW_POINTER_DEN:-1}
SCROLL_NUM=${ARCH_X11_RAW_SCROLL_NUM:-1}
SCROLL_DEN=${ARCH_X11_RAW_SCROLL_DEN:-1}
NATURAL_SCROLL=${ARCH_X11_RAW_NATURAL_SCROLL:-1}

mkdir -p "$STATE_DIR" 2>/dev/null || true
PATH=/system/bin:/system/xbin:/apex/com.android.runtime/bin:/vendor/bin:/odm/bin:$PATH
export PATH
printf '%s\n' "$$" >"$PID_FILE"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

hex_to_int() {
  value=${1#0x}
  case "$value" in
    ''|*[!0-9a-fA-F]*) printf '0\n'; return ;;
  esac
  number=$((16#$value))
  if [ "$number" -ge 2147483648 ]; then
    number=$((number - 4294967296))
  fi
  printf '%s\n' "$number"
}

scale_value() {
  value=$1
  num=$2
  den=$3
  [ "$den" -gt 0 ] 2>/dev/null || den=1
  printf '%s\n' $((value * num / den))
}

pointer_devices() {
  for dev in /dev/input/event*; do
    [ -e "$dev" ] || continue
    info=$(getevent -lp "$dev" 2>/dev/null || true)
    name=$(printf '%s\n' "$info" | sed -n 's/.*name: *"\(.*\)".*/\1/p' | head -n 1)
    case "$name" in
      ''|touchpanel|*fingerprint*|*Fingerprint*|*gpio-keys*|*pmic*|*haptics*|*hall*|*cover*|*snd-card*|*Headset*|*Jack*)
        continue
        ;;
    esac
    if printf '%s\n' "$info" | grep -q 'REL_X' &&
      printf '%s\n' "$info" | grep -q 'REL_Y' &&
      printf '%s\n' "$info" | grep -q 'BTN_MOUSE'; then
      printf '%s\n' "$dev"
    elif printf '%s\n' "$info" | grep -q 'ABS_X' &&
      printf '%s\n' "$info" | grep -q 'ABS_Y' &&
      printf '%s\n' "$info" | grep -q 'BTN_TOUCH'; then
      printf '%s\n' "$dev"
    fi
  done
}

button_number() {
  case "$1" in
    BTN_MOUSE) printf '1\n' ;;
    BTN_RIGHT) printf '3\n' ;;
    BTN_MIDDLE) printf '2\n' ;;
    BTN_SIDE|BTN_BACK) printf '8\n' ;;
    BTN_EXTRA|BTN_FORWARD) printf '9\n' ;;
    *) printf '0\n' ;;
  esac
}

button_state() {
  case "$1" in
    DOWN|00000001) printf 'down\n' ;;
    UP|00000000) printf 'up\n' ;;
    *) printf '\n' ;;
  esac
}

start_helper() {
  rm -f "$FIFO"
  mkfifo "$FIFO"
  /system/bin/chroot "$ROOT" /usr/bin/env \
    DISPLAY=:1 \
    XDG_RUNTIME_DIR=/tmp/runtime-root \
    PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
    /root/.local/bin/x11-pointer-helper <"$FIFO" >>"$LOG" 2>&1 &
  helper_pid=$!
  exec 3>"$FIFO"
}

stop_helper() {
  exec 3>&- 2>/dev/null || true
  [ -z "${helper_pid:-}" ] || kill "$helper_pid" >/dev/null 2>&1 || true
  rm -f "$FIFO"
  rm -f "$PID_FILE"
}

trap 'stop_helper' EXIT INT TERM HUP

log "raw pointer forwarder starting"

watch_device() {
  dev=$1
  (
    dx=0
    dy=0
    sx=0
    sy=0
    last_abs_x=
    last_abs_y=
    abs_active=0
    exec 4>"$FIFO"

    getevent -l "$dev" 2>>"$LOG" | while read -r _ event_type event_code event_value _rest; do
      case "$event_type:$event_code" in
        EV_REL:REL_X)
          value=$(hex_to_int "$event_value")
          value=$(scale_value "$value" "$POINTER_NUM" "$POINTER_DEN")
          dx=$((dx + value))
          ;;
        EV_REL:REL_Y)
          value=$(hex_to_int "$event_value")
          value=$(scale_value "$value" "$POINTER_NUM" "$POINTER_DEN")
          dy=$((dy + value))
          ;;
        EV_REL:REL_WHEEL)
          value=$(hex_to_int "$event_value")
          [ "$NATURAL_SCROLL" = 0 ] || value=$((-value))
          value=$(scale_value "$value" "$SCROLL_NUM" "$SCROLL_DEN")
          sy=$((sy + value))
          ;;
        EV_REL:REL_HWHEEL)
          value=$(hex_to_int "$event_value")
          value=$(scale_value "$value" "$SCROLL_NUM" "$SCROLL_DEN")
          sx=$((sx + value))
          ;;
        EV_ABS:ABS_X)
          value=$(hex_to_int "$event_value")
          if [ "$abs_active" = 1 ] && [ -n "$last_abs_x" ]; then
            delta=$((value - last_abs_x))
            delta=$(scale_value "$delta" "$POINTER_NUM" "$POINTER_DEN")
            dx=$((dx + delta))
          fi
          last_abs_x=$value
          ;;
        EV_ABS:ABS_Y)
          value=$(hex_to_int "$event_value")
          if [ "$abs_active" = 1 ] && [ -n "$last_abs_y" ]; then
            delta=$((value - last_abs_y))
            delta=$(scale_value "$delta" "$POINTER_NUM" "$POINTER_DEN")
            dy=$((dy + delta))
          fi
          last_abs_y=$value
          ;;
        EV_KEY:BTN_TOUCH)
          case "$event_value" in
            DOWN|00000001) abs_active=1 ;;
            UP|00000000)
              abs_active=0
              last_abs_x=
              last_abs_y=
              ;;
          esac
          ;;
        EV_KEY:BTN_*)
          button=$(button_number "$event_code")
          state=$(button_state "$event_value")
          if [ "$button" != 0 ] && [ -n "$state" ]; then
            printf 'button %s %s\n' "$button" "$state" >&4 || exit 0
          fi
          ;;
        EV_SYN:SYN_REPORT)
          if [ "$dx" != 0 ] || [ "$dy" != 0 ]; then
            printf 'move %s %s\n' "$dx" "$dy" >&4 || exit 0
            dx=0
            dy=0
          fi
          if [ "$sx" != 0 ] || [ "$sy" != 0 ]; then
            printf 'scroll %s %s\n' "$sx" "$sy" >&4 || exit 0
            sx=0
            sy=0
          fi
          ;;
      esac
    done
  )
}

while :; do
  devices=$(pointer_devices | tr '\n' ' ')
  if [ -z "$devices" ]; then
    log "no raw pointer devices found"
    sleep 3
    continue
  fi

  log "watching raw pointer devices: $devices"
  start_helper

  watcher_pids=
  for dev in $devices; do
    watch_device "$dev" &
    watcher_pids="$watcher_pids $!"
  done

  wait $watcher_pids >/dev/null 2>&1 || true
  for pid in $watcher_pids; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  stop_helper
  sleep 1
done
