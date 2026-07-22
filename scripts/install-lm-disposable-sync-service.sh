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
tls_root=$state_root/tls
endpoint_env=$config_root/endpoint.env
unit_root=$user_home/.config/systemd/user
backup_root=/srv/nas/helium-sync-server-disposable
sync_cli=$binary_root/helium-sync
service=helium-syncd-disposable.service
backup_timer=helium-sync-server-backup-disposable.timer
tls_port=44719

require_synthetic_marker() {
  [[ -f "$state_root/SYNTHETIC_ONLY" && ! -L "$state_root/SYNTHETIC_ONLY" &&
      "$(cat "$state_root/SYNTHETIC_ONLY")" == synthetic-only-v1 ]] || {
    echo "synthetic-only state marker is missing or invalid" >&2
    return 1
  }
}

verify_user_manager() {
  [[ -S "$XDG_RUNTIME_DIR/bus" ]] || {
    echo "the user systemd bus is unavailable: $XDG_RUNTIME_DIR/bus" >&2
    return 1
  }
  systemctl --user is-system-running >/dev/null
  [[ "$(loginctl show-user "$user_name" -p Linger --value)" == yes ]] || {
    echo "user lingering must be enabled for durable synthetic supervision" >&2
    return 1
  }
}

tailscale_identity() {
  local status
  status=$(tailscale status --json)
  jq -e '
    .BackendState == "Running" and .Self.Online == true and
    (.Self.DNSName | type == "string" and endswith(".ts.net.")) and
    ([.Self.TailscaleIPs[] | select(test("^[0-9]+\\."))] | length == 1)
  ' <<<"$status" >/dev/null || {
    echo "lm must have one online Tailscale IPv4 identity and a .ts.net name" >&2
    return 1
  }
  tls_hostname=$(jq -er '.Self.DNSName | rtrimstr(".")' <<<"$status")
  tls_ip=$(jq -er '[.Self.TailscaleIPs[] | select(test("^[0-9]+\\."))][0]' <<<"$status")
}

verify_no_tailscale_proxy() {
  jq -e 'type == "object" and length == 0' \
    <<<"$(tailscale serve status --json)" >/dev/null || {
    echo "Tailscale Serve must remain empty for direct TLS" >&2
    return 1
  }
  jq -e 'type == "object" and length == 0' \
    <<<"$(tailscale funnel status --json)" >/dev/null || {
    echo "Tailscale Funnel must remain empty for Helium Sync" >&2
    return 1
  }
}

