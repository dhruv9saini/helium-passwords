#!/system/bin/sh
set -eu

root=${ARCH_CHROOT:-/data/local/chroots/arch}
state_dir=$root/root/.local/state/x11
state_file=$state_dir/android-display-before-arch.env
target_file=$state_dir/android-display-target.env
external_density=${ARCH_DESKTOP_EXTERNAL_WM_DENSITY:-160}

mkdir -p "$state_dir" 2>/dev/null || true

sed_value() {
  sed -n "$1" | tail -n 1
}

save_state() {
  [ -f "$state_file" ] && return 0

  size_override=$(wm size | sed_value 's/^Override size: //p')
  density_override=$(wm density | sed_value 's/^Override density: //p')
  policy_control=$(settings get global policy_control 2>/dev/null || printf null)
  accelerometer_rotation=$(settings get system accelerometer_rotation 2>/dev/null || printf null)
  user_rotation=$(settings get system user_rotation 2>/dev/null || printf null)

  {
    printf 'size=%s\n' "${size_override:-reset}"
    printf 'density=%s\n' "${density_override:-reset}"
    printf 'policy_control=%s\n' "$policy_control"
    printf 'accelerometer_rotation=%s\n' "$accelerometer_rotation"
    printf 'user_rotation=%s\n' "$user_rotation"
  } >"$state_file"
}

restore_state() {
  [ -f "$state_file" ] || {
    wm size reset || true
    wm density reset || true
    wm user-rotation free || true
    return 0
  }

  size=reset
  density=reset
  policy_control=null
  accelerometer_rotation=null
  user_rotation=0
  # shellcheck disable=SC1090
  . "$state_file"

  if [ "${size:-reset}" = reset ]; then
    wm size reset || true
  else
    wm size "$size" || true
  fi

  if [ "${density:-reset}" = reset ]; then
    wm density reset || true
  else
    wm density "$density" || true
  fi

  if [ "${policy_control:-null}" = null ] || [ -z "${policy_control:-}" ]; then
    settings delete global policy_control >/dev/null 2>&1 || true
  else
    settings put global policy_control "$policy_control" || true
  fi

  if [ "${accelerometer_rotation:-null}" = 1 ]; then
    wm user-rotation free || true
    settings put system accelerometer_rotation 1 || true
  elif [ "${accelerometer_rotation:-null}" != null ]; then
    wm user-rotation lock "${user_rotation:-0}" || true
    settings put system accelerometer_rotation "$accelerometer_rotation" || true
    settings put system user_rotation "${user_rotation:-0}" || true
  fi

  rm -f "$state_file" "$target_file"
}

landscape_size() {
  size=$1
  width=${size%x*}
  height=${size#*x}
  case "$width:$height" in
    *[!0-9:]*|:|*:)
      printf '%s\n' "$size"
      return 0
      ;;
  esac
  if [ "$height" -gt "$width" ]; then
    printf '%sx%s\n' "$height" "$width"
  else
    printf '%s\n' "$size"
  fi
}

native_size() {
  size=$(wm size | sed_value 's/^Physical size: //p')
  [ -n "$size" ] || size=1440x3168
  landscape_size "$size"
}

detect_android_external() {
  cmd display get-displays 2>/dev/null | tr '\n' ' ' | sed 's/Display id/\nDisplay id/g' | while IFS= read -r line; do
    case "$line" in
      Display\ id*) ;;
      *) continue ;;
    esac

    id=$(printf '%s' "$line" | sed -n 's/^Display id \([0-9][0-9]*\):.*/\1/p')
    case "$line" in
      *"type EXTERNAL"*) ;;
      *)
        [ -n "$id" ] && [ "$id" != 0 ] || continue
        case "$line" in
          *"Built-in Screen"*) continue ;;
        esac
        ;;
    esac

    size=$(printf '%s' "$line" | sed -n 's/.*real \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1x\2/p')
    density=$(printf '%s' "$line" | sed -n 's/.*density \([0-9][0-9]*\).*/\1/p')
    [ -n "$size" ] || continue
    printf '%s %s %s\n' "${id:-0}" "$size" "${density:-$external_density}"
    break
  done | head -n 1
}

write_target() {
  source=$1
  display_id=$2
  size=$3
  density=$4
  x11_resolution=$5

  {
    printf 'target_source=%s\n' "$source"
    printf 'target_display_id=%s\n' "$display_id"
    printf 'target_size=%s\n' "$size"
    printf 'target_density=%s\n' "$density"
    printf 'target_x11_mode=exact\n'
    printf 'target_x11_resolution=%s\n' "$x11_resolution"
  } >"$target_file"
  chmod 600 "$target_file" 2>/dev/null || true
}

apply_mode() {
  save_state

  external_record=$(detect_android_external || true)

  if [ -n "$external_record" ]; then
    set -- $external_record
    display_id=${1:-0}
    target_size=${2:-$(native_size)}
    target_density=${3:-$external_density}
    wm size "$target_size" || true
    wm density "$target_density" || true
    if [ "$display_id" != 0 ]; then
      wm size "$target_size" -d "$display_id" >/dev/null 2>&1 || true
      wm density "$target_density" -d "$display_id" >/dev/null 2>&1 || true
    fi
    write_target external "$display_id" "$target_size" "$target_density" "$target_size"
    wm scaling auto || true
    wm user-rotation lock 1 || {
      settings put system accelerometer_rotation 0 || true
      settings put system user_rotation 1 || true
    }
    settings put global policy_control immersive.full=com.termux.x11 || true
    cmd statusbar collapse >/dev/null 2>&1 || true
  else
    target_size=$(native_size)
    wm size reset || true
    wm density reset || true
    write_target native 0 reset reset "$target_size"
  fi
}

case "${1:-status}" in
  apply)
    apply_mode
    ;;
  reset|restore)
    restore_state
    ;;
  status)
    wm size
    wm density
    settings get global policy_control
    wm user-rotation
    [ ! -f "$target_file" ] || cat "$target_file"
    ;;
  *)
    echo "usage: $0 [apply|reset|status]" >&2
    exit 2
    ;;
esac
