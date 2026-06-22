#!/system/bin/sh
set -eu

chroot_dir=${CHROOT_DIR:-/data/local/chroots/arch}

kill_matching() {
  local pattern=$1
  local pid

  pgrep -f "$pattern" 2>/dev/null | while read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
      $$) continue ;;
    esac
    kill -TERM "$pid" 2>/dev/null || true
  done
}

kill_matching '^bash /root/.config/x11/bin/chromium-helium-local'
kill_matching '^/opt/helium-sync/helium'
kill_matching '^helium-passwords'

i=0
while [ "$i" -lt 10 ]; do
  if ! pgrep -f '/opt/helium-sync/helium\|helium-passwords' >/dev/null 2>&1; then
    break
  fi
  sleep 1
  i=$((i + 1))
done

kill_matching '^/opt/helium-sync/helium'
kill_matching '^helium-passwords'

chroot "$chroot_dir" /bin/sh -lc '
  mkdir -p /tmp/runtime-root /root/.local/state/helium-sync
  chmod 700 /tmp/runtime-root
  nohup env \
    DISPLAY="${DISPLAY:-:1}" \
    HOME=/root \
    USER=root \
    SHELL=/bin/zsh \
    XDG_RUNTIME_DIR=/tmp/runtime-root \
    PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/root/.cabal/bin:/root/.ghcup/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl \
    /root/.config/x11/bin/chromium-helium-local \
    >>/root/.local/state/helium-sync/chromium-helium-local.restart.log 2>&1 &
'
