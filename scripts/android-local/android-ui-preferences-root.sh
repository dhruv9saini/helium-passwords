#!/system/bin/sh
set -eu

# Keep app notification icons out of the status bar. Notifications still appear
# in the shade; this only removes the left-side status-bar glyphs.
cmd statusbar send-disable-flag notification-icons >/dev/null 2>&1 || true

# Keep Android willing to place apps on external displays. Do not call
# `cmd display enable-display` here; on Android 16/crDroid that can retrigger
# the mirror/extend prompt on every Arch Desktop attach.
settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
settings put global force_allow_on_external 1 >/dev/null 2>&1 || true

# Termux:X11 is controlled by the Arch Desktop launcher. Its persistent
# notification is noisy on the phone display and can reappear after app updates.
if pm path com.termux.x11 >/dev/null 2>&1; then
  pm revoke com.termux.x11 android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  pm set-permission-flags com.termux.x11 android.permission.POST_NOTIFICATIONS user-set user-fixed >/dev/null 2>&1 || true
  cmd appops set com.termux.x11 POST_NOTIFICATION ignore >/dev/null 2>&1 || true
fi
