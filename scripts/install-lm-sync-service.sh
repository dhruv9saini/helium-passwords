#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
script_path=$(realpath -e "${BASH_SOURCE[0]}")
action=${1:-}
release_root=${HELIUM_SYNC_RELEASE_ROOT:-/usr/local/libexec/helium-sync-releases}
unit_root=${HELIUM_SYNC_UNIT_ROOT:-/etc/systemd/system}
sync_cli=${HELIUM_SYNC_CLI:-$release_root/current/helium-sync}
backup_cli=$release_root/current/helium-sync-server-backup
tls_root=${HELIUM_SYNC_TLS_ROOT:-/etc/helium-sync/tls}
tls_port=44719
source_units=(
  helium-syncd.service
  helium-sync-server-backup.service
  helium-sync-server-backup-archive.service
  helium-sync-server-backup.timer
)
operator_lock=${HELIUM_SYNC_OPERATOR_LOCK:-/run/helium-sync-operator.lock}

case "$action" in
  install-source|rollback-source|install-endpoint|rollback-endpoint|initialize|backup-drill|enroll-device|revoke-device|verify-endpoint|verify-live-endpoint|enable|disable|status)
    if [[ $EUID -ne 0 ]]; then
      exec sudo "$script_path" "$@"
    fi
    [[ "$operator_lock" == /* ]] || {
      echo "production operator lock path must be absolute" >&2
      exit 2
    }
    exec 8>"$operator_lock"
    chmod 0600 "$operator_lock"
    flock -n 8 || {
      echo "another Helium Sync production operator action is running" >&2
      exit 1
    }
    ;;
esac

receipt_value() {
  local receipt=$1 key=$2
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$receipt"
}

verify_receipt_shape() {
  local receipt=$1
  shift
  local -a lines=( ) keys=("$@")
  local index value
  mapfile -t lines <"$receipt"
  [[ ${#lines[@]} -eq ${#keys[@]} ]] || {
    echo "receipt field count is invalid: $receipt" >&2
    return 1
  }
  for index in "${!keys[@]}"; do
    value=${lines[$index]#*=}
    [[ -n "$value" && "${lines[$index]}" == "${keys[$index]}=$value" ]] || {
      echo "receipt key order is invalid: $receipt" >&2
      return 1
    }
  done
}

verify_source_generation() {
  local generation=$1 generation_root receipt file key expected actual
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid source generation: $generation" >&2
    return 1
  }
  generation_root=$release_root/generations/$generation
  receipt=$generation_root/source.env
  [[ -d "$generation_root" && ! -L "$generation_root" &&
      -f "$receipt" && ! -L "$receipt" ]] || {
    echo "source generation is missing or unsafe: $generation" >&2
    return 1
  }
  verify_receipt_shape "$receipt" \
    schema_version source_commit source_tree public_backbone_commit go_version \
    module_identity_sha256 build_command build_target built_at \
    helium_sync_sha256 helium_sync_buildinfo_sha256 \
    helium_syncd_sha256 helium_syncd_buildinfo_sha256 \
    endpoint_health_sha256 backup_sha256 backup_control_sha256 \
    sysusers_sha256 sync_unit_sha256 backup_unit_sha256 archive_unit_sha256 \
    backup_timer_sha256
  [[ $(sha256sum "$receipt" | awk '{print $1}') == "$generation" &&
      $(receipt_value "$receipt" schema_version) == 1 &&
      $(receipt_value "$receipt" source_commit) =~ ^[0-9a-f]{40}$ &&
      $(receipt_value "$receipt" source_tree) =~ ^[0-9a-f]{40}$ &&
      $(receipt_value "$receipt" public_backbone_commit) =~ ^[0-9a-f]{40}$ &&
      $(receipt_value "$receipt" module_identity_sha256) =~ ^[0-9a-f]{64}$ &&
      $(receipt_value "$receipt" build_target) == linux/amd64 ]] || {
    echo "source generation receipt identity is invalid" >&2
    return 1
  }
  while IFS='|' read -r file key; do
    [[ -f "$generation_root/$file" && ! -L "$generation_root/$file" ]] || {
      echo "source generation file is missing or unsafe: $file" >&2
      return 1
    }
    expected=$(receipt_value "$receipt" "$key")
    actual=$(sha256sum "$generation_root/$file" | awk '{print $1}')
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || {
      echo "source generation hash mismatch: $file" >&2
      return 1
    }
  done <<'EOF'
helium-sync|helium_sync_sha256
helium-sync.buildinfo|helium_sync_buildinfo_sha256
helium-syncd|helium_syncd_sha256
helium-syncd.buildinfo|helium_syncd_buildinfo_sha256
helium-sync-endpoint-health|endpoint_health_sha256
helium-sync-server-backup|backup_sha256
helium-sync-server-backup-control|backup_control_sha256
helium-sync.conf|sysusers_sha256
helium-syncd.service|sync_unit_sha256
helium-sync-server-backup.service|backup_unit_sha256
helium-sync-server-backup-archive.service|archive_unit_sha256
helium-sync-server-backup.timer|backup_timer_sha256
EOF
}

verify_source() {
  [[ -L "$release_root/current" ]] || {
    echo "current source generation is missing" >&2
    return 1
  }
  local target generation unit expected_link
  target=$(readlink "$release_root/current")
  [[ "$target" =~ ^generations/([0-9a-f]{64})$ ]] || {
    echo "current source generation link is invalid" >&2
    return 1
  }
  generation=${BASH_REMATCH[1]}
  verify_source_generation "$generation"
  for unit in "${source_units[@]}"; do
    expected_link=$release_root/current/$unit
    [[ -L "$unit_root/$unit" && $(readlink "$unit_root/$unit") == "$expected_link" ]] || {
      echo "installed systemd unit does not follow the current source generation: $unit" >&2
      return 1
    }
  done
  printf 'source_generation=%s\n' "$generation"
}

activate_source_generation() {
  local generation=$1 current_temp unit unit_temp
  verify_source_generation "$generation"
  current_temp=$release_root/.current.$$
  ln -s "generations/$generation" "$current_temp"
  mv -Tf "$current_temp" "$release_root/current"
  install -d -m0755 -o root -g root "$unit_root"
  for unit in "${source_units[@]}"; do
    unit_temp=$unit_root/.$unit.$$
    ln -s "$release_root/current/$unit" "$unit_temp"
    mv -Tf "$unit_temp" "$unit_root/$unit"
  done
  sync "$release_root" "$unit_root"
  systemctl daemon-reload
  verify_source >/dev/null
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
  local config=$1
  [[ -f "$config" && ! -L "$config" ]] || {
    echo "endpoint configuration is missing or not a regular file: $config" >&2
    return 1
  }
  mapfile -t endpoint_lines <"$config"
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

verify_tls_generation() {
  local generation=$1 generation_root receipt key file expected actual
  local source_generation source_cli_hash
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid TLS generation: $generation" >&2
    return 1
  }
  generation_root=$tls_root/generations/$generation
  receipt=$generation_root/generation.env
  [[ -d "$generation_root" && ! -L "$generation_root" &&
      -f "$receipt" && ! -L "$receipt" ]] || {
    echo "TLS generation or provenance receipt is missing: $generation" >&2
    return 1
  }
  verify_receipt_shape "$receipt" schema_version generation hostname ip listen \
    source_generation helium_sync_sha256 ca_cert_sha256 server_cert_sha256 \
    server_key_sha256 endpoint_env_sha256 installed_at
  source_generation=$(receipt_value "$receipt" source_generation)
  [[ "$source_generation" =~ ^[0-9a-f]{64}$ ]] || {
    echo "TLS generation source provenance is invalid" >&2
    return 1
  }
  verify_source_generation "$source_generation"
  source_cli_hash=$(sha256sum \
    "$release_root/generations/$source_generation/helium-sync" | awk '{print $1}')
  [[ $(receipt_value "$receipt" schema_version) == 1 &&
      $(receipt_value "$receipt" generation) == "$generation" &&
      $(receipt_value "$receipt" hostname) == "$tls_hostname" &&
      $(receipt_value "$receipt" ip) == "$tls_ip" &&
      $(receipt_value "$receipt" listen) == "$tls_ip:$tls_port" &&
      $(receipt_value "$receipt" helium_sync_sha256) == "$source_cli_hash" ]] || {
    echo "TLS generation provenance is invalid" >&2
    return 1
  }
  while IFS='|' read -r file key; do
    [[ -f "$generation_root/$file" && ! -L "$generation_root/$file" ]] || {
      echo "TLS generation file is missing or unsafe: $file" >&2
      return 1
    }
    expected=$(receipt_value "$receipt" "$key")
    actual=$(sha256sum "$generation_root/$file" | awk '{print $1}')
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || {
      echo "TLS generation hash mismatch: $file" >&2
      return 1
    }
  done <<'EOF'
ca-cert.pem|ca_cert_sha256
server-cert.pem|server_cert_sha256
server-key.pem|server_key_sha256
endpoint.env|endpoint_env_sha256
EOF
  [[ ! -e "$generation_root/ca-key.pem" ]] || {
    echo "CA private key must not be present on lm" >&2
    return 1
  }
  "$release_root/generations/$source_generation/helium-sync" tls-server-verify \
    --ca-cert "$generation_root/ca-cert.pem" \
    --server-cert "$generation_root/server-cert.pem" \
    --server-key "$generation_root/server-key.pem" \
    --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h
}

verify_endpoint() {
  local current_target generation source_generation
  tailscale_identity
  verify_no_tailscale_proxy
  read_endpoint_config "$tls_root/current/endpoint.env"
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
  generation=${current_target#generations/}
  verify_tls_generation "$generation"
  source_generation=$(receipt_value \
    "$tls_root/generations/$generation/generation.env" source_generation)
  [[ $(readlink "$release_root/current") == "generations/$source_generation" ]] || {
    echo "active TLS generation belongs to a different source release" >&2
    return 1
  }
}

activate_tls_generation() {
  local generation=$1 current_temp source_generation
  tailscale_identity
  verify_no_tailscale_proxy
  read_endpoint_config "$tls_root/generations/$generation/endpoint.env"
  [[ "$configured_listen" == "$tls_ip:$tls_port" &&
      "$configured_hostname" == "$tls_hostname" &&
      "$configured_ip" == "$tls_ip" ]] || {
    echo "endpoint configuration does not match lm's live Tailscale identity" >&2
    return 1
  }
  verify_tls_generation "$generation" >/dev/null
  source_generation=$(receipt_value \
    "$tls_root/generations/$generation/generation.env" source_generation)
  [[ $(readlink "$release_root/current") == "generations/$source_generation" ]] || {
    echo "refusing TLS generation from a different source release" >&2
    return 1
  }
  current_temp=$tls_root/.current.$$
  ln -s "generations/$generation" "$current_temp"
  mv -Tf "$current_temp" "$tls_root/current"
  sync "$tls_root"
  verify_endpoint >/dev/null
}

verify_live_endpoint() {
  tailscale_identity
  local response
  response=$(curl --fail --silent --show-error --max-time 10 \
    --noproxy '*' --tlsv1.3 --tls-max 1.3 \
    --cacert "$tls_root/current/ca-cert.pem" \
    --resolve "$tls_hostname:$tls_port:$tls_ip" \
    "https://$tls_hostname:$tls_port/v2/health")
  jq -e '.ok == true and length == 1' <<<"$response" >/dev/null || {
    echo "direct TLS health response is invalid" >&2
    return 1
  }
}

wait_live_endpoint() {
  local _
  for _ in {1..50}; do
    if verify_live_endpoint 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  verify_live_endpoint
}

perform_backup_drill() (
  [ -s /var/lib/helium-sync/devices.json ] || {
    echo "server registry is not initialized" >&2
    exit 1
  }
  ! systemctl is-active --quiet helium-syncd.service || {
    echo "backup-drill requires helium-syncd.service to be inactive; use the supervised backup unit for an active service" >&2
    exit 1
  }
  findmnt -M /srv/nas >/dev/null || {
    echo "/srv/nas is not mounted" >&2
    exit 1
  }
  install -d -m0700 -o helium-sync -g helium-sync /srv/nas/helium-sync-server
  backup_output=$(runuser -u helium-sync -- env \
    HELIUM_SERVER_SERVICE=none HELIUM_SYNC_CLI="$sync_cli" \
    "$backup_cli" backup /srv/nas/helium-sync-server)
  archive=$(awk -F= '$1 == "archive" {print $2}' <<<"$backup_output")
  archive_sha=$(awk -F= '$1 == "sha256" {print $2}' <<<"$backup_output")
  target="/tmp/helium-sync-restore.$(date +%s).$$"
  cleanup_restore() {
    case "$target" in
      /tmp/helium-sync-restore.*) [ ! -e "$target" ] || runuser -u helium-sync -- find "$target" -depth -delete ;;
    esac
  }
  trap cleanup_restore EXIT
  runuser -u helium-sync -- env HELIUM_SERVER_SERVICE=none \
    HELIUM_SYNC_CLI="$sync_cli" "$backup_cli" restore-drill \
    "$archive" "$target" >/dev/null
  receipt=/srv/nas/helium-sync-server/last-restore-drill.env
  receipt_temp=$receipt.incoming.$$
  printf 'archive=%s\narchive_sha256=%s\nverified_at=%s\n' \
    "$archive" "$archive_sha" "$(date --iso-8601=seconds)" | \
    runuser -u helium-sync -- tee "$receipt_temp" >/dev/null
  runuser -u helium-sync -- chmod 0600 "$receipt_temp"
  runuser -u helium-sync -- sync "$receipt_temp"
  runuser -u helium-sync -- mv "$receipt_temp" "$receipt"
  cleanup_restore
  trap - EXIT
  echo "backup_restore_drill=passed"
)

perform_registry_update() (
  [ -s /var/lib/helium-sync/devices.json ] || {
    echo "server registry is not initialized" >&2
    exit 1
  }
  was_active=false
  restart_required=false
  restart_service() {
    local result=$?
    trap - EXIT INT TERM
    if [[ "$restart_required" == true ]]; then
      if ! systemctl start helium-syncd.service; then
        systemctl stop helium-syncd.service >/dev/null 2>&1 || true
        result=1
      fi
    fi
    exit "$result"
  }
  trap restart_service EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if systemctl is-active --quiet helium-syncd.service; then
    restart_required=true
    systemctl stop helium-syncd.service
    ! systemctl is-active --quiet helium-syncd.service || {
      echo "helium-syncd remained active during registry update" >&2
      exit 1
    }
    was_active=true
  fi
  runuser -u helium-sync -- "$sync_cli" "$@"
  runuser -u helium-sync -- "$sync_cli" server-verify \
    --data-dir /var/lib/helium-sync \
    --devices-file /var/lib/helium-sync/devices.json >/dev/null
  if [ "$was_active" = true ]; then
    systemctl start helium-syncd.service
    restart_required=false
  fi
  trap - EXIT INT TERM
)

case "$action" in
  install-source)
    [[ $# -eq 1 ]] || exit 2
    for service_name in helium-syncd.service \
      helium-sync-server-backup.service \
      helium-sync-server-backup-archive.service; do
      ! systemctl is-active --quiet "$service_name" || {
        echo "refusing source install while $service_name is active" >&2
        exit 1
      }
    done
    operator_user=${SUDO_USER:-}
    [[ -n "$operator_user" && "$operator_user" != root ]] || {
      echo "install-source must be invoked by a non-root operator through sudo" >&2
      exit 1
    }
    operator_group=$(id -gn "$operator_user")
    git_cmd=(runuser -u "$operator_user" -- git -c safe.directory="$repo_root" -C "$repo_root")
    [[ -z $("${git_cmd[@]}" status --porcelain --untracked-files=all) ]] || {
      echo "refusing to build an uncommitted source tree" >&2
      exit 1
    }
    source_commit=$("${git_cmd[@]}" rev-parse HEAD)
    source_tree=$("${git_cmd[@]}" rev-parse 'HEAD^{tree}')
    public_backbone_commit=$("${git_cmd[@]}" merge-base HEAD passwords/main)
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ &&
       "$source_tree" =~ ^[0-9a-f]{40}$ &&
       "$public_backbone_commit" =~ ^[0-9a-f]{40}$ ]] || {
      echo "source provenance could not be resolved" >&2
      exit 1
    }
    go_bin=$(command -v go)
    build_target=$(runuser -u "$operator_user" -- "$go_bin" env GOOS)/$(
      runuser -u "$operator_user" -- "$go_bin" env GOARCH)
    [[ "$build_target" == linux/amd64 ]] || {
      echo "production lm release must be built for linux/amd64" >&2
      exit 1
    }
    temp_dir=$(mktemp -d /var/tmp/helium-sync-release.XXXXXX)
    chown "$operator_user" "$temp_dir"
    cleanup() { find "$temp_dir" -depth -delete; }
    trap cleanup EXIT
    install -d -m0700 -o "$operator_user" -g "$operator_group" "$temp_dir/gocache"
    runuser -u "$operator_user" -- env GOCACHE="$temp_dir/gocache" \
      "$go_bin" -C "$repo_root" build -trimpath -o "$temp_dir/helium-sync" \
      ./cmd/helium-sync
    runuser -u "$operator_user" -- env GOCACHE="$temp_dir/gocache" \
      "$go_bin" -C "$repo_root" build -trimpath -o "$temp_dir/helium-syncd" \
      ./cmd/helium-syncd
    "$go_bin" version -m "$temp_dir/helium-sync" >"$temp_dir/helium-sync.buildinfo"
    "$go_bin" version -m "$temp_dir/helium-syncd" >"$temp_dir/helium-syncd.buildinfo"
    go_version=$(runuser -u "$operator_user" -- "$go_bin" version)
    module_identity=$(sha256sum "$repo_root/go.mod" "$repo_root/go.sum" | sha256sum | awk '{print $1}')
    stage=$temp_dir/stage
    install -d -m0755 "$stage"
    install -m0755 "$temp_dir/helium-sync" "$stage/helium-sync"
    install -m0755 "$temp_dir/helium-syncd" "$stage/helium-syncd"
    install -m0644 "$temp_dir/helium-sync.buildinfo" "$stage/helium-sync.buildinfo"
    install -m0644 "$temp_dir/helium-syncd.buildinfo" "$stage/helium-syncd.buildinfo"
    install -m0755 "$repo_root/scripts/helium-sync-endpoint-health.sh" \
      "$stage/helium-sync-endpoint-health"
    install -m0755 "$repo_root/scripts/helium-sync-server-backup.sh" \
      "$stage/helium-sync-server-backup"
    install -m0755 "$repo_root/scripts/helium-sync-server-backup-control.sh" \
      "$stage/helium-sync-server-backup-control"
    install -m0644 "$repo_root/sysusers.d/helium-sync.conf" "$stage/helium-sync.conf"
    for unit in "${source_units[@]}"; do
      install -m0644 "$repo_root/systemd/$unit" "$stage/$unit"
    done
    receipt=$stage/source.env
    {
      printf 'schema_version=1\n'
      printf 'source_commit=%s\n' "$source_commit"
      printf 'source_tree=%s\n' "$source_tree"
      printf 'public_backbone_commit=%s\n' "$public_backbone_commit"
      printf 'go_version=%s\n' "$go_version"
      printf 'module_identity_sha256=%s\n' "$module_identity"
      printf 'build_command=go build -trimpath -o helium-sync ./cmd/helium-sync; go build -trimpath -o helium-syncd ./cmd/helium-syncd\n'
      printf 'build_target=%s\n' "$build_target"
      printf 'built_at=%s\n' "$(date --iso-8601=seconds)"
      printf 'helium_sync_sha256=%s\n' "$(sha256sum "$stage/helium-sync" | awk '{print $1}')"
      printf 'helium_sync_buildinfo_sha256=%s\n' "$(sha256sum "$stage/helium-sync.buildinfo" | awk '{print $1}')"
      printf 'helium_syncd_sha256=%s\n' "$(sha256sum "$stage/helium-syncd" | awk '{print $1}')"
      printf 'helium_syncd_buildinfo_sha256=%s\n' "$(sha256sum "$stage/helium-syncd.buildinfo" | awk '{print $1}')"
      printf 'endpoint_health_sha256=%s\n' "$(sha256sum "$stage/helium-sync-endpoint-health" | awk '{print $1}')"
      printf 'backup_sha256=%s\n' "$(sha256sum "$stage/helium-sync-server-backup" | awk '{print $1}')"
      printf 'backup_control_sha256=%s\n' "$(sha256sum "$stage/helium-sync-server-backup-control" | awk '{print $1}')"
      printf 'sysusers_sha256=%s\n' "$(sha256sum "$stage/helium-sync.conf" | awk '{print $1}')"
      printf 'sync_unit_sha256=%s\n' "$(sha256sum "$stage/helium-syncd.service" | awk '{print $1}')"
      printf 'backup_unit_sha256=%s\n' "$(sha256sum "$stage/helium-sync-server-backup.service" | awk '{print $1}')"
      printf 'archive_unit_sha256=%s\n' "$(sha256sum "$stage/helium-sync-server-backup-archive.service" | awk '{print $1}')"
      printf 'backup_timer_sha256=%s\n' "$(sha256sum "$stage/helium-sync-server-backup.timer" | awk '{print $1}')"
    } >"$receipt"
    generation=$(sha256sum "$receipt" | awk '{print $1}')
    verify_source_generation_incoming=$release_root/generations/.incoming-$generation.$$
    final_generation=$release_root/generations/$generation
    [[ ! -e "$final_generation" ]] || {
      echo "refusing to replace existing source generation: $generation" >&2
      exit 1
    }
    install -d -m0755 -o root -g root "$release_root/generations"
    install -d -m0755 -o root -g root "$verify_source_generation_incoming"
    cp -a "$stage/." "$verify_source_generation_incoming/"
    chown -R root:root "$verify_source_generation_incoming"
    chmod 0755 "$verify_source_generation_incoming"
    sync "$verify_source_generation_incoming"
    mv "$verify_source_generation_incoming" "$final_generation"
    verify_source_generation "$generation"
    previous_generation=none
    if [[ -L "$release_root/current" ]]; then
      previous_generation=$(readlink "$release_root/current")
    fi
    activate_source_generation "$generation"
    install -Dm0644 "$final_generation/helium-sync.conf" \
      /usr/lib/sysusers.d/helium-sync.conf
    systemd-sysusers /usr/lib/sysusers.d/helium-sync.conf
    trap - EXIT
    cleanup
    printf 'source_generation=%s\nprevious_source=%s\ninstalled=inactive\n' \
      "$generation" "$previous_generation"
    ;;
  rollback-source)
    [[ $# -eq 2 ]] || {
      echo "usage: $0 rollback-source SOURCE_GENERATION" >&2
      exit 2
    }
    for service_name in helium-syncd.service \
      helium-sync-server-backup.service \
      helium-sync-server-backup-archive.service; do
      ! systemctl is-active --quiet "$service_name" || {
        echo "refusing source rollback while $service_name is active" >&2
        exit 1
      }
    done
    previous_generation=$(readlink "$release_root/current" 2>/dev/null || printf none)
    activate_source_generation "$2"
    printf 'source_generation=%s\nprevious_source=%s\nstate_preserved=/var/lib/helium-sync\n' \
      "$2" "$previous_generation"
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
    source_output=$(verify_source)
    source_generation=${source_output#source_generation=}
    verify_output=$("$sync_cli" tls-server-verify \
      --ca-cert "$ca_source" --server-cert "$cert_source" \
      --server-key "$key_source" --hostname "$tls_hostname" --ip "$tls_ip" \
      --minimum-validity 720h)
    install -d -m0755 -o root -g root "$tls_root/generations"
    endpoint_temp=$(mktemp /tmp/helium-sync-endpoint.XXXXXX)
    cleanup_endpoint() {
      rm -f "$endpoint_temp"
      [[ -z "${incoming:-}" ]] || find "$incoming" -depth -delete 2>/dev/null || true
    }
    trap cleanup_endpoint EXIT
    printf 'HELIUM_SYNC_LISTEN=%s:%s\nHELIUM_SYNC_TLS_HOSTNAME=%s\nHELIUM_SYNC_TLS_IP=%s\n' \
      "$tls_ip" "$tls_port" "$tls_hostname" "$tls_ip" >"$endpoint_temp"
    generation=$(
      {
        sha256sum "$ca_source" "$cert_source" "$key_source" | awk '{print $1}'
        sha256sum "$endpoint_temp" | awk '{print $1}'
        printf '%s\n' "$source_generation"
      } | sha256sum | awk '{print $1}'
    )
    final_generation="$tls_root/generations/$generation"
    [[ ! -e "$final_generation" ]] || {
      echo "refusing to replace existing TLS generation: $final_generation" >&2
      exit 1
    }
    incoming=$(mktemp -d "$tls_root/generations/.incoming.XXXXXX")
    chown root:helium-sync "$incoming"
    chmod 0750 "$incoming"
    install -m0644 -o root -g root "$ca_source" "$incoming/ca-cert.pem"
    install -m0644 -o root -g root "$cert_source" "$incoming/server-cert.pem"
    install -m0640 -o root -g helium-sync "$key_source" "$incoming/server-key.pem"
    install -m0644 -o root -g root "$endpoint_temp" "$incoming/endpoint.env"
    runuser -u helium-sync -- "$sync_cli" tls-server-verify \
      --ca-cert "$incoming/ca-cert.pem" \
      --server-cert "$incoming/server-cert.pem" \
      --server-key "$incoming/server-key.pem" \
      --hostname "$tls_hostname" --ip "$tls_ip" --minimum-validity 720h >/dev/null
    {
      printf 'schema_version=1\n'
      printf 'generation=%s\n' "$generation"
      printf 'hostname=%s\n' "$tls_hostname"
      printf 'ip=%s\n' "$tls_ip"
      printf 'listen=%s:%s\n' "$tls_ip" "$tls_port"
      printf 'source_generation=%s\n' "$source_generation"
      printf 'helium_sync_sha256=%s\n' "$(sha256sum "$sync_cli" | awk '{print $1}')"
      printf 'ca_cert_sha256=%s\n' "$(sha256sum "$incoming/ca-cert.pem" | awk '{print $1}')"
      printf 'server_cert_sha256=%s\n' "$(sha256sum "$incoming/server-cert.pem" | awk '{print $1}')"
      printf 'server_key_sha256=%s\n' "$(sha256sum "$incoming/server-key.pem" | awk '{print $1}')"
      printf 'endpoint_env_sha256=%s\n' "$(sha256sum "$incoming/endpoint.env" | awk '{print $1}')"
      printf 'installed_at=%s\n' "$(date --iso-8601=seconds)"
    } >"$incoming/generation.env"
    chown root:root "$incoming/generation.env"
    chmod 0644 "$incoming/generation.env"
    sync "$incoming"
    mv "$incoming" "$final_generation"
    incoming=
    previous_generation=$(readlink "$tls_root/current" 2>/dev/null || printf none)
    activate_tls_generation "$generation"
    trap - EXIT
    cleanup_endpoint
    printf '%s\n' "$verify_output"
    verify_endpoint >/dev/null
    echo "endpoint_installed=inactive"
    echo "endpoint_url=https://$tls_hostname:$tls_port"
    echo "tls_generation=$generation"
    echo "previous_tls=$previous_generation"
    ;;
  rollback-endpoint)
    [[ $# -eq 2 ]] || {
      echo "usage: $0 rollback-endpoint TLS_GENERATION" >&2
      exit 2
    }
    ! systemctl is-active --quiet helium-syncd.service || {
      echo "refusing TLS rollback while helium-syncd.service is active" >&2
      exit 1
    }
    previous_generation=$(readlink "$tls_root/current" 2>/dev/null || printf none)
    activate_tls_generation "$2"
    printf 'tls_generation=%s\nprevious_tls=%s\nstate_preserved=/var/lib/helium-sync\n' \
      "$2" "$previous_generation"
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
    install -d -m0700 -o helium-sync -g helium-sync /var/lib/helium-sync
    runuser -u helium-sync -- "$sync_cli" server-init \
      --data-dir /var/lib/helium-sync \
      --devices-file /var/lib/helium-sync/devices.json \
      --bootstrap-file "$(realpath -e "$bootstrap")"
    echo "initialized=inactive"
    ;;
  backup-drill)
    perform_backup_drill
    ;;
  enroll-device)
    [ "$#" -eq 2 ] && [ -f "$2" ] || {
      echo "usage: $0 enroll-device /path/to/HASHED_AUTH_REQUEST" >&2
      exit 2
    }
    perform_registry_update server-enroll \
      --devices-file /var/lib/helium-sync/devices.json \
      --auth-request-file "$(realpath -e "$2")"
    echo "device_enrolled=service_reloaded"
    ;;
  revoke-device)
    [ "$#" -eq 2 ] && [ -n "$2" ] || {
      echo "usage: $0 revoke-device DEVICE" >&2
      exit 2
    }
    perform_registry_update server-revoke \
      --devices-file /var/lib/helium-sync/devices.json --device "$2"
    echo "device_revoked=service_reloaded"
    ;;
  verify-source)
    verify_source
    echo "source_release=verified"
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
    ss -ltnH "( sport = :$tls_port )" | grep -q . && {
      echo "port $tls_port already has a listener; stop the synthetic or other service first" >&2
      exit 1
    }
    verify_endpoint >/dev/null
    perform_backup_drill >/dev/null
    systemctl enable --now helium-syncd.service
    if ! wait_live_endpoint; then
      systemctl disable --now helium-syncd.service
      echo "helium-syncd was stopped because the direct TLS health gate failed" >&2
      exit 1
    fi
    systemctl enable --now helium-sync-server-backup.timer
    ;;
  disable)
    systemctl disable --now helium-sync-server-backup.timer helium-syncd.service
    echo "production_service=disabled"
    echo "state_preserved=/var/lib/helium-sync"
    ;;
  status)
    systemctl --no-pager --full status helium-syncd.service
    verify_endpoint
    verify_live_endpoint
    ;;
  *)
    echo "usage: $0 <install-source|rollback-source GENERATION|install-endpoint CA CERT KEY|rollback-endpoint GENERATION|initialize BOOTSTRAP|backup-drill|enroll-device AUTH_REQUEST|revoke-device DEVICE|verify-source|verify-endpoint|verify-live-endpoint|enable|disable|status>" >&2
    exit 2
    ;;
esac
