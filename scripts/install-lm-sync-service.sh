#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
script_path=$(realpath -e "${BASH_SOURCE[0]}")
action=${1:-}
release_root=${HELIUM_SYNC_RELEASE_ROOT:-/usr/local/libexec/helium-sync-releases}
unit_root=${HELIUM_SYNC_UNIT_ROOT:-/etc/systemd/system}
config_root=${HELIUM_SYNC_CONFIG_ROOT:-/etc/helium-sync}
endpoint_env=$config_root/endpoint.env
sync_cli=${HELIUM_SYNC_CLI:-$release_root/current/helium-sync}
backup_cli=$release_root/current/helium-sync-server-backup
sync_port=44719
source_units=(
  helium-syncd.service
  helium-sync-server-backup.service
  helium-sync-server-backup-archive.service
  helium-sync-server-backup.timer
)
operator_lock=${HELIUM_SYNC_OPERATOR_LOCK:-/run/helium-sync-operator.lock}

case "$action" in
  install-source|rollback-source|install-endpoint|initialize|backup-drill|enroll-device|revoke-device|verify-source|verify-endpoint|verify-live-endpoint|enable|disable|status)
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
  local -a lines=() keys=("$@")
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
  sync_ip=$(jq -er '
    if .BackendState == "Running" and .Self.Online == true then
      [.Self.TailscaleIPs[] | select(test("^100\\."))] |
      if length == 1 then .[0] else error("expected one Tailscale IPv4") end
    else error("Tailscale is not online")
    end
  ' <<<"$status")
  sync_listen=$sync_ip:$sync_port
}

verify_tailnet_exposure() {
  "$repo_root/scripts/verify-tailnet-exposure.sh" >/dev/null
}

read_endpoint_config() {
  [[ -f "$endpoint_env" && ! -L "$endpoint_env" ]] || {
    echo "endpoint configuration is missing or unsafe: $endpoint_env" >&2
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
  verify_source >/dev/null
  tailscale_identity
  verify_tailnet_exposure
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
  [[ -s /var/lib/helium-sync/devices.json ]] || {
    echo "server registry is not initialized" >&2
    exit 1
  }
  ! systemctl is-active --quiet helium-syncd.service || {
    echo "backup-drill requires helium-syncd.service to be inactive" >&2
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
      /tmp/helium-sync-restore.*)
        [[ ! -e "$target" ]] ||
          runuser -u helium-sync -- find "$target" -depth -delete
        ;;
    esac
  }
  trap cleanup_restore EXIT
  runuser -u helium-sync -- env HELIUM_SERVER_SERVICE=none \
    HELIUM_SYNC_CLI="$sync_cli" "$backup_cli" restore-drill \
    "$archive" "$target" >/dev/null
  receipt=/srv/nas/helium-sync-server/last-restore-drill.env
  receipt_temp=$receipt.incoming.$$
  printf 'archive=%s\narchive_sha256=%s\nverified_at=%s\n' \
    "$archive" "$archive_sha" "$(date --iso-8601=seconds)" |
    runuser -u helium-sync -- tee "$receipt_temp" >/dev/null
  runuser -u helium-sync -- chmod 0600 "$receipt_temp"
  runuser -u helium-sync -- sync "$receipt_temp"
  runuser -u helium-sync -- mv "$receipt_temp" "$receipt"
  cleanup_restore
  trap - EXIT
  echo "backup_restore_drill=passed"
)

