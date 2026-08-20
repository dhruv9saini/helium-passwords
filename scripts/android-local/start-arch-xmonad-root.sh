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
  target_android_display_mode=native
  if [ -f "$DISPLAY_TARGET" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
  fi

  if [ "${target_source:-native}" = external ] && [ "${target_android_display_mode:-mirror}" = extended ]; then
    settings put global force_desktop_mode_on_external_displays 1 || true
    settings put global force_allow_on_external 1 || true
    settings put global enable_freeform_support 1 || true
    settings put global force_resizable_activities 1 || true
    settings put global freeform_window_management 1 || true
    settings put global enable_non_resizable_multi_window 1 || true
  else
    settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
    settings put global force_allow_on_external 1 >/dev/null 2>&1 || true
    settings put global enable_freeform_support 0 >/dev/null 2>&1 || true
    settings put global force_resizable_activities 0 >/dev/null 2>&1 || true
    settings put global freeform_window_management 0 >/dev/null 2>&1 || true
    settings put global enable_non_resizable_multi_window 0 >/dev/null 2>&1 || true
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

tailscale_vpn_active() {
  ip route get 100.100.100.100 2>/dev/null | grep -q ' dev tun'
}

ensure_tailscale_vpn() {
  [ "${ARCH_X11_TAILSCALE_CONNECT:-1}" != 0 ] || return 0

  package=${TAILSCALE_ANDROID_PACKAGE:-com.tailscale.ipn}
  pm path "$package" >/dev/null 2>&1 || return 0

  cmd activity set-inactive "$package" false >/dev/null 2>&1 || true
  cmd activity set-standby-bucket "$package" active >/dev/null 2>&1 || true
  cmd activity set-bg-restriction-level "$package" unrestricted >/dev/null 2>&1 || true
  cmd deviceidle whitelist +"$package" >/dev/null 2>&1 || true
  cmd appops set "$package" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set "$package" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
  cmd appops set "$package" WAKE_LOCK allow >/dev/null 2>&1 || true
  cmd appops set "$package" ACTIVATE_VPN allow >/dev/null 2>&1 || true
  cmd appops set "$package" ESTABLISH_VPN_SERVICE allow >/dev/null 2>&1 || true

  tailscale_vpn_active && return 0

  am broadcast --user 0 -a "${package}.CONNECT_VPN" -p "$package" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    tailscale_vpn_active && return 0
    sleep 1
  done
}

ensure_tailscale_vpn >>"$LOG" 2>&1 || true

if [ "${ARCH_X11_OPEN_ACTIVITY:-1}" != 0 ]; then
  "$ROOT/termux-x11-session-focus-root.sh" >>"$LOG" 2>&1 || true
fi

if [ "${ARCH_X11_MAGIC_KEYBOARD_REMAP:-1}" != 0 ] && [ -x "$ROOT/android-magic-keyboard-remap-root.sh" ]; then
  "$ROOT/android-magic-keyboard-remap-root.sh" start >>"$LOG" 2>&1 || true
fi

if [ -x "$ROOT/input-display-assoc-root.sh" ]; then
  "$ROOT/input-display-assoc-root.sh" apply >>"$LOG" 2>&1 || true
fi

open_phone_trackpad_activity() {
  target_source=native
  if [ -f "$DISPLAY_TARGET" ]; then
    # shellcheck disable=SC1090
    . "$DISPLAY_TARGET" 2>/dev/null || true
  fi

  [ "${target_source:-native}" = external ] || return 0
  [ "${target_android_display_mode:-mirror}" = extended ] || return 0
  [ "${ARCH_X11_WEB_TRACKPAD:-0}" = 1 ] || return 0

  port=${X11_PHONE_TRACKPAD_PORT:-8765}
  url="http://127.0.0.1:${port}/?sensitivity=${X11_PHONE_TRACKPAD_SENSITIVITY:-2.35}&scroll=${X11_PHONE_TRACKPAD_SCROLL_SENSITIVITY:-0.08}"
  (
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      /system/bin/curl -fsS --max-time 1 "$url" >/dev/null 2>&1 && break
      sleep 1
    done
    am start --user 0 --display 0 -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 || true
  ) &
}

: > "$LOG"
chown "$TERMUX_UID:$TERMUX_UID" "$LOG" 2>/dev/null || true
chmod 666 "$LOG" 2>/dev/null || true

umount -l "$ROOT/tmp/.X11-unix" >/dev/null 2>&1 || true
rm -rf "$ROOT/tmp/.X11-unix" "$ROOT/tmp/.X1-lock" >/dev/null 2>&1 || true
/system/bin/pkill -f '[t]ermux-x11 com.termux.x11 :1' >/dev/null 2>&1 || true

/debug_ramdisk/su -mm -g "$TERMUX_UID" -G 3003 "$TERMUX_UID" -c "export HOME=$TERMUX_HOME PREFIX=$TERMUX_PREFIX TMPDIR=$ROOT/tmp PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin LANG=C.UTF-8 TERMUX_X11_DEBUG=1; cd $TERMUX_HOME; termux-x11 :1 -ac -dpi ${ARCH_X11_DPI:-96} -fakescreenfps ${ARCH_X11_FPS:-10} >>$LOG 2>&1" </dev/null >/dev/null 2>&1 &

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -S "$ROOT/tmp/.X11-unix/X1" ] && break
  sleep 1
