#!/system/bin/sh
set -eu

root=${ARCH_CHROOT:-/data/local/chroots/arch}
state_dir=$root/root/.local/state/x11
state_file=$state_dir/android-display-before-arch.env
target_file=$state_dir/android-display-target.env
launcher_prefs=/data/user/0/com.android.launcher3/shared_prefs/com.android.launcher3.prefs.xml
launcher_prefs_state=$state_dir/launcher3-prefs-before-arch.xml
external_density=${ARCH_DESKTOP_EXTERNAL_WM_DENSITY:-160}
desktop_global_keys="enable_freeform_support force_resizable_activities freeform_window_management enable_non_resizable_multi_window"

mkdir -p "$state_dir" 2>/dev/null || true

sed_value() {
  sed -n "$1" | tail -n 1
}

save_state() {
  [ -f "$state_file" ] && return 0

  if [ -f "$launcher_prefs" ] && [ ! -f "$launcher_prefs_state" ]; then
    cp -p "$launcher_prefs" "$launcher_prefs_state" 2>/dev/null || true
  fi

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
    for key in $desktop_global_keys; do
      value=$(settings get global "$key" 2>/dev/null || printf null)
      printf '%s=%s\n' "$key" "$value"
    done
  } >"$state_file"
}

clear_arch_global_display_settings() {
  settings delete global policy_control >/dev/null 2>&1 || true
  settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
  settings put global force_allow_on_external 1 >/dev/null 2>&1 || true
  for key in $desktop_global_keys; do
    settings put global "$key" 0 >/dev/null 2>&1 || true
  done
}

restore_launcher_prefs() {
  [ -f "$launcher_prefs_state" ] || return 0
  [ -f "$launcher_prefs" ] || {
    rm -f "$launcher_prefs_state"
    return 0
  }

  if ! cmp -s "$launcher_prefs_state" "$launcher_prefs" 2>/dev/null; then
    am force-stop com.android.launcher3 >/dev/null 2>&1 || true
    cp -p "$launcher_prefs_state" "$launcher_prefs" 2>/dev/null || true
  fi
  rm -f "$launcher_prefs_state"
}

restore_state() {
  [ -f "$state_file" ] || {
    wm size reset || true
    wm density reset || true
    wm user-rotation free || true
    clear_arch_global_display_settings
    restore_launcher_prefs
    rm -f "$target_file"
    return 0
  }

  size=reset
  density=reset
  policy_control=null
  accelerometer_rotation=null
  user_rotation=0
  enable_freeform_support=null
  force_resizable_activities=null
  freeform_window_management=null
  enable_non_resizable_multi_window=null
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

  clear_arch_global_display_settings

  if [ "${accelerometer_rotation:-null}" = 1 ]; then
    wm user-rotation free || true
    settings put system accelerometer_rotation 1 || true
  elif [ "${accelerometer_rotation:-null}" != null ]; then
    wm user-rotation lock "${user_rotation:-0}" || true
    settings put system accelerometer_rotation "$accelerometer_rotation" || true
    settings put system user_rotation "${user_rotation:-0}" || true
  fi

  restore_launcher_prefs
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
  for id in $(cmd display get-displays --ids-only 2>/dev/null); do
    [ "$id" != 0 ] || continue
    cmd display enable-display "$id" >/dev/null 2>&1 || true

    size=$(
      cmd display get-active-mode "$id" 2>/dev/null |
        sed -n 's/.*Resolution: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1x\2/p' |
        tail -n 1
    )
    if [ -z "$size" ]; then
      size=$(wm size -d "$id" 2>/dev/null | sed_value 's/^Physical size: //p')
    fi

    [ -n "$size" ] || continue
    printf '%s %s %s\n' "$id" "$size" "$external_density"
    return 0
  done

  return 1
}

write_target() {
  source=$1
  display_id=$2
  size=$3
  density=$4
  x11_resolution=$5
  android_mode=${6:-mirror}

  {
    printf 'target_source=%s\n' "$source"
    printf 'target_display_id=%s\n' "$display_id"
    printf 'target_size=%s\n' "$size"
    printf 'target_density=%s\n' "$density"
    printf 'target_android_display_mode=%s\n' "$android_mode"
    printf 'target_x11_mode=custom\n'
    printf 'target_x11_resolution=%s\n' "$x11_resolution"
  } >"$target_file"
  chmod 600 "$target_file" 2>/dev/null || true
}

target_record() {
  external_record=$(detect_android_external || true)

  if [ -n "$external_record" ]; then
    set -- $external_record
    display_id=${1:-0}
    target_size=${2:-$(native_size)}
    target_density=${ARCH_DESKTOP_MIRROR_WM_DENSITY:-$external_density}
    printf 'external %s %s %s %s extended\n' "$display_id" "$target_size" "$target_density" "$target_size"
  else
    target_size=$(native_size)
    printf 'native 0 reset reset %s native\n' "$target_size"
  fi
}

print_target() {
  set -- $(target_record)
  printf 'target_source=%s\n' "$1"
  printf 'target_display_id=%s\n' "$2"
  printf 'target_size=%s\n' "$3"
  printf 'target_density=%s\n' "$4"
  printf 'target_android_display_mode=%s\n' "$6"
  printf 'target_x11_mode=custom\n'
  printf 'target_x11_resolution=%s\n' "$5"
}

apply_mode() {
  save_state
  if [ -x "$root/android-ui-preferences-root.sh" ]; then
    "$root/android-ui-preferences-root.sh" || true
  else
    cmd statusbar send-disable-flag notification-icons >/dev/null 2>&1 || true
  fi

  set -- $(target_record)
  target_source=$1
  display_id=$2
  target_size=$3
  target_density=$4
  target_x11_resolution=$5
  target_android_display_mode=$6

  if [ "$target_source" = external ]; then
    settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
    settings put global force_allow_on_external 1 >/dev/null 2>&1 || true
    for key in $desktop_global_keys; do
      settings put global "$key" 1 >/dev/null 2>&1 || true
    done
    cmd display enable-display "$display_id" >/dev/null 2>&1 || true
    wm size reset || true
    wm density reset || true
    wm size "$target_size" -d "$display_id" >/dev/null 2>&1 || true
    wm density "$target_density" -d "$display_id" >/dev/null 2>&1 || true
    wm set-display-windowing-mode -d "$display_id" 1 >/dev/null 2>&1 || true
    write_target "$target_source" "$display_id" "$target_size" "$target_density" "$target_x11_resolution" "$target_android_display_mode"
    wm scaling auto || true
    cmd statusbar collapse >/dev/null 2>&1 || true
  else
    wm size reset || true
    wm density reset || true
    settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
    settings put global force_allow_on_external 1 >/dev/null 2>&1 || true
    for key in $desktop_global_keys; do
      settings put global "$key" 0 >/dev/null 2>&1 || true
    done
    write_target "$target_source" "$display_id" "$target_size" "$target_density" "$target_x11_resolution" "$target_android_display_mode"
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
  fingerprint)
    target_record
    ;;
  target)
    print_target
    ;;
  *)
    echo "usage: $0 [apply|reset|status|fingerprint|target]" >&2
    exit 2
    ;;
esac
