#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
TERMUX_UID=10409
TERMUX_HOME=/data/data/com.termux/files/home
TERMUX_PREFIX=/data/data/com.termux/files/usr
DISPLAY_TARGET="$ROOT/root/.local/state/x11/android-display-target.env"

load_target() {
  target_source=native
  target_display_id=0
  target_android_display_mode=native
  target_x11_resolution=
  if [ -f "$DISPLAY_TARGET" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
  fi
}

termux_pref() {
  pref="$TERMUX_PREFIX/bin/termux-x11-preference"
  [ -x "$pref" ] || return 0
  /debug_ramdisk/su -mm -g "$TERMUX_UID" -G 3003 "$TERMUX_UID" -c "export HOME=$TERMUX_HOME PREFIX=$TERMUX_PREFIX PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin; /system/bin/timeout -k 1 2 termux-x11-preference $*" >/dev/null 2>&1 || true
}

set_preferences() {
  load_target
  pointer_speed=${ARCH_X11_POINTER_SPEED:-145}
  hardware_scancodes=${ARCH_X11_HARDWARE_SCANCODES:-false}
  display_resolution_args="displayResolutionMode:native"
  if [ -n "${target_x11_resolution:-}" ]; then
    display_resolution_args="displayResolutionMode:custom displayResolutionCustom:${target_x11_resolution}"
  fi

  if [ "${target_source:-native}" = external ] && [ "${target_android_display_mode:-native}" = extended ]; then
    termux_pref "touchMode:Trackpad scaleTouchpad:true pointerCapture:true transformCapturedPointer:at capturedPointerSpeedFactor:$pointer_speed hardwareKbdScancodesWorkaround:$hardware_scancodes dexMetaKeyCapture:true filterOutWinkey:false showMouseHelper:false showAdditionalKbd:false additionalKbdVisible:false useTermuxEKBarBehaviour:false fullscreen:true $display_resolution_args"
  else
    termux_pref "touchMode:Trackpad scaleTouchpad:true pointerCapture:false capturedPointerSpeedFactor:$pointer_speed hardwareKbdScancodesWorkaround:$hardware_scancodes dexMetaKeyCapture:true filterOutWinkey:false showMouseHelper:true showAdditionalKbd:true additionalKbdVisible:true useTermuxEKBarBehaviour:true fullscreen:false displayResolutionMode:native"
  fi
}

stop_stale_raw_pointer_forwarder() {
  [ "${ARCH_X11_RAW_POINTER:-0}" = 0 ] || return 0
  /system/bin/pkill -f '[a]ndroid-raw-pointer-forwarder-root.sh' >/dev/null 2>&1 || true
  /system/bin/pkill -f '[g]etevent -l /dev/input/event' >/dev/null 2>&1 || true
}

start_activity() {
  load_target
  if [ "${target_source:-native}" = external ] && [ "${target_android_display_mode:-native}" = extended ] && [ -n "${target_display_id:-}" ] && [ "${target_display_id:-0}" != 0 ]; then
    am start --user 0 --display "$target_display_id" --activity-exclude-from-recents --activity-no-animation -n com.termux.x11/.MainActivity >/dev/null 2>&1 ||
      am start --user 0 --activity-exclude-from-recents --activity-no-animation -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
  else
    am start --user 0 --activity-no-animation -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
  fi
}

prime_pointer_capture() {
  load_target
  [ "${target_source:-native}" = external ] || return 0
  [ "${target_android_display_mode:-native}" = extended ] || return 0
  [ -n "${target_display_id:-}" ] || return 0
  [ "${target_display_id:-0}" != 0 ] || return 0
  input touchscreen -d "$target_display_id" tap 1 1 >/dev/null 2>&1 || true
}

prime_pointer_capture_repeatedly() {
  prime_pointer_capture
  (
    for delay in 1 2 4; do
      sleep "$delay"
      set_preferences
      prime_pointer_capture
    done
  ) &
}

stop_stale_raw_pointer_forwarder
set_preferences
start_activity
prime_pointer_capture_repeatedly