done

if [ "${ARCH_X11_RAW_POINTER:-0}" != 0 ] && [ -x "$ROOT/android-raw-pointer-forwarder-root.sh" ]; then
  /system/bin/pkill -f '[a]ndroid-raw-pointer-forwarder-root.sh' >/dev/null 2>&1 || true
  /system/bin/pkill -f '[g]etevent -l /dev/input/event' >/dev/null 2>&1 || true
  nohup "$ROOT/android-raw-pointer-forwarder-root.sh" >>"$LOG" 2>&1 &
else
  /system/bin/pkill -f '[a]ndroid-raw-pointer-forwarder-root.sh' >/dev/null 2>&1 || true
  /system/bin/pkill -f '[g]etevent -l /dev/input/event' >/dev/null 2>&1 || true
fi

reapply_x11_input_setup() {
  (
    for delay in 2 5 10; do
      sleep "$delay"
      [ -S "$ROOT/tmp/.X11-unix/X1" ] || continue
      /system/bin/chroot "$ROOT" /usr/bin/env \
        DISPLAY=:1 \
        XDG_RUNTIME_DIR=/tmp/runtime-root \
        PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
        sh -lc 'x11-apple-input-setup >/dev/null 2>&1 || true; x11-lorie-input-setup >/dev/null 2>&1 || true'
    done
  ) >>"$LOG" 2>&1 &
}

reapply_x11_input_setup

chroot "$ROOT" /usr/bin/env -i \
  HOME=/root \
	  USER=root \
	  LOGNAME=root \
	  SHELL=/bin/zsh \
	  DISPLAY=:1 \
	  BROWSER=/root/.config/x11/bin/chromium-helium-local \
	  TERMINAL=alacritty \
	  GTK_THEME=Adwaita:dark \
	  QT_QPA_PLATFORMTHEME=qt5ct \
	  QT_STYLE_OVERRIDE=Breeze \
	  XDG_CURRENT_DESKTOP=xmonad \
	  XDG_SESSION_DESKTOP=xmonad \
	  XDG_SESSION_TYPE=x11 \
	  XDG_RUNTIME_DIR=/tmp/runtime-root \
	  TMPDIR=/tmp \
	  XDG_CONFIG_HOME=/root/.config \
  XDG_DATA_HOME=/root/.local/share \
  XDG_CACHE_HOME=/root/.cache \
  ARCH_X11_TRACKPAD_TOKEN="${ARCH_X11_TRACKPAD_TOKEN:-}" \
  X11_PHONE_TRACKPAD_HOST="${X11_PHONE_TRACKPAD_HOST:-}" \
  LANG=C.utf8 \
  LC_CTYPE=C.utf8 \
		  TERM=xterm-256color \
		  PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/root/.cabal/bin:/root/.ghcup/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  /bin/bash -lc 'mkdir -p /tmp/runtime-root /root/.config/xmonad /root/.cache/xmonad /root/.local/share/xmonad /root/.local/state/x11 /root/Downloads; chmod 700 /tmp/runtime-root; rm -rf /root/.xmonad; xrdb -merge /root/.config/Xresources || true; xsettingsd >>/root/.local/state/x11/xsettingsd.log 2>&1 & xsetroot -solid "#111111" || true; x11-apple-input-setup || true; x11-lorie-input-setup || true; x11-clip-watch >>/root/.local/state/x11/clip-watch.log 2>&1 & if [ "${ARCH_X11_PHONE_TRACKPAD_SERVER:-0}" = 1 ] || [ "${ARCH_X11_WEB_TRACKPAD:-0}" = 1 ]; then trackpad_host="${X11_PHONE_TRACKPAD_HOST:-127.0.0.1}"; if [ -n "${ARCH_X11_TRACKPAD_TOKEN:-}" ] && [ -z "${X11_PHONE_TRACKPAD_HOST:-}" ]; then trackpad_host=0.0.0.0; fi; X11_PHONE_TRACKPAD_HOST="$trackpad_host" X11_PHONE_TRACKPAD_TOKEN="${ARCH_X11_TRACKPAD_TOKEN:-}" X11_PHONE_TRACKPAD_SENSITIVITY="${X11_PHONE_TRACKPAD_SENSITIVITY:-2.35}" X11_PHONE_TRACKPAD_SCROLL_SENSITIVITY="${X11_PHONE_TRACKPAD_SCROLL_SENSITIVITY:-0.08}" x11-phone-trackpad >>/root/.local/state/x11/phone-trackpad.log 2>&1 & fi; find_xmonad_bin() { find /root/.cache/xmonad /root/.local/share/xmonad /root/.config/xmonad -maxdepth 1 -type f -name "xmonad-*" -perm -111 2>/dev/null | sort | tail -n 1; }; XMONAD_BIN=$(find_xmonad_bin); if [ -z "$XMONAD_BIN" ] || [ /root/.config/xmonad/xmonad.hs -nt "$XMONAD_BIN" ] || [ "${ARCH_X11_RECOMPILE:-0}" = 1 ]; then xmonad --recompile || true; XMONAD_BIN=$(find_xmonad_bin); fi; [ -n "$XMONAD_BIN" ] || exit 1; dbus-run-session -- sh -lc "exec \"$XMONAD_BIN\""' </dev/null >>"$LOG" 2>&1 &

open_phone_trackpad_activity
