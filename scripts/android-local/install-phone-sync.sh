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
GOOS=linux GOARCH=arm64 go build -o "$work_dir/helium-syncd" "$repo_root/cmd/helium-syncd"

"$adb_bin" push "$work_dir/helium-local-syncd" /data/local/tmp/helium-local-syncd >/dev/null
"$adb_bin" push "$work_dir/helium-syncd" /data/local/tmp/helium-syncd >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-cookiecloud.mjs" /data/local/tmp/cdp-cookiecloud.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/cdp-password-sync.mjs" /data/local/tmp/cdp-password-sync.mjs >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/start-helium-local-sync-root.sh" /data/local/tmp/start-helium-local-sync-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/chromium-helium-local-root.sh" /data/local/tmp/chromium-helium-local-root.sh >/dev/null
"$adb_bin" push "$repo_root/scripts/android-local/seed-chroot-profile-root.sh" /data/local/tmp/seed-chroot-profile-root.sh >/dev/null
"$adb_bin" push "$cookiecloud_ext" /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz >/dev/null

"$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
ROOT='"$root"'
install -Dm755 /data/local/tmp/helium-local-syncd \"\$ROOT/usr/local/bin/helium-local-syncd\"
install -Dm755 /data/local/tmp/helium-syncd \"\$ROOT/usr/local/bin/helium-syncd\"
install -Dm755 /data/local/tmp/cdp-cookiecloud.mjs \"\$ROOT/usr/local/bin/cdp-cookiecloud\"
install -Dm755 /data/local/tmp/cdp-password-sync.mjs \"\$ROOT/usr/local/bin/cdp-password-sync\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension\"
rm -rf \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\" \"\$ROOT/root/.local/share/helium-local-pass\"
mkdir -p \"\$ROOT/root/.local/share/cookiecloud-extension/chrome-mv3\"
cp /data/local/tmp/cookiecloud-extension-chrome-mv3.tar.xz \"\$ROOT/tmp/cookiecloud-extension-chrome-mv3.tar.xz\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/cookiecloud-extension-chrome-mv3.tar.xz -C /root/.local/share/cookiecloud-extension/chrome-mv3
install -Dm755 /data/local/tmp/start-helium-local-sync-root.sh \"\$ROOT/root/.config/x11/bin/start-helium-local-sync\"
install -Dm755 /data/local/tmp/chromium-helium-local-root.sh \"\$ROOT/root/.config/x11/bin/chromium-helium-local\"
install -Dm755 /data/local/tmp/seed-chroot-profile-root.sh \"\$ROOT/usr/local/bin/seed-helium-chroot-profile\"
"'
