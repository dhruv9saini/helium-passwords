#!/system/bin/sh
set -eu

# Keep app notification icons out of the status bar. Notifications still appear
# in the shade; this only removes the left-side status-bar glyphs.
cmd statusbar send-disable-flag notification-icons >/dev/null 2>&1 || true

# Termux:X11 is controlled by the Arch Desktop launcher. Its persistent
# notification is noisy on the phone display and can reappear after app updates.
if pm path com.termux.x11 >/dev/null 2>&1; then
  pm revoke com.termux.x11 android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  pm set-permission-flags com.termux.x11 android.permission.POST_NOTIFICATIONS user-set user-fixed >/dev/null 2>&1 || true
  cmd appops set com.termux.x11 POST_NOTIFICATION ignore >/dev/null 2>&1 || true
fi
