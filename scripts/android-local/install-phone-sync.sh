#!/usr/bin/env bash
set -euo pipefail

adb_bin=${ADB:-adb}
root=${ARCH_CHROOT:-/data/local/chroots/arch}
cookiecloud_ext=${COOKIECLOUD_EXT:-/tmp/cookiecloud-extension-chrome-mv3.tar.xz}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if [ ! -f "$cookiecloud_ext" ]; then
  COOKIECLOUD_EXT="$cookiecloud_ext" \
    "$repo_root/scripts/android-local/fetch-cookiecloud-extension.sh" >/dev/null
fi

GOOS=linux GOARCH=arm64 go build -o "$work_dir/helium-local-syncd" "$repo_root/cmd/helium-local-syncd"
GOOS=linux GOARCH=arm64 go build -o "$work_dir/helium-sync" "$repo_root/cmd/helium-sync"
GOOS=linux GOARCH=arm64 go build -o "$work_dir/helium-syncd" "$repo_root/cmd/helium-syncd"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "$work_dir/android-magic-keyboard-remap" "$repo_root/cmd/android-magic-keyboard-remap"
input_display_assoc_jar=$("$repo_root/scripts/android-local/build-input-display-assoc.sh")
connected_display_auto_enable_jar=$("$repo_root/scripts/android-local/build-connected-display-auto-enable.sh")
arch_desktop_apk=$("$repo_root/scripts/android-local/build-arch-desktop-controller.sh")
tar -C "$repo_root/browser-extensions/google-ai-overview-blocker" \
  -cf "$work_dir/google-ai-overview-blocker.tar" .
tar -C "$repo_root/browser-extensions/blank-new-tab-extension" \
  -cf "$work_dir/blank-new-tab-extension.tar" .
tar -C "$repo_root/browser-extensions/tab-pin-helper-extension" \
  -cf "$work_dir/tab-pin-helper-extension.tar" .