read_endpoint_config() {
  [[ -f "$endpoint_env" && ! -L "$endpoint_env" ]] || {
    echo "endpoint configuration is missing: $endpoint_env" >&2
    return 1
  }
  mapfile -t endpoint_lines <"$endpoint_env"
  [[ ${#endpoint_lines[@]} -eq 3 ]] || {
    echo "endpoint configuration must contain exactly three lines" >&2
    return 1
  }
  configured_listen=${endpoint_lines[0]#HELIUM_SYNC_LISTEN=}
  configured_hostname=${endpoint_lines[1]#HELIUM_SYNC_TLS_HOSTNAME=}
  configured_ip=${endpoint_lines[2]#HELIUM_SYNC_TLS_IP=}
  [[ "${endpoint_lines[0]}" == "HELIUM_SYNC_LISTEN=$configured_listen" &&
      "${endpoint_lines[1]}" == "HELIUM_SYNC_TLS_HOSTNAME=$configured_hostname" &&
      "${endpoint_lines[2]}" == "HELIUM_SYNC_TLS_IP=$configured_ip" ]] || {
    echo "endpoint configuration keys or order are invalid" >&2
    return 1
  }
}

verify_endpoint() {
  require_synthetic_marker
  verify_user_manager
  tailscale_identity
  verify_no_tailscale_proxy
  read_endpoint_config
  [[ "$configured_listen" == "$tls_ip:$tls_port" &&
      "$configured_hostname" == "$tls_hostname" &&
      "$configured_ip" == "$tls_ip" ]] || {
    echo "installed endpoint identity does not match lm's live Tailscale identity" >&2
    return 1
  }
  [[ -L "$tls_root/current" ]] || {
    echo "current disposable TLS generation is missing" >&2
    return 1
  }
  current_target=$(readlink "$tls_root/current")
  [[ "$current_target" =~ ^generations/[0-9a-f]{64}$ ]] || {
    echo "current disposable TLS generation link is invalid" >&2
    return 1
  }
  [[ ! -e "$tls_root/current/ca-key.pem" ]] || {
    echo "CA private key must not be present on lm" >&2
    return 1
  }
  "$sync_cli" tls-server-verify \
    --ca-cert "$tls_root/current/ca-cert.pem" \
    --server-cert "$tls_root/current/server-cert.pem" \
    --server-key "$tls_root/current/server-key.pem" \
    --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h
}

verify_live_endpoint() {
  tailscale_identity
  local response
  response=$(curl --fail --silent --show-error --max-time 10 \
    --tlsv1.3 --tls-max 1.3 \
    --cacert "$tls_root/current/ca-cert.pem" \
    --resolve "$tls_hostname:$tls_port:$tls_ip" \
    "https://$tls_hostname:$tls_port/v2/health")
  jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
    echo "direct TLS health response is invalid" >&2
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
      /tmp/helium-sync-restore.disposable.*) [ ! -e "$target" ] || find "$target" -depth -delete ;;
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

case "$action" in
  install-source)
    verify_user_manager
    systemctl --user is-active --quiet "$service" && {
      echo "refusing source install while $service is active" >&2
      exit 1
    }
    temp_dir=$(mktemp -d /tmp/helium-sync-disposable-install.XXXXXX)
    cleanup_install() { find "$temp_dir" -depth -delete; }
    trap cleanup_install EXIT
    go build -trimpath -o "$temp_dir/helium-syncd" "$repo_root/cmd/helium-syncd"
    go build -trimpath -o "$temp_dir/helium-sync" "$repo_root/cmd/helium-sync"
    install -d -m0700 "$binary_root" "$state_root" "$config_root" \
      "$tls_root/generations" "$unit_root"
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
    [[ $# -eq 4 ]] || {
      echo "usage: $0 install-endpoint CA_CERT SERVER_CERT SERVER_KEY" >&2
      exit 2
    }
    require_synthetic_marker
    ca_source=$(realpath -e "$2")
    cert_source=$(realpath -e "$3")
    key_source=$(realpath -e "$4")
    tailscale_identity
    verify_no_tailscale_proxy
    systemctl --user is-active --quiet "$service" && {
      echo "refusing endpoint install while $service is active" >&2
      exit 1
    }
    "$sync_cli" tls-server-verify --ca-cert "$ca_source" \
      --server-cert "$cert_source" --server-key "$key_source" \
      --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h >/dev/null
    generation=$(sha256sum "$cert_source" | awk '{print $1}')
    [[ "$generation" =~ ^[0-9a-f]{64}$ ]]
    final_generation=$tls_root/generations/$generation
    [[ ! -e "$final_generation" ]] || {
      echo "refusing to replace disposable TLS generation: $final_generation" >&2
      exit 1
    }
    incoming=$(mktemp -d "$tls_root/generations/.incoming.XXXXXX")
    endpoint_temp=$(mktemp "$config_root/.endpoint.XXXXXX")
    cleanup_endpoint() {
      [[ ! -e "$endpoint_temp" ]] || find "$endpoint_temp" -delete
      [[ -z "${incoming:-}" || ! -e "$incoming" ]] || find "$incoming" -depth -delete
    }
    trap cleanup_endpoint EXIT
    chmod 0700 "$incoming"
    install -m0644 "$ca_source" "$incoming/ca-cert.pem"
    install -m0644 "$cert_source" "$incoming/server-cert.pem"
    install -m0600 "$key_source" "$incoming/server-key.pem"
    "$sync_cli" tls-server-verify --ca-cert "$incoming/ca-cert.pem" \
      --server-cert "$incoming/server-cert.pem" --server-key "$incoming/server-key.pem" \
      --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h >/dev/null
    sync "$incoming/ca-cert.pem" "$incoming/server-cert.pem" "$incoming/server-key.pem"
    mv "$incoming" "$final_generation"
    incoming=
    printf 'HELIUM_SYNC_LISTEN=%s:%s\nHELIUM_SYNC_TLS_HOSTNAME=%s\nHELIUM_SYNC_TLS_IP=%s\n' \
      "$tls_ip" "$tls_port" "$tls_hostname" "$tls_ip" >"$endpoint_temp"
    chmod 0600 "$endpoint_temp"
    mv "$endpoint_temp" "$endpoint_env"
    current_incoming=$tls_root/.current.$$
    ln -s "generations/$generation" "$current_incoming"
    mv -Tf "$current_incoming" "$tls_root/current"
    sync "$tls_root" "$config_root"
    trap - EXIT
    verify_endpoint >/dev/null
    echo "disposable_endpoint_installed=inactive"
    ;;
  initialize)
    bootstrap=${2:-}
    [[ -f "$bootstrap" ]] || {
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
  verify-endpoint)
    verify_endpoint
    echo "disposable_direct_tls_endpoint=verified"
    ;;
  verify-live-endpoint)
    verify_endpoint >/dev/null
    verify_live_endpoint
    echo "disposable_direct_tls_endpoint=live"
    ;;
  enable)
    require_synthetic_marker
    [[ -s "$server_root/devices.json" ]] || {
      echo "synthetic server registry is not initialized" >&2
      exit 1
    }
    systemctl is-active --quiet helium-syncd.service && {
      echo "root-owned helium-syncd.service is already active" >&2
      exit 1
    }
    ss -ltnH "( sport = :$tls_port )" | grep -q . && {
      echo "port $tls_port already has a listener" >&2
      exit 1
    }
    verify_endpoint >/dev/null
    perform_backup_drill >/dev/null
    systemctl --user enable --now "$service"
    if ! wait_live_endpoint; then
      systemctl --user disable --now "$service"
      echo "disposable service stopped because its TLS health gate failed" >&2
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
    echo "usage: $0 <install-source|install-endpoint CA CERT KEY|initialize BOOTSTRAP|backup-drill|verify-endpoint|verify-live-endpoint|enable|disable|status>" >&2
    exit 2
    ;;
esac
