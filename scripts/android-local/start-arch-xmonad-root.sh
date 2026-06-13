#!/system/bin/sh
set -eu

ROOT=/data/local/chroots/arch
TERMUX_UID=10409
TERMUX_HOME=/data/data/com.termux/files/home
TERMUX_PREFIX=/data/data/com.termux/files/usr
LOG="$TERMUX_HOME/start-arch-xmonad.log"
DISPLAY_TARGET="$ROOT/root/.local/state/x11/android-display-target.env"

"$ROOT/android-bind-mounts.sh" "$ROOT"

configure_android_desktop_flags() {
  target_source=native
  if [ -f "$DISPLAY_TARGET" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
  fi

  if [ "${target_source:-native}" = external ]; then
    settings put global force_desktop_mode_on_external_displays 1 || true
    settings put global enable_freeform_support 1 || true
    settings put global force_resizable_activities 1 || true
    settings put global freeform_window_management 1 || true
    settings put global enable_non_resizable_multi_window 1 || true
  else
    settings delete global force_desktop_mode_on_external_displays >/dev/null 2>&1 || true
    settings delete global enable_freeform_support >/dev/null 2>&1 || true
    settings delete global force_resizable_activities >/dev/null 2>&1 || true
    settings delete global freeform_window_management >/dev/null 2>&1 || true
    settings delete global enable_non_resizable_multi_window >/dev/null 2>&1 || true
  fi
}

configure_android_desktop_flags

if [ -x "$ROOT/android-ui-preferences-root.sh" ]; then
  "$ROOT/android-ui-preferences-root.sh" || true
fi

keep_android_helium_awake() {
  package=${HELIUM_ANDROID_PACKAGE:-computer.helium.sync}

  cmd activity set-inactive "$package" false >/dev/null 2>&1 || true
  cmd activity set-standby-bucket "$package" active >/dev/null 2>&1 || true
  cmd activity set-bg-restriction-level "$package" unrestricted >/dev/null 2>&1 || true
  cmd deviceidle whitelist +"$package" >/dev/null 2>&1 || true
  cmd appops set "$package" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set "$package" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set "$package" WAKE_LOCK allow >/dev/null 2>&1 || true
  cmd activity unfreeze --sticky "$package" >/dev/null 2>&1 || true

  pid=$(pidof "$package" 2>/dev/null | awk '{ print $1 }')
  [ -z "$pid" ] || cmd activity unfreeze --sticky "$pid" >/dev/null 2>&1 || true
}

keep_android_helium_awake

start_termux_x11_activity() {
  target_display_id=0
  if [ -f "$DISPLAY_TARGET" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
  fi

  if [ -n "${target_display_id:-}" ] && [ "${target_display_id:-0}" != 0 ]; then
    am start --user 0 --display "$target_display_id" -n com.termux.x11/.MainActivity >/dev/null 2>&1 ||
      am start --user 0 -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
  else
    am start --user 0 -n com.termux.x11/.MainActivity >/dev/null 2>&1 || true
  fi
}

if [ "${ARCH_X11_OPEN_ACTIVITY:-1}" != 0 ]; then
  start_termux_x11_activity
fi

set_termux_x11_preferences() {
  pref="$TERMUX_PREFIX/bin/termux-x11-preference"
  [ -x "$pref" ] || return 0

  display_resolution_args="displayResolutionMode:native"
  if [ -f "$DISPLAY_TARGET" ]; then
    target_x11_resolution=
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
    if [ -n "${target_x11_resolution:-}" ]; then
      display_resolution_args="displayResolutionMode:custom displayResolutionCustom:${target_x11_resolution}"
    fi
  fi

  /debug_ramdisk/su -mm -g "$TERMUX_UID" -G 3003 "$TERMUX_UID" -c "export HOME=$TERMUX_HOME PREFIX=$TERMUX_PREFIX PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin; /system/bin/timeout -k 1 5 termux-x11-preference touchMode:Trackpad scaleTouchpad:true pointerCapture:true transformCapturedPointer:at capturedPointerSpeedFactor:125 hardwareKbdScancodesWorkaround:true filterOutWinkey:false showMouseHelper:false showAdditionalKbd:false additionalKbdVisible:false useTermuxEKBarBehaviour:false fullscreen:true $display_resolution_args" >/dev/null 2>&1
}

for _ in 1 2 3 4 5; do
  set_termux_x11_preferences && break
  if [ "${ARCH_X11_OPEN_ACTIVITY:-1}" != 0 ]; then
    start_termux_x11_activity
  fi
  sleep 1
done

: > "$LOG"
chown "$TERMUX_UID:$TERMUX_UID" "$LOG" 2>/dev/null || true
chmod 666 "$LOG" 2>/dev/null || true

umount -l "$ROOT/tmp/.X11-unix" >/dev/null 2>&1 || true
rm -rf "$ROOT/tmp/.X11-unix" "$ROOT/tmp/.X1-lock" >/dev/null 2>&1 || true
/system/bin/pkill -f '[t]ermux-x11 com.termux.x11 :1' >/dev/null 2>&1 || true

/debug_ramdisk/su -mm -g "$TERMUX_UID" -G 3003 "$TERMUX_UID" -c "export HOME=$TERMUX_HOME PREFIX=$TERMUX_PREFIX TMPDIR=$ROOT/tmp PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin LANG=C.UTF-8 TERMUX_X11_DEBUG=1; cd $TERMUX_HOME; termux-x11 :1 -ac -dpi ${ARCH_X11_DPI:-120} -fakescreenfps ${ARCH_X11_FPS:-10} >>$LOG 2>&1" </dev/null >/dev/null 2>&1 &

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -S "$ROOT/tmp/.X11-unix/X1" ] && break
  sleep 1
done

chroot "$ROOT" /usr/bin/env -i \
  HOME=/root \
	  USER=root \
	  LOGNAME=root \
	  SHELL=/bin/zsh \
	  DISPLAY=:1 \
	  BROWSER=/root/.config/x11/bin/chromium-helium-local \
	  TERMINAL=/root/.local/bin/zutty \
	  GTK_THEME=Adwaita:dark \
	  QT_QPA_PLATFORMTHEME=qt5ct \
	  QT_STYLE_OVERRIDE=Breeze \
	  XDG_CURRENT_DESKTOP=xmonad \
	  XDG_SESSION_DESKTOP=xmonad \
	  XDG_SESSION_TYPE=x11 \
	  XDG_RUNTIME_DIR=/tmp/runtime-root \
	  XDG_CONFIG_HOME=/root/.config \
  XDG_DATA_HOME=/root/.local/share \
  XDG_CACHE_HOME=/root/.cache \
  LANG=C.utf8 \
  LC_CTYPE=C.utf8 \
	  TERM=xterm-256color \
		  PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/root/.cabal/bin:/root/.ghcup/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
		  /bin/bash -lc 'mkdir -p /tmp/runtime-root /root/.config/xmonad /root/.cache/xmonad /root/.local/share/xmonad /root/.local/state/x11 /root/Downloads; chmod 700 /tmp/runtime-root; rm -rf /root/.xmonad; xrdb -merge /root/.config/Xresources || true; xsettingsd >>/root/.local/state/x11/xsettingsd.log 2>&1 & xsetroot -solid "#111111" || true; x11-apple-input-setup || true; x11-lorie-input-setup || true; x11-clip-watch >>/root/.local/state/x11/clip-watch.log 2>&1 & x11-phone-trackpad >>/root/.local/state/x11/phone-trackpad.log 2>&1 & xmonad --recompile || true; XMONAD_BIN=$(find /root/.cache/xmonad /root/.local/share/xmonad /root/.config/xmonad -maxdepth 1 -type f -name "xmonad-*" -perm -111 2>/dev/null | sort | tail -n 1); [ -n "$XMONAD_BIN" ] || exit 1; dbus-run-session -- sh -lc "exec \"$XMONAD_BIN\""' </dev/null >>"$LOG" 2>&1 &
