#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
action=${1:-}
user_id=$(id -u)
user_name=$(id -un)
user_home=$(getent passwd "$user_id" | cut -d: -f6)
[[ -n "$user_home" && "$user_home" == /* ]] || {
  echo "cannot resolve the current user's absolute home" >&2
  exit 1
}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$user_id}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

binary_root=$user_home/.local/share/helium-sync-disposable/bin
state_root=$user_home/.local/state/helium-sync-disposable
server_root=$state_root/server
config_root=$state_root/config
endpoint_env=$config_root/endpoint.env
unit_root=$user_home/.config/systemd/user
backup_root=/srv/nas/helium-sync-server-disposable
sync_cli=$binary_root/helium-sync
service=helium-syncd-disposable.service
backup_timer=helium-sync-server-backup-disposable.timer
sync_port=44719

case "$action" in
  install-source|install-endpoint|initialize|backup-drill|enroll-device|revoke-device|enable|disable)
    exec 8>"$XDG_RUNTIME_DIR/helium-sync-disposable.operator.lock"
    chmod 0600 "$XDG_RUNTIME_DIR/helium-sync-disposable.operator.lock"
    flock -n 8 || {
      echo "another Helium Sync disposable operator action is running" >&2
      exit 1
    }
    ;;
esac

require_synthetic_marker() {
  [[ -f "$state_root/SYNTHETIC_ONLY" && ! -L "$state_root/SYNTHETIC_ONLY" &&
      "$(cat "$state_root/SYNTHETIC_ONLY")" == synthetic-only-v1 ]] || {
    echo "synthetic-only state marker is missing or invalid" >&2
    return 1
  }
}

verify_user_manager() {
  local manager_state
  [[ -S "$XDG_RUNTIME_DIR/bus" ]] || {
    echo "the user systemd bus is unavailable: $XDG_RUNTIME_DIR/bus" >&2
    return 1
  }
  manager_state=$(systemctl --user is-system-running 2>/dev/null || true)
  [[ "$manager_state" == running || "$manager_state" == degraded ]] || {
    echo "the user systemd manager is not operational: $manager_state" >&2
    return 1
  }
  [[ "$(loginctl show-user "$user_name" -p Linger --value)" == yes ]] || {
    echo "user lingering must be enabled for durable synthetic supervision" >&2
    return 1
  }
}

tailscale_identity() {
  local status
  status=$(tailscale status --json)
  sync_ip=$(jq -er '
    if .BackendState == "Running" and .Self.Online == true then
      [.Self.TailscaleIPs[] | select(test("^100\\."))] |
      if length == 1 then .[0] else error("expected one Tailscale IPv4") end
    else error("Tailscale is not online")
    end
  ' <<<"$status")
  sync_listen=$sync_ip:$sync_port
}

read_endpoint_config() {
  [[ -f "$endpoint_env" && ! -L "$endpoint_env" ]] || {
    echo "endpoint configuration is missing: $endpoint_env" >&2
    return 1
  }
  mapfile -t endpoint_lines <"$endpoint_env"
  [[ ${#endpoint_lines[@]} -eq 1 &&
      "${endpoint_lines[0]}" == HELIUM_SYNC_LISTEN=* ]] || {
    echo "endpoint configuration must contain only HELIUM_SYNC_LISTEN" >&2
    return 1
  }
  configured_listen=${endpoint_lines[0]#HELIUM_SYNC_LISTEN=}
}

verify_endpoint() {
  require_synthetic_marker
  verify_user_manager
  tailscale_identity
  read_endpoint_config
  [[ "$configured_listen" == "$sync_listen" ]] || {
    echo "installed endpoint does not match lm's live Tailscale IPv4" >&2
    return 1
  }
}

verify_live_endpoint() {
  tailscale_identity
  local response
  response=$(curl --fail --silent --show-error --max-time 10 \
    --noproxy '*' "http://$sync_listen/v2/health")
  jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
    echo "private Tailnet health response is invalid" >&2
    return 1
  }
}

wait_live_endpoint() {
  local attempt
  for attempt in {1..50}; do
    if verify_live_endpoint 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  verify_live_endpoint
}

perform_backup_drill() (
  require_synthetic_marker
  [[ -s "$server_root/devices.json" ]] || {
    echo "synthetic server registry is not initialized" >&2
    exit 1
  }
  findmnt -M /srv/nas >/dev/null || {
    echo "/srv/nas is not mounted" >&2
    exit 1
  }
  install -d -m0700 "$backup_root"
  backup_output=$(HELIUM_SERVER_DATA_DIR="$server_root" \
    HELIUM_SERVER_SERVICE="$service" HELIUM_SERVER_SERVICE_SCOPE=user \
    HELIUM_SYNC_CLI="$sync_cli" \
    "$binary_root/helium-sync-server-backup" backup "$backup_root")
  archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$backup_output")
  archive_sha=$(awk -F= '$1 == "sha256" {print $2}' <<<"$backup_output")
  target="/tmp/helium-sync-restore.disposable.$(date +%s).$$"
  cleanup_restore() {
    case "$target" in
      /tmp/helium-sync-restore.disposable.*)
        [[ ! -e "$target" ]] || find "$target" -depth -delete
        ;;
    esac
  }
  trap cleanup_restore EXIT
  HELIUM_SERVER_DATA_DIR="$server_root" HELIUM_SERVER_SERVICE=none \
    HELIUM_SYNC_CLI="$sync_cli" \
    "$binary_root/helium-sync-server-backup" restore-drill \
    "$archive" "$target" >/dev/null
  receipt=$backup_root/last-restore-drill.env
  receipt_temp=$receipt.incoming
  (umask 077; printf 'archive=%s\narchive_sha256=%s\nverified_at=%s\n' \
    "$archive" "$archive_sha" "$(date --iso-8601=seconds)" >"$receipt_temp")
  sync "$receipt_temp"
  mv "$receipt_temp" "$receipt"
  cleanup_restore
  trap - EXIT
  echo "disposable_backup_restore_drill=passed"
)

perform_registry_update() (
  require_synthetic_marker
  [[ -s "$server_root/devices.json" ]] || {
    echo "synthetic server registry is not initialized" >&2
    exit 1
  }
  was_active=false
  if systemctl --user is-active --quiet "$service"; then
    systemctl --user stop "$service"
    was_active=true
  fi
  restart_service() {
    if [[ "$was_active" == true ]]; then
      systemctl --user start "$service" || true
    fi
  }
  trap restart_service EXIT INT TERM
  "$sync_cli" "$@"
  "$sync_cli" server-verify --data-dir "$server_root" \
    --devices-file "$server_root/devices.json" >/dev/null
  trap - EXIT INT TERM
  if [[ "$was_active" == true ]]; then
    systemctl --user start "$service"
    if ! wait_live_endpoint; then
      systemctl --user stop "$service"
      echo "disposable service stopped because the registry reload health gate failed" >&2
      exit 1
    fi
  fi
)

case "$action" in
  install-source)
    [[ $# -eq 1 ]] || exit 2
    verify_user_manager
    ! systemctl --user is-active --quiet "$service" || {
      echo "refusing source install while $service is active" >&2
      exit 1
    }
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/helium-sync-disposable-install.XXXXXX")
    cleanup_install() { find "$temp_dir" -depth -delete; }
    trap cleanup_install EXIT
    go build -trimpath -o "$temp_dir/helium-syncd" "$repo_root/cmd/helium-syncd"
    go build -trimpath -o "$temp_dir/helium-sync" "$repo_root/cmd/helium-sync"
    install -d -m0700 "$binary_root" "$state_root" "$config_root" "$unit_root"
    marker_temp=$state_root/.SYNTHETIC_ONLY.incoming
    (umask 077; printf 'synthetic-only-v1\n' >"$marker_temp")
    mv "$marker_temp" "$state_root/SYNTHETIC_ONLY"
    install -m0755 "$temp_dir/helium-syncd" "$binary_root/helium-syncd"
    install -m0755 "$temp_dir/helium-sync" "$binary_root/helium-sync"
    install -m0755 "$repo_root/scripts/helium-sync-server-backup.sh" \
      "$binary_root/helium-sync-server-backup"
    install -m0644 "$repo_root/systemd/helium-syncd-disposable.service" \
      "$unit_root/helium-syncd-disposable.service"
    install -m0644 "$repo_root/systemd/helium-sync-server-backup-disposable.service" \
      "$unit_root/helium-sync-server-backup-disposable.service"
    install -m0644 "$repo_root/systemd/helium-sync-server-backup-disposable.timer" \
      "$unit_root/helium-sync-server-backup-disposable.timer"
    systemctl --user daemon-reload
    cleanup_install
    trap - EXIT
    echo "disposable_source_installed=inactive"
    ;;
  install-endpoint)
    [[ $# -eq 1 ]] || {
      echo "usage: $0 install-endpoint" >&2
      exit 2
    }
    require_synthetic_marker
    tailscale_identity
    ! systemctl --user is-active --quiet "$service" || {
      echo "refusing endpoint install while $service is active" >&2
      exit 1
    }
    install -d -m0700 "$config_root"
    endpoint_temp=$(mktemp "$config_root/.endpoint.XXXXXX")
    printf 'HELIUM_SYNC_LISTEN=%s\n' "$sync_listen" >"$endpoint_temp"
    chmod 0600 "$endpoint_temp"
    mv "$endpoint_temp" "$endpoint_env"
    sync "$config_root"
    verify_endpoint >/dev/null
    printf 'disposable_endpoint_installed=inactive\nendpoint_url=http://%s\n' \
      "$sync_listen"
    ;;
  initialize)
    bootstrap=${2:-}
    [[ $# -eq 2 && -f "$bootstrap" ]] || {
      echo "usage: $0 initialize SYNTHETIC_BOOTSTRAP" >&2
      exit 2
    }
    require_synthetic_marker
    [[ ! -e "$server_root/devices.json" ]] || {
      echo "refusing to replace the disposable server registry" >&2
      exit 1
    }
    install -d -m0700 "$server_root"
    "$sync_cli" server-init --data-dir "$server_root" \
      --devices-file "$server_root/devices.json" \
      --bootstrap-file "$(realpath -e "$bootstrap")" >/dev/null
    echo "disposable_server_initialized=inactive"
    ;;
  backup-drill)
    perform_backup_drill
    ;;
  enroll-device)
    [[ $# -eq 2 && -f "$2" ]] || {
      echo "usage: $0 enroll-device HASHED_AUTH_REQUEST" >&2
      exit 2
    }
    perform_registry_update server-enroll \
      --devices-file "$server_root/devices.json" \
      --auth-request-file "$(realpath -e "$2")"
    echo "disposable_device_enrolled=service_reloaded"
    ;;
  revoke-device)
    [[ $# -eq 2 && -n "$2" ]] || {
      echo "usage: $0 revoke-device DEVICE" >&2
      exit 2
    }
    perform_registry_update server-revoke \
      --devices-file "$server_root/devices.json" --device "$2"
    echo "disposable_device_revoked=service_reloaded"
    ;;
  verify-endpoint)
    verify_endpoint
    echo "disposable_tailnet_endpoint=verified"
    ;;
  verify-live-endpoint)
    verify_endpoint >/dev/null
    verify_live_endpoint
    echo "disposable_tailnet_endpoint=live"
    ;;
  enable)
    require_synthetic_marker
    [[ -s "$server_root/devices.json" ]] || {
      echo "synthetic server registry is not initialized" >&2
      exit 1
    }
    ! systemctl is-active --quiet helium-syncd.service || {
      echo "root-owned helium-syncd.service is already active" >&2
      exit 1
    }
    tailscale_identity
    ! ss -ltnH "( sport = :$sync_port )" | grep -q . || {
      echo "port $sync_port already has a listener" >&2
      exit 1
    }
    verify_endpoint >/dev/null
    perform_backup_drill >/dev/null
    systemctl --user enable --now "$service"
    if ! wait_live_endpoint; then
      systemctl --user disable --now "$service"
      echo "disposable service stopped because its Tailnet health gate failed" >&2
      exit 1
    fi
    systemctl --user enable --now "$backup_timer"
    echo "disposable_service=enabled"
    ;;
  disable)
    systemctl --user disable --now "$backup_timer" "$service"
    echo "disposable_service=disabled"
    echo "state_preserved=$state_root"
    ;;
  status)
    systemctl --user --no-pager --full status "$service"
    verify_endpoint >/dev/null
    verify_live_endpoint
    ;;
  *)
    echo "usage: $0 <install-source|install-endpoint|initialize BOOTSTRAP|backup-drill|enroll-device AUTH_REQUEST|revoke-device DEVICE|verify-endpoint|verify-live-endpoint|enable|disable|status>" >&2
    exit 2
    ;;
esac
