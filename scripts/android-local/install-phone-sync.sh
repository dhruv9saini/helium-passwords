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
tar -C "$repo_root/browser-extensions/google-ai-overview-blocker" \
  -cf "$work_dir/google-ai-overview-blocker.tar" .

"$adb_bin" push "$work_dir/helium-local-syncd" /data/local/tmp/helium-local-syncd >/dev/null
"$adb_bin" push "$work_dir/helium-sync" /data/local/tmp/helium-sync >/dev/null
"$adb_bin" push "$work_dir/helium-syncd" /data/local/tmp/helium-syncd >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-cookiecloud.mjs" /data/local/tmp/cdp-cookiecloud.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-password-sync.mjs" /data/local/tmp/cdp-password-sync.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/start-helium-local-sync-root.sh" /data/local/tmp/start-helium-local-sync-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/chromium-helium-local-root.sh" /data/local/tmp/chromium-helium-local-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/seed-chroot-profile-root.sh" /data/local/tmp/seed-chroot-profile-root.sh >/dev/null
"$adb_bin" push "$cookiecloud_ext" /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz >/dev/null
"$adb_bin" push "$work_dir/google-ai-overview-blocker.tar" /data/local/tmp/google-ai-overview-blocker.tar >/dev/null

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
install -Dm755 /data/local/tmp/cdp-cookiecloud.mjs \"\$ROOT/usr/local/bin/cdp-cookiecloud\"
install -Dm755 /data/local/tmp/cdp-password-sync.mjs \"\$ROOT/usr/local/bin/cdp-password-sync\"
install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/usr/local/bin/start-helium-local-sync\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension\"
rm -rf \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/root/.local/share/google-ai-overview-blocker\" \"\$ROOT/root/.local/share/helium-local-pass\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\"
mkdir -p \"\$ROOT/root/.local/share/google-ai-overview-blocker\"
cp /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz \"\$ROOT/tmp/cookiecloud-extension-chrome-mv3.tar.xz\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/cookiecloud-extension-chrome-mv3.tar.xz -C /root/.local/share/cookiecloud-extension/chrome-mv3
cp /data/local/tmp/google-ai-overview-blocker.tar \"\$ROOT/tmp/google-ai-overview-blocker.tar\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/google-ai-overview-blocker.tar -C /root/.local/share/google-ai-overview-blocker
chown -R 0:0 \"\$ROOT/root/.local/share/cookiecloud-extension\" \"\$ROOT/root/.local/share/google-ai-overview-blocker\"
install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/root/.config/x11/bin/start-helium-local-sync\"
install -Dm755 /data/local/tmp/chromium-helium-local-root.sh \"\$ROOT/root/.config/x11/bin/chromium-helium-local\"
install -Dm755 /data/local/tmp/seed-chroot-profile-root.sh \"\$ROOT/usr/local/bin/seed-helium-chroot-profile\"
if [ -n \"\$CHROOT_UID\" ] && [ -n \"\$CHROOT_GID\" ] && [ -d \"\$ROOT/\$CHROOT_HOME\" ]; then
  rm -rf \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\"
  mkdir -p \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/cookiecloud-extension-chrome-mv3.tar.xz -C \"\$CHROOT_HOME/.local/share/cookiecloud-extension/chrome-mv3\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/google-ai-overview-blocker.tar -C \"\$CHROOT_HOME/.local/share/google-ai-overview-blocker\"
  install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/start-helium-local-sync\"
  install -Dm755 /data/local/tmp/chromium-helium-local-root.sh \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/chromium-helium-local\"
  for sync_dir in helium-sync helium-local-sync; do
    if [ -d \"\$ROOT/root/.local/share/\$sync_dir\" ]; then
      mkdir -p \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\"
      cp -a \"\$ROOT/root/.local/share/\$sync_dir/.\" \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir/\"
    fi
  done
  chown -R \"\$CHROOT_UID:\$CHROOT_GID\" \"\$ROOT/\$CHROOT_HOME/.local/share/cookiecloud-extension\" \"\$ROOT/\$CHROOT_HOME/.local/share/google-ai-overview-blocker\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/start-helium-local-sync\" \"\$ROOT/\$CHROOT_HOME/.config/x11/bin/chromium-helium-local\"
  for sync_dir in helium-sync helium-local-sync; do
    if [ -d \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\" ]; then
      chown -R \"\$CHROOT_UID:\$CHROOT_GID\" \"\$ROOT/\$CHROOT_HOME/.local/share/\$sync_dir\"
    fi
  done
fi
"'
