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
    sudo install -Dm0755 "$repo_root/scripts/helium-sync-server-backup.sh" /usr/local/libexec/helium-sync-server-backup
    sudo install -Dm0644 "$repo_root/systemd/helium-syncd.service" /etc/systemd/system/helium-syncd.service
    sudo install -Dm0644 "$repo_root/systemd/helium-sync-server-backup.service" /etc/systemd/system/helium-sync-server-backup.service
    sudo install -Dm0644 "$repo_root/systemd/helium-sync-server-backup.timer" /etc/systemd/system/helium-sync-server-backup.timer
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
  backup-drill)
    [ -s /var/lib/helium-sync/devices.json ] || {
      echo "server registry is not initialized" >&2
      exit 1
    }
    backup_output=$(sudo /usr/local/libexec/helium-sync-server-backup \
      backup /srv/nas/helium-sync-server)
    archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$backup_output")
    archive_sha=$(awk -F= '$1 == "sha256" {print $2}' <<<"$backup_output")
    target="/tmp/helium-sync-restore.$(date +%s).$$"
    cleanup_restore() {
      case "$target" in
        /tmp/helium-sync-restore.*) [ ! -e "$target" ] || sudo find "$target" -depth -delete ;;
      esac
    }
    trap cleanup_restore EXIT
    sudo /usr/local/libexec/helium-sync-server-backup restore-drill \
      "$archive" "$target" >/dev/null
    receipt=/srv/nas/helium-sync-server/last-restore-drill.env
    sudo sh -c 'umask 077; printf "archive=%s\narchive_sha256=%s\nverified_at=%s\n" "$1" "$2" "$3" >"$4.incoming"; sync "$4.incoming"; mv "$4.incoming" "$4"' \
      sh "$archive" "$archive_sha" "$(date --iso-8601=seconds)" "$receipt"
    cleanup_restore
    trap - EXIT
    echo "backup_restore_drill=passed"
    ;;
  enable)
    [ -s /var/lib/helium-sync/devices.json ] || {
      echo "server registry is not initialized" >&2
      exit 1
    }
    [ -s /srv/nas/helium-sync-server/last-restore-drill.env ] || {
      echo "server backup restore drill has not passed" >&2
      exit 1
    }
    tailscale serve status --json | jq -e \
      '.. | strings | select(test("127\\.0\\.0\\.1:44719"))' >/dev/null || {
      echo "Tailscale HTTPS Serve is not forwarding to 127.0.0.1:44719" >&2
      exit 1
    }
    sudo systemctl enable --now helium-syncd.service
    sudo systemctl enable --now helium-sync-server-backup.timer
    ;;
  status)
    systemctl --no-pager --full status helium-syncd.service
    tailscale serve status
    ;;
  *)
    echo "usage: $0 <install-source|initialize BOOTSTRAP|backup-drill|enable|status>" >&2
    exit 2
    ;;
esac
