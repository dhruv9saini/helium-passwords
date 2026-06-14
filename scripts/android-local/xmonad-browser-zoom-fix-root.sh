#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}

/system/bin/chroot "$ROOT" /usr/bin/env \
  HOME=/root \
  TMPDIR=/tmp \
  DISPLAY=:1 \
  XDG_RUNTIME_DIR=/tmp/runtime-root \
  PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/root/.cabal/bin:/root/.ghcup/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
sh -lc '
export TMPDIR=/tmp
file=/root/.config/xmonad/xmonad.hs
[ -f "$file" ] || exit 0
mkdir -p /tmp /root/.cache/xmonad/build-aarch64-linux
chmod 1777 /tmp 2>/dev/null || true
cp -p "$file" "$file.before-browser-zoom-fix.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
sed -i \
  -e "/(\"C-=\", zoomTerminal/d" \
  -e "/(\"C-S-=\", zoomTerminal/d" \
  -e "/(\"C-<KP_Add>\", zoomTerminal/d" \
  -e "/(\"C--\", zoomTerminal/d" \
  -e "/(\"C-<KP_Subtract>\", zoomTerminal/d" \
  -e "/(\"C-0\", zoomTerminal/d" \
  "$file"
xmonad --recompile || true
xmonad --restart || true
'
