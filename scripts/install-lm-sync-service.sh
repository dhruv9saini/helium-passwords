#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
action=${1:-}

case "$action" in
  install-source)
    temp_dir=$(mktemp -d /tmp/helium-syncd-install.XXXXXX)
    cleanup() { find "$temp_dir" -depth -delete; }
    trap cleanup EXIT
    go build -trimpath -o "$temp_dir/helium-syncd" "$repo_root/cmd/helium-syncd"
    go build -trimpath -o "$temp_dir/helium-sync" "$repo_root/cmd/helium-sync"
    sudo install -Dm0644 "$repo_root/sysusers.d/helium-sync.conf" /usr/lib/sysusers.d/helium-sync.conf
    sudo systemd-sysusers /usr/lib/sysusers.d/helium-sync.conf
    sudo install -Dm0755 "$temp_dir/helium-syncd" /usr/local/libexec/helium-syncd
    sudo install -Dm0755 "$temp_dir/helium-sync" /usr/local/libexec/helium-sync
    sudo install -Dm0644 "$repo_root/systemd/helium-syncd.service" /etc/systemd/system/helium-syncd.service
    sudo systemctl daemon-reload
    echo "installed=inactive"
    ;;
  initialize)
    bootstrap=${2:-}
    [ -f "$bootstrap" ] || {
      echo "usage: $0 initialize /path/to/d-server-bootstrap.json" >&2
      exit 2
    }
    [ ! -e /var/lib/helium-sync/devices.json ] || {
      echo "refusing to replace an existing server registry" >&2
      exit 1
    }
    sudo install -d -m0700 -o helium-sync -g helium-sync /var/lib/helium-sync
    sudo -u helium-sync /usr/local/libexec/helium-sync server-init \
      --data-dir /var/lib/helium-sync \
      --devices-file /var/lib/helium-sync/devices.json \
      --bootstrap-file "$(realpath -e "$bootstrap")"
    echo "initialized=inactive"
    ;;
  enable)
    [ -s /var/lib/helium-sync/devices.json ] || {
      echo "server registry is not initialized" >&2
      exit 1
    }
    tailscale serve status --json | jq -e \
      '.. | strings | select(test("127\\.0\\.0\\.1:44719"))' >/dev/null || {
      echo "Tailscale HTTPS Serve is not forwarding to 127.0.0.1:44719" >&2
      exit 1
    }
    sudo systemctl enable --now helium-syncd.service
    ;;
  status)
    systemctl --no-pager --full status helium-syncd.service
    tailscale serve status
    ;;
  *)
    echo "usage: $0 <install-source|initialize BOOTSTRAP|enable|status>" >&2
    exit 2
    ;;
esac