perform_registry_update() (
  [[ -s /var/lib/helium-sync/devices.json ]] || {
    echo "server registry is not initialized" >&2
    exit 1
  }
  was_active=false
  if systemctl is-active --quiet helium-syncd.service; then
    systemctl stop helium-syncd.service
    was_active=true
  fi
  restart_service() {
    if [[ "$was_active" == true ]]; then
      systemctl start helium-syncd.service || true
    fi
  }
  trap restart_service EXIT INT TERM
  runuser -u helium-sync -- "$sync_cli" "$@"
  runuser -u helium-sync -- "$sync_cli" server-verify \
    --data-dir /var/lib/helium-sync \
    --devices-file /var/lib/helium-sync/devices.json >/dev/null
  trap - EXIT INT TERM
  if [[ "$was_active" == true ]]; then
    systemctl start helium-syncd.service
    if ! wait_live_endpoint; then
      systemctl stop helium-syncd.service
      echo "helium-syncd stopped because the registry reload health gate failed" >&2
      exit 1
    fi
  fi
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
    module_identity=$(sha256sum "$repo_root/go.mod" "$repo_root/go.sum" |
      sha256sum | awk '{print $1}')
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
    incoming=$release_root/generations/.incoming-$generation.$$
    final_generation=$release_root/generations/$generation
    [[ ! -e "$final_generation" ]] || {
      echo "refusing to replace existing source generation: $generation" >&2
      exit 1
    }
    install -d -m0755 -o root -g root "$release_root/generations"
    install -d -m0755 -o root -g root "$incoming"
    cp -a "$stage/." "$incoming/"
    chown -R root:root "$incoming"
    chmod 0755 "$incoming"
    sync "$incoming"
    mv "$incoming" "$final_generation"
    verify_source_generation "$generation"
    previous_generation=$(readlink "$release_root/current" 2>/dev/null || printf none)
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
    [[ $# -eq 1 ]] || {
      echo "usage: $0 install-endpoint" >&2
      exit 2
    }
    ! systemctl is-active --quiet helium-syncd.service || {
      echo "refusing endpoint install while helium-syncd.service is active" >&2
      exit 1
    }
    verify_source >/dev/null
    tailscale_identity
    verify_no_funnel
    install -d -m0750 -o root -g helium-sync "$config_root"
    endpoint_temp=$(mktemp "$config_root/.endpoint.XXXXXX")
    printf 'HELIUM_SYNC_LISTEN=%s\n' "$sync_listen" >"$endpoint_temp"
    chown root:helium-sync "$endpoint_temp"
    chmod 0640 "$endpoint_temp"
    mv "$endpoint_temp" "$endpoint_env"
    sync "$config_root"
    verify_endpoint >/dev/null
    printf 'endpoint_installed=inactive\nendpoint_url=http://%s\n' "$sync_listen"
    ;;
  initialize)
    bootstrap=${2:-}
    [[ $# -eq 2 && -f "$bootstrap" ]] || {
      echo "usage: $0 initialize /path/to/d-server-bootstrap.json" >&2
      exit 2
    }
    [[ ! -e /var/lib/helium-sync/devices.json ]] || {
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
    [[ $# -eq 2 && -f "$2" ]] || {
      echo "usage: $0 enroll-device /path/to/HASHED_AUTH_REQUEST" >&2
      exit 2
    }
    perform_registry_update server-enroll \
      --devices-file /var/lib/helium-sync/devices.json \
      --auth-request-file "$(realpath -e "$2")"
    echo "device_enrolled=service_reloaded"
    ;;
  revoke-device)
    [[ $# -eq 2 && -n "$2" ]] || {
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
    echo "tailnet_endpoint=verified"
    ;;
  verify-live-endpoint)
    verify_endpoint >/dev/null
    verify_live_endpoint
    echo "tailnet_endpoint=live"
    ;;
  enable)
    [[ -s /var/lib/helium-sync/devices.json ]] || {
      echo "server registry is not initialized" >&2
      exit 1
    }
    tailscale_identity
    ! ss -ltnH "( sport = :$sync_port )" | grep -q . || {
      echo "port $sync_port already has a listener" >&2
      exit 1
    }
    verify_endpoint >/dev/null
    perform_backup_drill >/dev/null
    systemctl enable --now helium-syncd.service
    if ! wait_live_endpoint; then
      systemctl disable --now helium-syncd.service
      echo "helium-syncd stopped because its Tailnet health gate failed" >&2
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
    echo "usage: $0 <install-source|rollback-source GENERATION|install-endpoint|initialize BOOTSTRAP|backup-drill|enroll-device AUTH_REQUEST|revoke-device DEVICE|verify-source|verify-endpoint|verify-live-endpoint|enable|disable|status>" >&2
    exit 2
    ;;
esac
