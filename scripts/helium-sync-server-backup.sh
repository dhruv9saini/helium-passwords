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

validate_archive_inventory() {
  local archive=$1 data_name=$2 entry normalized type inventory verbose
  local -A seen=()
  local devices_seen=false records_seen=false snapshots_seen=false
  inventory=$(tar --zstd -tf "$archive") || {
    echo "backup archive inventory is unreadable" >&2
    return 1
  }
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != /* &&
       "$entry" != .. && "$entry" != ../* &&
       "$entry" != */../* && "$entry" != */.. ]] || {
      echo "backup archive contains an unsafe path" >&2
      return 1
    }
    normalized=${entry%/}
    [[ -z ${seen[$normalized]+set} ]] || {
      echo "backup archive contains a duplicate member: $normalized" >&2
      return 1
    }
    seen[$normalized]=1
    case "$normalized" in
      "$data_name/devices.json") devices_seen=true ;;
      "$data_name/records.jsonl") records_seen=true ;;
      "$data_name/snapshots") snapshots_seen=true ;;
      "$data_name/snapshots"/*|"$data_name/quarantine"|"$data_name/quarantine"/*) ;;
      *)
        echo "backup archive contains an unexpected member: $normalized" >&2
        return 1
        ;;
    esac
  done <<<"$inventory"
  [[ $devices_seen == true && $records_seen == true &&
     $snapshots_seen == true ]] || {
    echo "backup archive is missing a required member" >&2
    return 1
  }
  verbose=$(tar --zstd -tvf "$archive") || {
    echo "backup archive types are unreadable" >&2
    return 1
  }
  while IFS= read -r type; do
    [[ "$type" == - || "$type" == d ]] || {
      echo "backup archive contains a non-regular member" >&2
      return 1
    }
  done < <(cut -c1 <<<"$verbose")
}

validate_generation() {
  local archive=$1 manifest=$2 generation=$3 target=$4 data_name=$5
  local -a lines expected_keys
  local index key value archive_sha archive_bytes actual_sha actual_bytes restored
  [[ "$generation" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z$ ]] || {
    echo "backup generation identity is invalid" >&2
    return 1
  }
  [[ -f "$archive" && ! -L "$archive" &&
     -f "$manifest" && ! -L "$manifest" ]] || {
    echo "backup archive or manifest is missing or unsafe" >&2
    return 1
  }
  mapfile -t lines <"$manifest"
  expected_keys=(schema_version generation archive_sha256 archive_bytes \
    created_at source_host helium_sync_cli_sha256)
  [[ ${#lines[@]} -eq ${#expected_keys[@]} ]] || {
    echo "backup manifest field count is invalid" >&2
    return 1
  }
  for index in "${!expected_keys[@]}"; do
    key=${expected_keys[$index]}
    value=${lines[$index]#*=}
    [[ "${lines[$index]}" == "$key=$value" ]] || {
      echo "backup manifest key order is invalid" >&2
      return 1
    }
    case "$key" in
      schema_version) [[ "$value" == 1 ]] ;;
      generation) [[ "$value" == "$generation" ]] ;;
      archive_sha256|helium_sync_cli_sha256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] ;;
      archive_bytes) [[ "$value" =~ ^[1-9][0-9]*$ ]] ;;
      created_at) [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] ;;
      source_host) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ;;
    esac || {
      echo "backup manifest value is invalid: $key" >&2
      return 1
    }
  done
  archive_sha=${lines[2]#*=}
  archive_bytes=${lines[3]#*=}
  actual_sha=$(sha256sum "$archive" | awk '{print $1}')
  actual_bytes=$(stat -c %s "$archive")
  [[ "$archive_sha" == "$actual_sha" &&
     "$archive_bytes" == "$actual_bytes" ]] || {
    echo "backup checksum or byte count mismatch" >&2
    return 1
  }
  validate_archive_inventory "$archive" "$data_name"
  [[ ! -e "$target" ]] || {
    echo "restore target must not exist" >&2
    return 1
  }
  mkdir -m0700 "$target"
  tar --zstd --no-same-owner --no-same-permissions -C "$target" -xf "$archive"
  if find "$target" \( -type l -o \( ! -type d ! -type f \) \) -print -quit | grep -q .; then
    echo "restored backup contains an unsafe filesystem object" >&2
    return 1
  fi
  restored=$target/$data_name
  "$verify_bin" server-verify --data-dir "$restored" \
    --devices-file "$restored/devices.json" >/dev/null
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
  if [[ "$destination" == /srv/nas/* ]]; then
    findmnt -M /srv/nas >/dev/null || {
      echo "/srv/nas is not mounted" >&2
      exit 1
    }
  fi
  mkdir -p "$destination/generations"
  chmod 0700 "$destination" "$destination/generations"
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
  restart_service() {
    [[ "$was_active" == true ]] || return 0
    service_control start
    service_control is-active --quiet
  }
  finish() {
    local result=$?
    trap - EXIT INT TERM
    restart_service || result=1
    exit "$result"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "$service" != none ] && service_control is-active --quiet; then
    was_active=true
    service_control stop
    if service_control is-active --quiet; then
      echo "Helium Sync service remained active during backup quiesce" >&2
      exit 1
    fi
  fi

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
  if find "${archive_members[@]/#/$data_parent/}" \
      \( -type l -o \( ! -type d ! -type f \) \) -print -quit | grep -q .; then
    echo "server backup members must contain only regular files and directories" >&2
    exit 1
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
  validation_target="$destination/.validate-$generation"
  validation_cleanup() {
    [[ ! -e "$validation_target" ]] || find "$validation_target" -depth -delete
  }
  finish_with_validation() {
    local result=$?
    validation_cleanup
    return "$result"
  }
  trap 'finish_with_validation; finish' EXIT
  validate_generation "$incoming" "$temp_manifest" "$generation" \
    "$validation_target" "$data_name"
  validation_cleanup
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
  generation=$(basename "${archive%.tar.zst}")
  validate_generation "$archive" "$manifest" "$generation" "$target" \
    "$(basename "$data_dir")"
  actual=$(sha256sum "$archive" | awk '{print $1}')
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
