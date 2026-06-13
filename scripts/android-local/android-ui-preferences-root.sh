#!/system/bin/sh
set -eu

# Keep app notification icons out of the status bar. Notifications still appear
# in the shade; this only removes the left-side status-bar glyphs.
cmd statusbar send-disable-flag notification-icons >/dev/null 2>&1 || true

# Keep external displays enabled without repeated mirror/desktop prompts. Arch
# Desktop decides when to place Termux:X11 on the external display.
settings put global force_desktop_mode_on_external_displays 1 >/dev/null 2>&1 || true
settings put global force_allow_on_external 1 >/dev/null 2>&1 || true
for display_id in $(cmd display get-displays --ids-only 2>/dev/null); do
  [ "$display_id" = 0 ] && continue
  cmd display enable-display "$display_id" >/dev/null 2>&1 || true
done

# Termux:X11 is controlled by the Arch Desktop launcher. Its persistent
# notification is noisy on the phone display and can reappear after app updates.
if pm path com.termux.x11 >/dev/null 2>&1; then
  pm revoke com.termux.x11 android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  pm set-permission-flags com.termux.x11 android.permission.POST_NOTIFICATIONS user-set user-fixed >/dev/null 2>&1 || true
  cmd appops set com.termux.x11 POST_NOTIFICATION ignore >/dev/null 2>&1 || true
fi