"$adb_bin" push "$work_dir/helium-local-syncd" /data/local/tmp/helium-local-syncd >/dev/null
"$adb_bin" push "$work_dir/helium-sync" /data/local/tmp/helium-sync >/dev/null
"$adb_bin" push "$work_dir/helium-syncd" /data/local/tmp/helium-syncd >/dev/null
"$adb_bin" push "$work_dir/android-magic-keyboard-remap" /data/local/tmp/android-magic-keyboard-remap >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-cookiecloud.mjs" /data/local/tmp/cdp-cookiecloud.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cookie-replication.mjs" /data/local/tmp/cookie-replication.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-password-sync.mjs" /data/local/tmp/cdp-password-sync.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/password-reconcile.mjs" /data/local/tmp/password-reconcile.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/start-helium-local-sync-root.sh" /data/local/tmp/start-helium-local-sync-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/chromium-helium-local-root.sh" /data/local/tmp/chromium-helium-local-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/helium-prepare-profile-root.py" /data/local/tmp/helium-prepare-profile-root.py >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/helium-cleanup-startup-tabs-root.py" /data/local/tmp/helium-cleanup-startup-tabs-root.py >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-display-mode-root.sh" /data/local/tmp/arch-desktop-display-mode-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-display-watch-root.sh" /data/local/tmp/arch-desktop-display-watch-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-session-watch-root.sh" /data/local/tmp/arch-desktop-session-watch-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-resume-root.sh" /data/local/tmp/arch-desktop-resume-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-hibernate-root.sh" /data/local/tmp/arch-desktop-hibernate-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/phone-thermal-guard-root.sh" /data/local/tmp/phone-thermal-guard-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-thermal-guard-root.sh" /data/local/tmp/arch-desktop-thermal-guard-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/arch-desktop-attach-root.sh" /data/local/tmp/arch-desktop-attach-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/android-ui-preferences-root.sh" /data/local/tmp/android-ui-preferences-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/chroot-tailnet-dns-root.sh" /data/local/tmp/chroot-tailnet-dns-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/fix-magic-keyboard-layout-root.sh" /data/local/tmp/fix-magic-keyboard-layout-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/x11-lorie-input-setup-root.sh" /data/local/tmp/x11-lorie-input-setup-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/x11-hibernate-hold-osd-root.sh" /data/local/tmp/x11-hibernate-hold-osd-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/xmonad-browser-zoom-fix-root.sh" /data/local/tmp/xmonad-browser-zoom-fix-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/xmonad-desktop-config-root.sh" /data/local/tmp/xmonad-desktop-config-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/android-raw-pointer-forwarder-root.sh" /data/local/tmp/android-raw-pointer-forwarder-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/android-magic-keyboard-remap-root.sh" /data/local/tmp/android-magic-keyboard-remap-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/fix-terminal-colors-root.sh" /data/local/tmp/fix-terminal-colors-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/restart-raw-pointer-root.sh" /data/local/tmp/restart-raw-pointer-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/merge-helium-laptop-extensions-root.sh" /data/local/tmp/merge-helium-laptop-extensions-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/purge-blocked-helium-extensions-root.sh" /data/local/tmp/purge-blocked-helium-extensions-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/input-display-assoc-root.sh" /data/local/tmp/input-display-assoc-root.sh >/dev/null
"$adb_bin" push "$input_display_assoc_jar" /data/local/tmp/input-display-assoc.jar >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/android-connected-display-auto-enable-root.sh" /data/local/tmp/android-connected-display-auto-enable-root.sh >/dev/null
"$adb_bin" push "$connected_display_auto_enable_jar" /data/local/tmp/connected-display-auto-enable.jar >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/helium-phone-ui-service-root.sh" /data/local/tmp/helium-phone-ui-service-root.sh >/dev/null
"$adb_bin" push "$arch_desktop_apk" /data/local/tmp/arch-desktop.apk >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/x11-phone-trackpad-server.mjs" /data/local/tmp/x11-phone-trackpad-server.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/x11-key-helper-root.sh" /data/local/tmp/x11-key-helper-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/wire-arch-desktop-display-mode-root.sh" /data/local/tmp/wire-arch-desktop-display-mode-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/start-arch-xmonad-root.sh" /data/local/tmp/start-arch-xmonad-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/stop-arch-x11-root.sh" /data/local/tmp/stop-arch-x11-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/termux-x11-session-focus-root.sh" /data/local/tmp/termux-x11-session-focus-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/seed-chroot-profile-root.sh" /data/local/tmp/seed-chroot-profile-root.sh >/dev/null
"$adb_bin" push "$cookiecloud_ext" /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz >/dev/null
"$adb_bin" push "$work_dir/google-ai-overview-blocker.tar" /data/local/tmp/google-ai-overview-blocker.tar >/dev/null
"$adb_bin" push "$work_dir/blank-new-tab-extension.tar" /data/local/tmp/blank-new-tab-extension.tar >/dev/null
"$adb_bin" push "$work_dir/tab-pin-helper-extension.tar" /data/local/tmp/tab-pin-helper-extension.tar >/dev/null

