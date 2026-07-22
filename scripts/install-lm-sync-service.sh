#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
action=${1:-}
sync_cli=${HELIUM_SYNC_CLI:-/usr/local/libexec/helium-sync}
tls_root=${HELIUM_SYNC_TLS_ROOT:-/etc/helium-sync/tls}
endpoint_env=${HELIUM_SYNC_ENDPOINT_ENV:-/etc/helium-sync/endpoint.env}
tls_port=44719

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
  local serve_status funnel_status
  serve_status=$(tailscale serve status --json)
  funnel_status=$(tailscale funnel status --json)
  jq -e 'type == "object" and length == 0' <<<"$serve_status" >/dev/null || {
    echo "Tailscale Serve must remain empty for the direct TLS endpoint" >&2
    return 1
  }
  jq -e 'type == "object" and length == 0' <<<"$funnel_status" >/dev/null || {
    echo "Tailscale Funnel must remain empty for Helium Sync" >&2
    return 1
  }
}

read_endpoint_config() {
  [[ -f "$endpoint_env" && ! -L "$endpoint_env" ]] || {
    echo "endpoint configuration is missing or not a regular file: $endpoint_env" >&2
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
    echo "current TLS generation is missing" >&2
    return 1
  }
  current_target=$(readlink "$tls_root/current")
  [[ "$current_target" =~ ^generations/[0-9a-f]{64}$ ]] || {
    echo "current TLS generation link is invalid" >&2
    return 1
  }
  "$sync_cli" tls-server-verify \
    --ca-cert "$tls_root/current/ca-cert.pem" \
    --server-cert "$tls_root/current/server-cert.pem" \
    --server-key "$tls_root/current/server-key.pem" \
    --hostname "$tls_hostname" --ip "$tls_ip" \
    --minimum-validity 720h
}

verify_live_endpoint() {
  tailscale_identity
  local response
  response=$(curl --fail --silent --show-error --max-time 10 \
    --cacert "$tls_root/current/ca-cert.pem" \
    --resolve "$tls_hostname:$tls_port:$tls_ip" \
    "https://$tls_hostname:$tls_port/v2/health")
  jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
    echo "direct TLS health response is invalid" >&2
    return 1
  }
}

perform_backup_drill() (
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
)

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
  install-endpoint)
    [[ $# -eq 4 ]] || {
      echo "usage: $0 install-endpoint /path/ca-cert.pem /path/server-cert.pem /path/server-key.pem" >&2
      exit 2
    }
    ca_source=$(realpath -e "$2")
    cert_source=$(realpath -e "$3")
    key_source=$(realpath -e "$4")
    tailscale_identity
    verify_no_tailscale_proxy
    systemctl is-active --quiet helium-syncd.service && {
      echo "refusing TLS generation install while helium-syncd is active" >&2
      exit 1
    }
    verify_output=$("$sync_cli" tls-server-verify \
      --ca-cert "$ca_source" --server-cert "$cert_source" \
      --server-key "$key_source" --hostname "$tls_hostname" --ip "$tls_ip" \
      --minimum-validity 720h)
    generation=$(sha256sum "$cert_source" | awk '{print $1}')
    [[ "$generation" =~ ^[0-9a-f]{64}$ ]]
    final_generation="$tls_root/generations/$generation"
    sudo test ! -e "$final_generation" || {
      echo "refusing to replace existing TLS generation: $final_generation" >&2
      exit 1
    }
    sudo install -d -m0700 -o helium-sync -g helium-sync "$tls_root/generations"
    incoming=$(sudo mktemp -d "$tls_root/generations/.incoming.XXXXXX")
    endpoint_temp=$(mktemp /tmp/helium-sync-endpoint.XXXXXX)
    cleanup_endpoint() {
      rm -f "$endpoint_temp"
      [[ -z "${incoming:-}" ]] || sudo find "$incoming" -depth -delete 2>/dev/null || true
    }
    trap cleanup_endpoint EXIT
    sudo chown helium-sync:helium-sync "$incoming"
    sudo chmod 0700 "$incoming"
    sudo install -m0644 -o helium-sync -g helium-sync "$ca_source" "$incoming/ca-cert.pem"
    sudo install -m0644 -o helium-sync -g helium-sync "$cert_source" "$incoming/server-cert.pem"
    sudo install -m0600 -o helium-sync -g helium-sync "$key_source" "$incoming/server-key.pem"
    sudo -u helium-sync "$sync_cli" tls-server-verify \
      --ca-cert "$incoming/ca-cert.pem" \
      --server-cert "$incoming/server-cert.pem" \
      --server-key "$incoming/server-key.pem" \
      --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h >/dev/null
    sudo sync "$incoming/ca-cert.pem" "$incoming/server-cert.pem" "$incoming/server-key.pem"
    sudo mv "$incoming" "$final_generation"
    incoming=
    printf 'HELIUM_SYNC_LISTEN=%s:%s\nHELIUM_SYNC_TLS_HOSTNAME=%s\nHELIUM_SYNC_TLS_IP=%s\n' \
      "$tls_ip" "$tls_port" "$tls_hostname" "$tls_ip" >"$endpoint_temp"
    sudo install -d -m0755 -o root -g root "$(dirname "$endpoint_env")"
    sudo install -m0644 -o root -g root "$endpoint_temp" "$endpoint_env.incoming"
    sudo mv -T "$endpoint_env.incoming" "$endpoint_env"
    current_incoming="$tls_root/.current.$$"
    sudo ln -s "generations/$generation" "$current_incoming"
    sudo mv -Tf "$current_incoming" "$tls_root/current"
    sudo sync "$tls_root" "$(dirname "$endpoint_env")"
    trap - EXIT
    cleanup_endpoint
    printf '%s\n' "$verify_output"
    verify_endpoint >/dev/null
    echo "endpoint_installed=inactive"
    echo "endpoint_url=https://$tls_hostname:$tls_port"
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
    perform_backup_drill
    ;;
  verify-endpoint)
    verify_endpoint
    echo "direct_tls_endpoint=verified"
    ;;
  verify-live-endpoint)
    verify_endpoint >/dev/null
    verify_live_endpoint
    echo "direct_tls_endpoint=live"
    ;;
  enable)
    [ -s /var/lib/helium-sync/devices.json ] || {
      echo "server registry is not initialized" >&2
      exit 1
    }
    verify_endpoint >/dev/null
    perform_backup_drill >/dev/null
    sudo systemctl enable --now helium-syncd.service
    if ! verify_live_endpoint; then
      sudo systemctl disable --now helium-syncd.service
      echo "helium-syncd was stopped because the direct TLS health gate failed" >&2
      exit 1
    fi
    sudo systemctl enable --now helium-sync-server-backup.timer
    ;;
  status)
    systemctl --no-pager --full status helium-syncd.service
    verify_endpoint
    verify_live_endpoint
    ;;
  *)
    echo "usage: $0 <install-source|install-endpoint CA CERT KEY|initialize BOOTSTRAP|backup-drill|verify-endpoint|verify-live-endpoint|enable|status>" >&2
    exit 2
    ;;
esac
