#!/usr/bin/env bash
set -euo pipefail
umask 077

data_dir=${HELIUM_SERVER_DATA_DIR:-/var/lib/helium-sync}
service=${HELIUM_SERVER_SERVICE:-helium-syncd.service}
service_scope=${HELIUM_SERVER_SERVICE_SCOPE:-system}
verify_bin=${HELIUM_SYNC_CLI:-/usr/local/libexec/helium-sync}
command=${1:-}

require_absolute() {
  case "$1" in
    /*) ;;
    *) echo "path must be absolute: $1" >&2; exit 2 ;;
  esac
}

service_control() {
  case "$service_scope" in
    system)
      if [[ $EUID -eq 0 ]]; then
        systemctl "$@" "$service"
      else
        sudo systemctl "$@" "$service"
      fi
      ;;
    user) systemctl --user "$@" "$service" ;;
    *) echo "HELIUM_SERVER_SERVICE_SCOPE must be system or user" >&2; exit 2 ;;
  esac
}

backup() {
  destination=${1:-}
  require_absolute "$data_dir"
  require_absolute "$destination"
  [[ -d "$data_dir" && ! -L "$data_dir" ]] || {
    echo "server data must be an existing directory, not a symlink" >&2
    exit 1
  }
  [ -s "$data_dir/devices.json" ] || {
    echo "server registry is missing" >&2
    exit 1
  }
  mkdir -p "$destination/generations"
  chmod 0700 "$destination" "$destination/generations"
  if [[ "$destination" == /srv/nas/* ]]; then
    findmnt -M /srv/nas >/dev/null || {
      echo "/srv/nas is not mounted" >&2
      exit 1
    }
  fi
  available=$(df -PB1 "$destination" | awk 'NR == 2 { print $4 }')
  [ "$available" -ge $((1024 * 1024 * 1024)) ] || {
    echo "backup destination has less than 1 GiB free" >&2
    exit 1
  }

  exec 9>"$destination/.backup.lock"
  chmod 0600 "$destination/.backup.lock"
  flock -n 9 || {
    echo "another server backup is running" >&2
    exit 1
  }
  was_active=false
  if [ "$service" != none ] && service_control is-active --quiet; then
    service_control stop
    was_active=true
  fi
  restart_service() {
    if [ "$was_active" = true ]; then
      service_control start || true
    fi
  }
  trap restart_service EXIT INT TERM

  "$verify_bin" server-verify --data-dir "$data_dir" \
    --devices-file "$data_dir/devices.json" >/dev/null
  generation=$(date -u +%Y%m%dT%H%M%S.%NZ)
  incoming="$destination/generations/.incoming-$generation.tar.zst"
  final="$destination/generations/$generation.tar.zst"
  manifest="$destination/generations/$generation.env"
  [ ! -e "$final" ] && [ ! -e "$manifest" ] || {
    echo "backup generation already exists" >&2
    exit 1
  }
  data_parent=$(dirname "$data_dir")
  data_name=$(basename "$data_dir")
  archive_members=(
    "$data_name/devices.json"
    "$data_name/records.jsonl"
    "$data_name/snapshots"
  )
  if [[ -e "$data_dir/quarantine" ]]; then
    [[ -d "$data_dir/quarantine" && ! -L "$data_dir/quarantine" ]] || {
      echo "server quarantine must be a directory, not a symlink" >&2
      exit 1
    }
    archive_members+=("$data_name/quarantine")
  fi
  tar --zstd -C "$data_parent" -cf "$incoming" -- "${archive_members[@]}"
  archive_sha=$(sha256sum "$incoming" | awk '{print $1}')
  archive_bytes=$(stat -c %s "$incoming")
  temp_manifest="$manifest.incoming"
  {
    printf 'schema_version=1\n'
    printf 'generation=%s\n' "$generation"
    printf 'archive_sha256=%s\n' "$archive_sha"
    printf 'archive_bytes=%s\n' "$archive_bytes"
    printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'source_host=%s\n' "$(uname -n | cut -d. -f1)"
    printf 'helium_sync_cli_sha256=%s\n' "$(sha256sum "$verify_bin" | awk '{print $1}')"
  } >"$temp_manifest"
  sync "$incoming" "$temp_manifest"
  mv "$incoming" "$final"
  mv "$temp_manifest" "$manifest"
  sync "$destination/generations"
  trap - EXIT INT TERM
  restart_service
  printf 'generation=%s\narchive=%s\nsha256=%s\n' \
    "$generation" "$final" "$archive_sha"
}

restore_drill() {
  archive=${1:-}
  target=${2:-}
  require_absolute "$archive"
  require_absolute "$target"
  [ -f "$archive" ] || { echo "backup archive is missing" >&2; exit 1; }
  [ ! -e "$target" ] || {
    echo "restore target must not exist" >&2
    exit 1
  }
  case "$target" in
    /tmp/helium-sync-restore.*) ;;
    *) echo "restore target must be /tmp/helium-sync-restore.*" >&2; exit 2 ;;
  esac
  manifest=${archive%.tar.zst}.env
  [ -f "$manifest" ] || { echo "backup manifest is missing" >&2; exit 1; }
  expected=$(awk -F= '$1 == "archive_sha256" {print $2}' "$manifest")
  actual=$(sha256sum "$archive" | awk '{print $1}')
  [ -n "$expected" ] && [ "$actual" = "$expected" ] || {
    echo "backup checksum mismatch" >&2
    exit 1
  }
  if tar --zstd -tf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "backup archive contains an unsafe path" >&2
    exit 1
  fi
  mkdir -m0700 "$target"
  tar --zstd -C "$target" -xf "$archive"
  restored="$target/$(basename "$data_dir")"
  "$verify_bin" server-verify --data-dir "$restored" \
    --devices-file "$restored/devices.json" >/dev/null
  printf 'restore_drill=passed\ntarget=%s\nsha256=%s\n' "$target" "$actual"
}

case "$command" in
  backup) [ "$#" -eq 2 ] || exit 2; backup "$2" ;;
  restore-drill) [ "$#" -eq 3 ] || exit 2; restore_drill "$2" "$3" ;;
  *)
    echo "usage: $0 backup /destination | restore-drill /generation.tar.zst /tmp/helium-sync-restore.NAME" >&2
    exit 2
    ;;
esac