"$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
ROOT='"$root"'
CHROOT_USER=dhruv
CHROOT_HOME=/home/\$CHROOT_USER
CHROOT_UID=\$(awk -F: -v user=\"\$CHROOT_USER\" '\''\$1 == user { print \$3 }'\'' \"\$ROOT/etc/passwd\" 2>/dev/null || true)
CHROOT_GID=\$(awk -F: -v user=\"\$CHROOT_USER\" '\''\$1 == user { print \$4 }'\'' \"\$ROOT/etc/passwd\" 2>/dev/null || true)
install -Dm755 /data/local/tmp/helium-local-syncd \"\$ROOT/usr/local/bin/helium-local-syncd\"
install -Dm755 /data/local/tmp/helium-sync \"\$ROOT/usr/local/bin/helium-sync\"
install -Dm755 /data/local/tmp/helium-syncd \"\$ROOT/usr/local/bin/helium-syncd\"
install -Dm755 /data/local/tmp/android-magic-keyboard-remap \"\$ROOT/usr/local/bin/android-magic-keyboard-remap\"
install -Dm755 /data/local/tmp/cdp-cookiecloud.mjs \"\$ROOT/usr/local/bin/cdp-cookiecloud\"
install -Dm644 /data/local/tmp/cookie-replication.mjs \"\$ROOT/usr/local/bin/cookie-replication.mjs\"
install -Dm755 /data/local/tmp/cdp-password-sync.mjs \"\$ROOT/usr/local/bin/cdp-password-sync\"
install -Dm644 /data/local/tmp/password-reconcile.mjs \"\$ROOT/usr/local/bin/password-reconcile.mjs\"
install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/usr/local/bin/start-helium-local-sync\"
install -Dm755 /data/local/tmp/arch-desktop-display-mode-root.sh \"\$ROOT/arch-desktop-display-mode-root.sh\"
install -Dm755 /data/local/tmp/arch-desktop-display-watch-root.sh \"\$ROOT/arch-desktop-display-watch-root.sh\"
install -Dm755 /data/local/tmp/arch-desktop-session-watch-root.sh \"\$ROOT/arch-desktop-session-watch.sh\"
install -Dm755 /data/local/tmp/arch-desktop-resume-root.sh \"\$ROOT/arch-desktop-resume-root.sh\"
install -Dm755 /data/local/tmp/arch-desktop-hibernate-root.sh \"\$ROOT/arch-desktop-hibernate-root.sh\"
install -Dm755 /data/local/tmp/phone-thermal-guard-root.sh /data/local/helium-phone-thermal-guard-root.sh
install -Dm755 /data/local/tmp/arch-desktop-thermal-guard-root.sh \"\$ROOT/arch-desktop-thermal-guard-root.sh\"
install -Dm755 /data/local/tmp/arch-desktop-attach-root.sh \"\$ROOT/arch-desktop-attach-root.sh\"
install -Dm755 /data/local/tmp/android-ui-preferences-root.sh \"\$ROOT/android-ui-preferences-root.sh\"
install -Dm755 /data/local/tmp/chroot-tailnet-dns-root.sh \"\$ROOT/chroot-tailnet-dns-root.sh\"
install -Dm755 /data/local/tmp/fix-magic-keyboard-layout-root.sh \"\$ROOT/fix-magic-keyboard-layout-root.sh\"
install -Dm755 /data/local/tmp/x11-hibernate-hold-osd-root.sh \"\$ROOT/x11-hibernate-hold-osd-root.sh\"
install -Dm755 /data/local/tmp/xmonad-browser-zoom-fix-root.sh \"\$ROOT/xmonad-browser-zoom-fix-root.sh\"
install -Dm755 /data/local/tmp/xmonad-desktop-config-root.sh \"\$ROOT/xmonad-desktop-config-root.sh\"
install -Dm755 /data/local/tmp/android-raw-pointer-forwarder-root.sh \"\$ROOT/android-raw-pointer-forwarder-root.sh\"
install -Dm755 /data/local/tmp/android-magic-keyboard-remap-root.sh \"\$ROOT/android-magic-keyboard-remap-root.sh\"
install -Dm755 /data/local/tmp/fix-terminal-colors-root.sh \"\$ROOT/fix-terminal-colors-root.sh\"
install -Dm755 /data/local/tmp/restart-raw-pointer-root.sh \"\$ROOT/restart-raw-pointer-root.sh\"
install -Dm755 /data/local/tmp/merge-helium-laptop-extensions-root.sh \"\$ROOT/merge-helium-laptop-extensions-root.sh\"
install -Dm755 /data/local/tmp/purge-blocked-helium-extensions-root.sh \"\$ROOT/purge-blocked-helium-extensions-root.sh\"
install -Dm755 /data/local/tmp/input-display-assoc-root.sh \"\$ROOT/input-display-assoc-root.sh\"
install -Dm644 /data/local/tmp/input-display-assoc.jar \"\$ROOT/input-display-assoc.jar\"
install -Dm755 /data/local/tmp/android-connected-display-auto-enable-root.sh \"\$ROOT/android-connected-display-auto-enable-root.sh\"
install -Dm644 /data/local/tmp/connected-display-auto-enable.jar \"\$ROOT/connected-display-auto-enable.jar\"
install -Dm755 /data/local/tmp/helium-phone-ui-service-root.sh /data/adb/service.d/99-helium-phone-ui.sh
pm install -r /data/local/tmp/arch-desktop.apk >/dev/null
\"\$ROOT/android-ui-preferences-root.sh\"
/data/local/helium-phone-thermal-guard-root.sh start
\"\$ROOT/android-connected-display-auto-enable-root.sh\" restart
\"\$ROOT/chroot-tailnet-dns-root.sh\"
\"\$ROOT/fix-magic-keyboard-layout-root.sh\"
\"\$ROOT/input-display-assoc-root.sh\" apply
\"\$ROOT/xmonad-desktop-config-root.sh\"
\"\$ROOT/xmonad-browser-zoom-fix-root.sh\"
\"\$ROOT/fix-terminal-colors-root.sh\"
install -Dm755 /data/local/tmp/wire-arch-desktop-display-mode-root.sh \"\$ROOT/wire-arch-desktop-display-mode-root.sh\"
install -Dm755 /data/local/tmp/start-arch-xmonad-root.sh \"\$ROOT/start-arch-xmonad-root.sh\"
install -Dm755 /data/local/tmp/stop-arch-x11-root.sh \"\$ROOT/stop-arch-x11-root.sh\"
install -Dm755 /data/local/tmp/termux-x11-session-focus-root.sh \"\$ROOT/termux-x11-session-focus-root.sh\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension\"
rm -rf \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/root/.local/share/google-ai-overview-blocker\" \"\$ROOT/root/.local/share/blank-new-tab-extension\" \"\$ROOT/root/.local/share/tab-pin-helper-extension\" \"\$ROOT/root/.local/share/helium-local-pass\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\"
mkdir -p \"\$ROOT/root/.local/share/google-ai-overview-blocker\"
mkdir -p \"\$ROOT/root/.local/share/blank-new-tab-extension\"
mkdir -p \"\$ROOT/root/.local/share/tab-pin-helper-extension\"
cp /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz \"\$ROOT/tmp/cookiecloud-extension-chrome-mv3.tar.xz\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/cookiecloud-extension-chrome-mv3.tar.xz -C /root/.local/share/cookiecloud-extension/chrome-mv3
cp /data/local/tmp/google-ai-overview-blocker.tar \"\$ROOT/tmp/google-ai-overview-blocker.tar\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/google-ai-overview-blocker.tar -C /root/.local/share/google-ai-overview-blocker
cp /data/local/tmp/blank-new-tab-extension.tar \"\$ROOT/tmp/blank-new-tab-extension.tar\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/blank-new-tab-extension.tar -C /root/.local/share/blank-new-tab-extension
cp /data/local/tmp/tab-pin-helper-extension.tar \"\$ROOT/tmp/tab-pin-helper-extension.tar\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/tab-pin-helper-extension.tar -C /root/.local/share/tab-pin-helper-extension
chown -R 0:0 \"\$ROOT/root/.local/share/cookiecloud-extension\" \"\$ROOT/root/.local/share/google-ai-overview-blocker\" \"\$ROOT/root/.local/share/blank-new-tab-extension\" \"\$ROOT/root/.local/share/tab-pin-helper-extension\"
install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/root/.config/x11/bin/start-helium-local-sync\"
install -Dm755 /data/local/tmp/chromium-helium-local-root.sh \"\$ROOT/root/.config/x11/bin/chromium-helium-local\"
install -Dm755 /data/local/tmp/helium-prepare-profile-root.py \"\$ROOT/root/.config/x11/bin/helium-prepare-profile\"
install -Dm755 /data/local/tmp/helium-cleanup-startup-tabs-root.py \"\$ROOT/root/.config/x11/bin/helium-cleanup-startup-tabs\"
install -Dm755 /data/local/tmp/x11-phone-trackpad-server.mjs \"\$ROOT/root/.config/x11/bin/x11-phone-trackpad-server.mjs\"
install -Dm755 /data/local/tmp/x11-key-helper-root.sh \"\$ROOT/root/.local/bin/x11-key-helper\"
install -Dm755 /data/local/tmp/x11-lorie-input-setup-root.sh \"\$ROOT/root/.local/bin/x11-lorie-input-setup\"
install -Dm755 /data/local/tmp/seed-chroot-profile-root.sh \"\$ROOT/usr/local/bin/seed-helium-chroot-profile\"
if [ -n \"\$CHROOT_UID\" ] && [ -n \"\$CHROOT_GID\" ] && [ -d \"\$ROOT/\$CHROOT_HOME\" ]; then
  rm -rf \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\" \"\$ROOT/\$CHROOT_HOME/.local/share/blank-new-tab-extension\" \"\$ROOT/\$CHROOT_HOME/.local/share/tab-pin-helper-extension\"
  mkdir -p \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\" \"\$ROOT/\$CHROOT_HOME/.local/share/blank-new-tab-extension\" \"\$ROOT/\$CHROOT_HOME/.local/share/tab-pin-helper-extension\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/cookiecloud-extension-chrome-mv3.tar.xz -C \"\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/google-ai-overview-blocker.tar -C \"\$CHROOT_HOME/.local/share/google-ai-overview-blocker\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/blank-new-tab-extension.tar -C \"\$CHROOT_HOME/.local/share/blank-new-tab-extension\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/tab-pin-helper-extension.tar -C \"\$CHROOT_HOME/.local/share/tab-pin-helper-extension\"
  install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/start-helium-local-sync\"
  install -Dm755 /data/local/tmp/chromium-helium-local-root.sh \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/chromium-helium-local\"
  install -Dm755 /data/local/tmp/helium-prepare-profile-root.py \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/helium-prepare-profile\"
  install -Dm755 /data/local/tmp/helium-cleanup-startup-tabs-root.py \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/helium-cleanup-startup-tabs\"
  install -Dm755 /data/local/tmp/x11-phone-trackpad-server.mjs \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/x11-phone-trackpad-server.mjs\"
  install -Dm755 /data/local/tmp/x11-key-helper-root.sh \"\$ROOT/\$CHROOT_HOME/.local/bin/x11-key-helper\"
  install -Dm755 /data/local/tmp/x11-lorie-input-setup-root.sh \"\$ROOT/\$CHROOT_HOME/.local/bin/x11-lorie-input-setup\"
  for sync_dir in helium-sync helium-local-sync; do
    if [ -d \"\$ROOT/root/.local/share/\$sync_dir\" ]; then
      mkdir -p \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\"
      cp -a \"\$ROOT/root/.local/share/\$sync_dir/.\" \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir/\"
    fi
  done
  chown -R \"\$CHROOT_UID:\$CHROOT_GID\" \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\" \"\$ROOT/\$CHROOT_HOME/.local/share/blank-new-tab-extension\" \"\$ROOT/\$CHROOT_HOME/.local/share/tab-pin-helper-extension\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/start-helium-local-sync\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/chromium-helium-local\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/helium-prepare-profile\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/helium-cleanup-startup-tabs\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/x11-phone-trackpad-server.mjs\" \"\$ROOT/\$CHROOT_HOME/.local/bin/x11-key-helper\" \"\$ROOT/\$CHROOT_HOME/.local/bin/x11-lorie-input-setup\"
  for sync_dir in helium-sync helium-local-sync; do
    if [ -d \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\" ]; then
      chown -R \"\$CHROOT_UID:\$CHROOT_GID\" \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\"
    fi
  done
fi
"'
