#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
STATE_DIR="$ROOT/root/.local/state/x11"
LOG="$STATE_DIR/thermal-guard.log"
PID_FILE="$STATE_DIR/thermal-guard.pid"
DEFAULTS_FILE="$STATE_DIR/frequency-max-defaults.env"
INTERVAL=${ARCH_DESKTOP_THERMAL_GUARD_INTERVAL:-3}
BASE_CAP=${ARCH_DESKTOP_THERMAL_BASE_CAP:-55}
LIGHT_CAP=${ARCH_DESKTOP_THERMAL_LIGHT_CAP:-45}
MODERATE_CAP=${ARCH_DESKTOP_THERMAL_MODERATE_CAP:-35}
SEVERE_CAP=${ARCH_DESKTOP_THERMAL_SEVERE_CAP:-25}
CRITICAL_CAP=${ARCH_DESKTOP_THERMAL_CRITICAL_CAP:-15}

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

cap_targets() {
  for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    [ -e "$policy/scaling_max_freq" ] || continue
    printf '%s|%s|%s\n' "cpu" "$policy/scaling_max_freq" "$policy/cpuinfo_min_freq"
  done
  for device in /sys/class/devfreq/*; do
    [ -d "$device" ] || continue
    [ -e "$device/max_freq" ] || continue
    case "$device" in
      *gpu*|*kgsl*|*adreno*|*gpubw*|*llccbw*|*memplat*|*memlat*|*cpubw*)
        printf '%s|%s|%s\n' "devfreq" "$device/max_freq" "$device/min_freq"
        ;;
    esac
  done
}

save_defaults() {
  [ -s "$DEFAULTS_FILE" ] && return 0
  tmp="$DEFAULTS_FILE.tmp"
  : >"$tmp"
  cap_targets | while IFS='|' read -r kind path min_path; do
    max=$(cat "$path" 2>/dev/null || true)
    min=0
    if [ -n "$min_path" ] && [ -e "$min_path" ]; then
      min=$(cat "$min_path" 2>/dev/null || printf 0)
    fi
    case "$max:$min" in
      *[!0-9:]*|:*) continue ;;
    esac
    [ "$max" -gt 0 ] || continue
    printf '%s|%s|%s|%s\n' "$kind" "$path" "$max" "$min" >>"$tmp"
  done
  mv "$tmp" "$DEFAULTS_FILE"
  chmod 600 "$DEFAULTS_FILE" 2>/dev/null || true
}

restore_defaults() {
  [ -s "$DEFAULTS_FILE" ] || return 0
  while IFS='|' read -r kind path max min; do
    case "$kind:$max" in
      *[!A-Za-z0-9_:.-]*|*:|:) continue ;;
    esac
    [ -e "$path" ] || continue
    printf '%s\n' "$max" >"$path" 2>/dev/null || true
  done <"$DEFAULTS_FILE"
  log "restored frequency caps"
}

skin_line() {
  dumpsys thermalservice 2>/dev/null |
    sed -n 's/.*mValue=\([0-9][0-9]*\)\(\.[0-9][0-9]*\)\{0,1\}.*mName=skin, mStatus=\([0-9][0-9]*\).*/\1 \3/p' |
    tail -n 1
}

skin_status() {
  set -- $(skin_line)
  printf '%s\n' "${2:-0}"
}

skin_value_int() {
  set -- $(skin_line)
  printf '%s\n' "${1:-0}"
}

cap_for_thermal() {
  value=${1:-0}
  status=${2:-0}
  case "$value:$status" in
    *[!0-9:]*|:*) printf '%s\n' "$BASE_CAP"; return 0 ;;
  esac

  if [ "$status" -ge 4 ] || [ "$value" -ge 58 ]; then
    printf '%s\n' "$CRITICAL_CAP"
  elif [ "$status" -ge 3 ] || [ "$value" -ge 54 ]; then
    printf '%s\n' "$SEVERE_CAP"
  elif [ "$status" -ge 2 ] || [ "$value" -ge 50 ]; then
    printf '%s\n' "$MODERATE_CAP"
  elif [ "$status" -ge 1 ] || [ "$value" -ge 47 ]; then
    printf '%s\n' "$LIGHT_CAP"
  else
    printf '%s\n' "$BASE_CAP"
  fi
}

apply_cap() {
  percent=$1
  changed=0
  [ -s "$DEFAULTS_FILE" ] || return 0
  while IFS='|' read -r kind path max min; do
    case "$kind:$max:$min" in
      *[!A-Za-z0-9_:.-]*|*::*) continue ;;
    esac
    [ -e "$path" ] || continue
    cap=$((max * percent / 100))
    [ "$cap" -ge "$min" ] || cap=$min
    current=$(cat "$path" 2>/dev/null || printf 0)
    if [ "$current" != "$cap" ]; then
      printf '%s\n' "$cap" >"$path" 2>/dev/null || true
      changed=1
    fi
  done <"$DEFAULTS_FILE"
  [ "$changed" = 0 ] || log "set frequency max cap to ${percent}%"
}

daemon_running() {
  [ -s "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$pid" ]
}

daemon_loop() {
  save_defaults
  printf '%s\n' "$$" >"$PID_FILE"
  log "thermal guard started"
  while :; do
    value=$(skin_value_int)
    status=$(skin_status)
    cap=$(cap_for_thermal "$value" "$status")
    apply_cap "$cap"
    sleep "$INTERVAL"
  done
}

stop_guard() {
  if daemon_running; then
    pid=$(cat "$PID_FILE")
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
  restore_defaults
}

case "${1:-start}" in
  start)
    daemon_running && exit 0
    nohup "$0" daemon >>"$LOG" 2>&1 &
    ;;
  daemon)
    daemon_loop
    ;;
  once)
    save_defaults
    apply_cap "$(cap_for_thermal "$(skin_value_int)" "$(skin_status)")"
    ;;
  stop|restore)
    stop_guard
    ;;
  status)
    if daemon_running; then
      printf 'running pid=%s\n' "$(cat "$PID_FILE")"
    else
      printf 'stopped\n'
    fi
    printf 'skin_value=%s\n' "$(skin_value_int)"
    printf 'skin_status=%s\n' "$(skin_status)"
    ;;
  *)
    printf 'usage: %s [start|daemon|once|stop|status]\n' "$0" >&2
    exit 2
    ;;
esac
