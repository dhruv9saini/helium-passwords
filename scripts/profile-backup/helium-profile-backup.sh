#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: helium-profile-backup.sh <command> CONFIG [arguments]

  preflight CONFIG
  backup CONFIG [GENERATION]
  backup-stream CONFIG GENERATION EXPECTED-TREE-SHA256 SOURCE-BYTES ARCHIVE-ROOT
  status CONFIG GENERATION
  receipt-export CONFIG DESTINATION-ID GENERATION NEW-FILE
  verify-receipt CONFIG RECEIPT [EXPECTED-PROFILE-PATH]
  retention-apply CONFIG
  quarantine CONFIG DESTINATION-ID GENERATION REASON-SLUG
  restore-to-disposable CONFIG DESTINATION-ID GENERATION NEW-DIRECTORY

CONFIG schema 3 names exactly two off-source private destinations. A compressed
archive streams directly to both incoming directories and is checksum-bound.
Restore can write only a new marked disposable directory.
EOF
}

die() { echo "$*" >&2; exit 1; }
valid_generation() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]]; }
valid_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }
host_short() { uname -n | cut -d. -f1; }
require_absolute() {
  [[ "$2" == /* && "$2" != *$'\n'* && "/$2/" != *"/../"* ]] ||
    die "$1 must be a safe absolute path"
}

load_config() {
  local config=$1 line key value mode extra
  [[ -f "$config" && ! -L "$config" ]] ||
    die "config must be a regular non-symlink file"
  mode=$(stat -c %a -- "$config")
  (( (8#$mode & 077) == 0 )) ||
    die "config must not be accessible by group or other users"

  PROFILE_DEST_IDS=()
  PROFILE_DEST_ROLES=()
  PROFILE_DEST_KINDS=()
  PROFILE_DEST_HOSTS=()
  PROFILE_DEST_SSH=()
  PROFILE_DEST_ROOTS=()
  unset PROFILE_VERSION PROFILE_SOURCE_DEVICE PROFILE_ID PROFILE_SOURCE_PATH
  unset PROFILE_RETENTION_KEEP
  unset PROFILE_DESTINATION_RESERVE_BYTES PROFILE_SSH_USER
  unset PROFILE_SSH_IDENTITY PROFILE_SSH_KNOWN_HOSTS

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] ||
      die "invalid profile backup config line"
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version)
        [[ -z "${PROFILE_VERSION+x}" ]] || die "duplicate version"
        PROFILE_VERSION=$value
        ;;
      source_device)
        [[ -z "${PROFILE_SOURCE_DEVICE+x}" ]] || die "duplicate source_device"
        PROFILE_SOURCE_DEVICE=$value
        ;;
      profile_id)
        [[ -z "${PROFILE_ID+x}" ]] || die "duplicate profile_id"
        PROFILE_ID=$value
        ;;
      source_path)
        [[ -z "${PROFILE_SOURCE_PATH+x}" ]] || die "duplicate source_path"
        PROFILE_SOURCE_PATH=$value
        ;;
      ssh_user)
        [[ -z "${PROFILE_SSH_USER+x}" ]] || die "duplicate ssh_user"
        PROFILE_SSH_USER=$value
        ;;
      ssh_identity)
        [[ -z "${PROFILE_SSH_IDENTITY+x}" ]] || die "duplicate ssh_identity"
        PROFILE_SSH_IDENTITY=$value
        ;;
      ssh_known_hosts)
        [[ -z "${PROFILE_SSH_KNOWN_HOSTS+x}" ]] || die "duplicate ssh_known_hosts"
        PROFILE_SSH_KNOWN_HOSTS=$value
        ;;
      retention_keep)
        [[ -z "${PROFILE_RETENTION_KEEP+x}" ]] || die "duplicate retention_keep"
        PROFILE_RETENTION_KEEP=$value
        ;;
      destination_reserve_bytes)
        [[ -z "${PROFILE_DESTINATION_RESERVE_BYTES+x}" ]] ||
          die "duplicate destination_reserve_bytes"
        PROFILE_DESTINATION_RESERVE_BYTES=$value
        ;;
      destination)
        local destination_id destination_role destination_kind
        local destination_host destination_ssh destination_root
        IFS='|' read -r destination_id destination_role destination_kind \
          destination_host destination_ssh destination_root extra <<<"$value"
        [[ -n "$destination_id" && -n "$destination_role" &&
          -n "$destination_kind" && -n "$destination_host" &&
          -n "$destination_ssh" && -n "$destination_root" &&
          -z "${extra:-}" ]] ||
          die "destination requires id|nas-or-device|local-or-ssh|host-id|ssh-alias-or--|absolute-root"
        PROFILE_DEST_IDS+=("$destination_id")
        PROFILE_DEST_ROLES+=("$destination_role")
        PROFILE_DEST_KINDS+=("$destination_kind")
        PROFILE_DEST_HOSTS+=("$destination_host")
        PROFILE_DEST_SSH+=("$destination_ssh")
        PROFILE_DEST_ROOTS+=("$destination_root")
        ;;
      *) die "unknown profile backup config field: $key" ;;
    esac
  done <"$config"

  [[ "${PROFILE_VERSION:-}" == 3 ]] ||
    die "unsupported profile backup config version"
  [[ "${PROFILE_SOURCE_DEVICE:-}" =~ ^(d|da|oneplus|fixture)$ ]] ||
    die "invalid source_device"
  valid_slug "${PROFILE_ID:-}" || die "invalid profile_id"
  require_absolute source_path "${PROFILE_SOURCE_PATH:-}"
  [[ "${PROFILE_SSH_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    die "ssh_user is invalid"
  require_absolute ssh_identity "${PROFILE_SSH_IDENTITY:-}"
  require_absolute ssh_known_hosts "${PROFILE_SSH_KNOWN_HOSTS:-}"
  [[ "${PROFILE_SSH_IDENTITY}" =~ ^/[A-Za-z0-9._/-]+$ &&
    "${PROFILE_SSH_KNOWN_HOSTS}" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "SSH material path contains unsupported characters"
  [[ "${PROFILE_RETENTION_KEEP:-}" =~ ^[1-9][0-9]*$ ]] ||
    die "retention_keep must be positive"
  [[ "${PROFILE_DESTINATION_RESERVE_BYTES:-}" =~ ^[0-9]+$ ]] ||
    die "destination_reserve_bytes must be non-negative"
  validate_destinations
}

validate_destinations() {
  [[ ${#PROFILE_DEST_IDS[@]} -eq 2 ]] ||
    die "exactly two off-source destinations are required"
  local index expected_peer nas_count=0 device_count=0 actual
  actual=$(host_short)
  case "$PROFILE_SOURCE_DEVICE" in
    d)
      [[ "$actual" == d ]] ||
        die "d profile backups must run on authenticated source host d"
      expected_peer=da
      ;;
    da)
      [[ "$actual" == da ]] ||
        die "da profile backups must run on authenticated source host da"
      expected_peer=d
      ;;
    oneplus)
      [[ "$actual" == lm ]] ||
        die "oneplus app-profile backup streams must be handled on lm"
      expected_peer=da
      ;;
    fixture) expected_peer= ;;
  esac

  for index in 0 1; do
    valid_slug "${PROFILE_DEST_IDS[index]}" || die "invalid destination id"
    valid_slug "${PROFILE_DEST_HOSTS[index]}" || die "invalid destination host id"
    [[ "${PROFILE_DEST_HOSTS[index]}" != "$PROFILE_SOURCE_DEVICE" ]] ||
      die "destination ${PROFILE_DEST_IDS[index]} is on the source device"
    require_absolute destination_root "${PROFILE_DEST_ROOTS[index]}"
    [[ "${PROFILE_DEST_ROOTS[index]}" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
      die "destination root contains unsupported characters"
    case "${PROFILE_DEST_KINDS[index]}" in
      local)
        [[ "${PROFILE_DEST_SSH[index]}" == - ]] ||
          die "a local destination must use '-' as its SSH alias"
        [[ "${PROFILE_DEST_HOSTS[index]}" == "$actual" ]] ||
          die "local destination host does not match this machine"
        ;;
      ssh)
        [[ "${PROFILE_DEST_SSH[index]}" =~ ^[A-Za-z0-9._-]+$ ]] ||
          die "invalid destination SSH alias"
        ;;
      *) die "destination kind must be local or ssh" ;;
    esac
    case "${PROFILE_DEST_ROLES[index]}" in
      nas) nas_count=$((nas_count + 1)) ;;
      device) device_count=$((device_count + 1)) ;;
      *) die "destination role must be nas or device" ;;
    esac
  done

  [[ "${PROFILE_DEST_IDS[0]}" != "${PROFILE_DEST_IDS[1]}" &&
    "${PROFILE_DEST_HOSTS[0]}" != "${PROFILE_DEST_HOSTS[1]}" ]] ||
    die "the two destinations must use distinct IDs and hosts"
  [[ $nas_count -eq 1 && $device_count -eq 1 ]] ||
    die "exactly one NAS and one peer-device destination are required"

  if [[ "$PROFILE_SOURCE_DEVICE" != fixture ]]; then
    for index in 0 1; do
      case "${PROFILE_DEST_ROLES[index]}" in
        nas)
          [[ "${PROFILE_DEST_IDS[index]}" == nas-on-lm &&
            "${PROFILE_DEST_HOSTS[index]}" == lm &&
            "${PROFILE_DEST_ROOTS[index]}" == /srv/nas/helium-profile-backups ]] ||
            die "the NAS copy must be nas-on-lm at /srv/nas/helium-profile-backups on lm"
          ;;
        device)
          [[ "${PROFILE_DEST_IDS[index]}" == "$expected_peer-copy" &&
            "${PROFILE_DEST_HOSTS[index]}" == "$expected_peer" &&
            "${PROFILE_DEST_KINDS[index]}" == ssh &&
            "${PROFILE_DEST_ROOTS[index]}" == /home/d/.local/share/helium-profile-backups ]] ||
            die "$PROFILE_SOURCE_DEVICE must use the fixed $expected_peer peer replica"
          ;;
      esac
    done
  fi
}

topology_fingerprint() {
  local index
  for index in 0 1; do
    printf '%s|%s|%s|%s|%s\n' \
      "${PROFILE_DEST_IDS[index]}" "${PROFILE_DEST_ROLES[index]}" \
      "${PROFILE_DEST_KINDS[index]}" "${PROFILE_DEST_HOSTS[index]}" \
      "${PROFILE_DEST_ROOTS[index]}"
  done | sort | sha256sum | awk '{print $1}'
}

require_ssh_material() {
  local needed=false material mode owner
  [[ "${PROFILE_DEST_KINDS[0]}" == ssh ||
    "${PROFILE_DEST_KINDS[1]}" == ssh ]] && needed=true
  [[ "$needed" == true ]] || return 0
  command -v ssh >/dev/null || die "ssh is required"
  command -v rsync >/dev/null || die "rsync is required"
  for material in "$PROFILE_SSH_IDENTITY" "$PROFILE_SSH_KNOWN_HOSTS"; do
    [[ -f "$material" && ! -L "$material" && -s "$material" ]] ||
      die "SSH material must be a nonempty regular non-symlink file"
    owner=$(stat -c %u -- "$material")
    [[ "$owner" == "$(id -u)" ]] ||
      die "SSH material must be owned by the source user"
    mode=$(stat -c %a -- "$material")
    [[ "$mode" == 600 ]] || die "SSH material must have mode 0600"
  done
}

destination_run() {
  local index=$1 command_text
  shift
  if [[ "${PROFILE_DEST_KINDS[index]}" == local ]]; then
    "$@"
    return
  fi
  printf -v command_text '%q ' "$@"
  ssh -F none -o BatchMode=yes -o ConnectTimeout=10 \
    -o ClearAllForwardings=yes -o RequestTTY=no -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o "GlobalKnownHostsFile=${PROFILE_SSH_KNOWN_HOSTS}" \
    -o "UserKnownHostsFile=${PROFILE_SSH_KNOWN_HOSTS}" \
    -i "$PROFILE_SSH_IDENTITY" -l "$PROFILE_SSH_USER" \
    "${PROFILE_DEST_SSH[index]}" "$command_text"
}

destination_rsh() {
  printf 'ssh -F none -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=%s -o UserKnownHostsFile=%s -i %s -l %s\n' \
    "$PROFILE_SSH_KNOWN_HOSTS" "$PROFILE_SSH_KNOWN_HOSTS" \
    "$PROFILE_SSH_IDENTITY" "$PROFILE_SSH_USER"
}

verify_destination_host() {
  local index=$1 actual
  actual=$(destination_run "$index" uname -n)
  actual=${actual%%.*}
  [[ "$actual" == "${PROFILE_DEST_HOSTS[index]}" ]] ||
    die "destination host identity mismatch for ${PROFILE_DEST_IDS[index]}"
}

verify_destination_storage() {
  local index=$1 root=$2 target
  [[ "${PROFILE_DEST_ROLES[index]}" == nas ]] || return 0
  target=$(destination_run "$index" findmnt --noheadings --output TARGET \
    --target "$root" | awk 'NF {print $1; exit}')
  [[ -n "$target" && "$target" != / ]] ||
    die "nas-on-lm is not a separately mounted filesystem"
}

destination_namespace() {
  printf '%s/%s/%s\n' "${PROFILE_DEST_ROOTS[$1]%/}" \
    "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
}
generation_dir() { printf '%s/generations/%s\n' "$(destination_namespace "$1")" "$2"; }
archive_path() { printf '%s/profile.tar.zst\n' "$(generation_dir "$1" "$2")"; }
receipt_path() { printf '%s/receipt.env\n' "$(generation_dir "$1" "$2")"; }
incoming_dir() {
  printf '%s/incoming/%s.%s\n' "$(destination_namespace "$1")" "$2" "$3"
}

destination_sha256() {
  destination_run "$1" sha256sum "$2" | awk '{print $1}'
}

destination_size() {
  destination_run "$1" stat -c %s -- "$2"
}

destination_copy_to() {
  local index=$1 source=$2 target=$3
  if [[ "${PROFILE_DEST_KINDS[index]}" == local ]]; then
    (
      umask 077
      set -o noclobber
      cat "$source" >"$target"
    )
  else
    rsync -e "$(destination_rsh)" --archive --chmod=F600 --ignore-existing \
      "$source" "${PROFILE_DEST_SSH[index]}:$target"
  fi
}

destination_copy_from() {
  local index=$1 source=$2 target=$3
  if [[ "${PROFILE_DEST_KINDS[index]}" == local ]]; then
    cat "$source" >"$target"
  else
    rsync -e "$(destination_rsh)" --archive --chmod=F600 \
      "${PROFILE_DEST_SSH[index]}:$source" "$target"
  fi
  chmod 600 "$target"
}

destination_receive_stream() {
  local index=$1 target=$2
  if [[ "${PROFILE_DEST_KINDS[index]}" == local ]]; then
    (
      umask 077
      set -o noclobber
      cat >"$target"
    )
  else
    # shellcheck disable=SC2016
    destination_run "$index" bash -c \
      'umask 077; set -o noclobber; cat >"$1"' _ "$target"
  fi
}

preflight_destinations() {
  local source_bytes=$1 index available root
  [[ "$source_bytes" =~ ^[1-9][0-9]*$ ]] ||
    die "source size must be positive"
  require_ssh_material
  for index in 0 1; do
    verify_destination_host "$index"
    root=${PROFILE_DEST_ROOTS[index]}
    destination_run "$index" test -d "$root"
    destination_run "$index" test ! -L "$root"
    destination_run "$index" test -w "$root"
    verify_destination_storage "$index" "$root"
    available=$(destination_run "$index" df -PB1 "$root" |
      awk 'NR == 2 {print $4}')
    [[ "$available" =~ ^[0-9]+$ &&
      "$available" -ge $((source_bytes + PROFILE_DESTINATION_RESERVE_BYTES)) ]] ||
      die "destination ${PROFILE_DEST_IDS[index]} lacks source-size budget plus reserve"
  done
}

profile_open_pid() {
  local proc fd target canonical
  canonical=$(realpath -e -- "$PROFILE_SOURCE_PATH")/
  shopt -s nullglob
  for proc in /proc/[0-9]*; do
    for fd in "$proc"/fd/*; do
      target=$(readlink -- "$fd" 2>/dev/null || true)
      case "$target" in
        "$canonical"*)
          printf '%s\n' "${proc##*/}"
          shopt -u nullglob
          return 0
          ;;
      esac
    done
  done
  shopt -u nullglob
  return 1
}

ensure_source_stopped() {
  local pid
  [[ -d "$PROFILE_SOURCE_PATH" && ! -L "$PROFILE_SOURCE_PATH" ]] ||
    die "source profile must be a real directory"
  pid=$(profile_open_pid || true)
  [[ -z "$pid" ]] ||
    die "source profile has an open file in process $pid; stop the browser first"
}

profile_path_hash() {
  printf '%s' "$(realpath -e -- "$PROFILE_SOURCE_PATH")" |
    sha256sum | awk '{print $1}'
}

profile_tree_fingerprint() {
  local path=${1:-$PROFILE_SOURCE_PATH}
  [[ -d "$path" && ! -L "$path" ]] ||
    die "profile tree is unavailable for fingerprinting"
  tar --sort=name --format=posix \
    --pax-option=delete=atime,delete=ctime --mtime=@0 \
    --owner=0 --group=0 --numeric-owner -C "$path" -cf - . |
    sha256sum | awk '{print $1}'
}

preflight() {
  local source_bytes
  command -v zstd >/dev/null || die "zstd is required"
  ensure_source_stopped
  source_bytes=$(du -sb -- "$PROFILE_SOURCE_PATH" | awk '{print $1}')
  preflight_destinations "$source_bytes"
  printf 'preflight=ok\nsource_device=%s\nprofile_id=%s\nsource_bytes=%s\ntopology_sha256=%s\n' \
    "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID" "$source_bytes" \
    "$(topology_fingerprint)"
}

prepare_incoming() {
  local generation=$1 operation=$2 index ns incoming final
  for index in 0 1; do
    ns=$(destination_namespace "$index")
    incoming=$(incoming_dir "$index" "$generation" "$operation")
    final=$(generation_dir "$index" "$generation")
    destination_run "$index" mkdir -p \
      "$ns/generations" "$ns/incoming" "$ns/quarantine" "$ns/retired"
    destination_run "$index" chmod 700 \
      "$ns" "$ns/generations" "$ns/incoming" "$ns/quarantine" "$ns/retired"
    destination_run "$index" test ! -e "$final"
    destination_run "$index" test ! -e "$incoming"
    destination_run "$index" mkdir "$incoming"
    destination_run "$index" chmod 700 "$incoming"
  done
}

stream_archive() {
  local mode=$1 generation=$2 operation=$3 scratch=$4
  local fifo0=$scratch/archive.0 fifo1=$scratch/archive.1
  local hash_fifo=$scratch/archive.hash raw_fifo=$scratch/raw.hash
  local dest0 dest1 hash_pid raw_pid='' pipeline_rc=0 wait_rc=0
  dest0="$(incoming_dir 0 "$generation" "$operation")/profile.tar.zst"
  dest1="$(incoming_dir 1 "$generation" "$operation")/profile.tar.zst"
  mkfifo -m 600 "$fifo0" "$fifo1" "$hash_fifo"
  destination_receive_stream 0 "$dest0" <"$fifo0" &
  local dest0_pid=$!
  destination_receive_stream 1 "$dest1" <"$fifo1" &
  local dest1_pid=$!
  sha256sum <"$hash_fifo" | awk '{print $1}' >"$scratch/archive.sha256" &
  hash_pid=$!

  if [[ "$mode" == stream ]]; then
    mkfifo -m 600 "$raw_fifo"
    sha256sum <"$raw_fifo" | awk '{print $1}' >"$scratch/raw.sha256" &
    raw_pid=$!
    tee "$raw_fifo" |
      zstd -q -T1 -3 |
      tee "$fifo0" "$fifo1" "$hash_fifo" >/dev/null ||
      pipeline_rc=$?
  else
    tar --format=pax --numeric-owner \
      -C "$(dirname -- "$PROFILE_SOURCE_PATH")" \
      -cf - "$(basename -- "$PROFILE_SOURCE_PATH")" |
      zstd -q -T1 -3 |
      tee "$fifo0" "$fifo1" "$hash_fifo" >/dev/null ||
      pipeline_rc=$?
  fi

  wait "$dest0_pid" || wait_rc=1
  wait "$dest1_pid" || wait_rc=1
  wait "$hash_pid" || wait_rc=1
  [[ -z "$raw_pid" ]] || wait "$raw_pid" || wait_rc=1
  [[ $pipeline_rc -eq 0 && $wait_rc -eq 0 ]] ||
    die "compressed profile stream did not reach both destinations"
  [[ -s "$scratch/archive.sha256" ]] ||
    die "archive stream hash was not produced"
}

write_receipt() {
  local output=$1 generation=$2 source_tree=$3 fingerprint_kind=$4
  local archive_root=$5 archive_hash=$6 archive_size=$7 source_bytes=$8
  {
    printf 'schema_version=3\nsource_device=%s\nprofile_id=%s\n' \
      "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
    printf 'profile_path_sha256=%s\nsource_tree_sha256=%s\nsource_fingerprint_kind=%s\n' \
      "$PROFILE_PATH_HASH" "$source_tree" "$fingerprint_kind"
    printf 'archive_root=%s\n' "$archive_root"
    printf 'generation=%s\narchive_sha256=%s\narchive_size=%s\nsource_bytes=%s\n' \
      "$generation" "$archive_hash" "$archive_size" "$source_bytes"
    printf 'topology_sha256=%s\ncreated_at=%s\n' \
      "$(topology_fingerprint)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$output"
  chmod 600 "$output"
}

read_receipt() {
  local file=$1 line key value
  local allowed=' schema_version source_device profile_id profile_path_sha256 source_tree_sha256 source_fingerprint_kind archive_root generation archive_sha256 archive_size source_bytes topology_sha256 created_at '
  [[ -f "$file" && ! -L "$file" ]] ||
    die "receipt is unavailable: $file"
  declare -gA RECEIPT=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" == *=* ]] ||
      die "invalid profile backup receipt line"
    key=${line%%=*}
    value=${line#*=}
    [[ "$key" =~ ^[a-z][a-z0-9_]*$ && "$allowed" == *" $key "* ]] ||
      die "unknown profile backup receipt field: $key"
    [[ -z "${RECEIPT[$key]+set}" ]] ||
      die "duplicate profile backup receipt field: $key"
    [[ -n "$value" ]] || die "empty profile backup receipt field: $key"
    RECEIPT[$key]=$value
  done <"$file"
  [[ ${#RECEIPT[@]} -eq 13 ]] || die "incomplete profile backup receipt"
  [[ "${RECEIPT[schema_version]:-}" == 3 &&
    "${RECEIPT[source_device]:-}" == "$PROFILE_SOURCE_DEVICE" &&
    "${RECEIPT[profile_id]:-}" == "$PROFILE_ID" ]] ||
    die "profile backup receipt namespace mismatch"
  valid_generation "${RECEIPT[generation]:-}" || die "invalid receipt generation"
  [[ "${RECEIPT[archive_sha256]:-}" =~ ^[a-f0-9]{64}$ &&
    "${RECEIPT[topology_sha256]:-}" =~ ^[a-f0-9]{64}$ &&
    "${RECEIPT[profile_path_sha256]:-}" =~ ^[a-f0-9]{64}$ &&
    "${RECEIPT[source_tree_sha256]:-}" =~ ^[a-f0-9]{64}$ ]] ||
    die "invalid profile backup receipt hashes"
  [[ "${RECEIPT[archive_size]:-}" =~ ^[1-9][0-9]*$ &&
    "${RECEIPT[source_bytes]:-}" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid profile backup receipt sizes"
  [[ "${RECEIPT[source_fingerprint_kind]:-}" =~ ^(normalized-tree-v1|tar-stream-v1)$ ]] ||
    die "invalid source fingerprint kind"
  [[ "${RECEIPT[archive_root]:-}" != */* &&
    "${RECEIPT[archive_root]:-}" != . &&
    "${RECEIPT[archive_root]:-}" != .. ]] ||
    die "invalid archive root"
  [[ "${RECEIPT[topology_sha256]}" == "$(topology_fingerprint)" ]] ||
    die "receipt destination topology changed"
}

verify_incoming_archive() {
  local generation=$1 operation=$2 expected_hash=$3
  local index path size first_size=
  for index in 0 1; do
    path="$(incoming_dir "$index" "$generation" "$operation")/profile.tar.zst"
    destination_run "$index" test -f "$path"
    destination_run "$index" test ! -L "$path"
    [[ "$(destination_sha256 "$index" "$path")" == "$expected_hash" ]] ||
      die "archive stream checksum mismatch at ${PROFILE_DEST_IDS[index]}"
    size=$(destination_size "$index" "$path")
    [[ "$size" =~ ^[1-9][0-9]*$ ]] || die "archive stream is empty"
    if [[ -z "$first_size" ]]; then
      first_size=$size
    else
      [[ "$size" == "$first_size" ]] ||
        die "destination archive sizes disagree"
    fi
  done
  printf '%s\n' "$first_size"
}

publish_generation() {
  local generation=$1 operation=$2 receipt=$3 index incoming
  local receipt_hash
  receipt_hash=$(sha256sum -- "$receipt" | awk '{print $1}')
  for index in 0 1; do
    incoming=$(incoming_dir "$index" "$generation" "$operation")
    destination_copy_to "$index" "$receipt" "$incoming/receipt.env"
    [[ "$(destination_sha256 "$index" "$incoming/receipt.env")" == "$receipt_hash" ]] ||
      die "receipt transfer checksum mismatch at ${PROFILE_DEST_IDS[index]}"
  done
  for index in 0 1; do
    incoming=$(incoming_dir "$index" "$generation" "$operation")
    destination_run "$index" mv -T "$incoming" \
      "$(generation_dir "$index" "$generation")"
  done
}

backup_common() {
  local mode=$1 generation=$2 expected_tree=${3:-} source_bytes=${4:-}
  local archive_root=${5:-} operation scratch archive_hash archive_size
  local tree_before tree_after fingerprint_kind
  valid_generation "$generation" || die "invalid generation"
  command -v zstd >/dev/null || die "zstd is required"

  if [[ "$mode" == profile ]]; then
    ensure_source_stopped
    archive_root=$(basename -- "$(realpath -e -- "$PROFILE_SOURCE_PATH")")
    source_bytes=$(du -sb -- "$PROFILE_SOURCE_PATH" | awk '{print $1}')
    PROFILE_PATH_HASH=$(profile_path_hash)
    tree_before=$(profile_tree_fingerprint)
    fingerprint_kind='normalized-tree-v1'
  else
    [[ "$expected_tree" =~ ^[a-f0-9]{64}$ ]] ||
      die "invalid expected stream fingerprint"
    [[ "$source_bytes" =~ ^[1-9][0-9]*$ ]] ||
      die "stream source size must be positive"
    [[ "$archive_root" == "$(basename -- "$PROFILE_SOURCE_PATH")" &&
      "$archive_root" != . && "$archive_root" != .. &&
      "$archive_root" != */* ]] ||
      die "stream archive root does not match configured source path"
    PROFILE_PATH_HASH=$(printf '%s' "$PROFILE_SOURCE_PATH" |
      sha256sum | awk '{print $1}')
    fingerprint_kind='tar-stream-v1'
  fi

  preflight_destinations "$source_bytes"
  operation=$(tr -d - </proc/sys/kernel/random/uuid)
  scratch=$(mktemp -d)
  chmod 700 "$scratch"
  cleanup_backup() {
    local result=$?
    find "$scratch" -depth -delete 2>/dev/null || true
    return "$result"
  }
  trap cleanup_backup EXIT
  prepare_incoming "$generation" "$operation"
  stream_archive "$mode" "$generation" "$operation" "$scratch"
  archive_hash=$(tr -d '\r\n' <"$scratch/archive.sha256")
  [[ "$archive_hash" =~ ^[a-f0-9]{64}$ ]] ||
    die "invalid compressed stream checksum"
  archive_size=$(verify_incoming_archive "$generation" "$operation" "$archive_hash")

  if [[ "$mode" == profile ]]; then
    tree_after=$(profile_tree_fingerprint)
    [[ "$tree_after" == "$tree_before" ]] ||
      die "source profile changed while the backup was being created"
    expected_tree=$tree_before
  else
    [[ "$(tr -d '\r\n' <"$scratch/raw.sha256")" == "$expected_tree" ]] ||
      die "source changed between fingerprint and compressed backup stream"
  fi

  write_receipt "$scratch/receipt.env" "$generation" "$expected_tree" \
    "$fingerprint_kind" "$archive_root" "$archive_hash" "$archive_size" \
    "$source_bytes"
  publish_generation "$generation" "$operation" "$scratch/receipt.env"
  verify_generation "$generation"
  find "$scratch" -depth -delete
  trap - EXIT
  printf 'backup=committed\ngeneration=%s\nsource_tree_sha256=%s\narchive_sha256=%s\nreceipt_destination=%s\n' \
    "$generation" "$expected_tree" "$archive_hash" "${PROFILE_DEST_IDS[0]}"
}

backup() {
  local generation=${1:-}
  [[ -n "$generation" ]] ||
    generation="$(date -u +%Y%m%dT%H%M%SZ)-$(tr -d - </proc/sys/kernel/random/uuid | cut -c1-16)"
  backup_common profile "$generation"
}

backup_stream() {
  backup_common stream "$1" "$2" "$3" "$4"
}

verify_generation() (
  local generation=$1 index dir archive receipt inventory hash size
  local scratch first_receipt_hash='' first_archive_hash='' receipt_hash
  valid_generation "$generation" || die "invalid generation"
  require_ssh_material
  scratch=$(mktemp -d)
  chmod 700 "$scratch"
  trap 'find "$scratch" -depth -delete 2>/dev/null || true' EXIT
  for index in 0 1; do
    verify_destination_host "$index"
    dir=$(generation_dir "$index" "$generation")
    archive=$(archive_path "$index" "$generation")
    receipt=$(receipt_path "$index" "$generation")
    destination_run "$index" test -d "$dir"
    destination_run "$index" test ! -L "$dir"
    inventory=$(destination_run "$index" find "$dir" -mindepth 1 -maxdepth 1 \
      -printf '%f\n' | sort)
    [[ "$inventory" == $'profile.tar.zst\nreceipt.env' ]] ||
      die "generation inventory is invalid at ${PROFILE_DEST_IDS[index]}"
    destination_run "$index" test -f "$archive"
    destination_run "$index" test ! -L "$archive"
    destination_run "$index" test -f "$receipt"
    destination_run "$index" test ! -L "$receipt"
    destination_copy_from "$index" "$receipt" "$scratch/receipt.$index"
    read_receipt "$scratch/receipt.$index"
    [[ "${RECEIPT[generation]}" == "$generation" ]] ||
      die "receipt generation mismatch"
    hash=$(destination_sha256 "$index" "$archive")
    size=$(destination_size "$index" "$archive")
    [[ "$hash" == "${RECEIPT[archive_sha256]}" &&
      "$size" == "${RECEIPT[archive_size]}" ]] ||
      die "archive checksum or size mismatch at ${PROFILE_DEST_IDS[index]}"
    if [[ -z "$first_receipt_hash" ]]; then
      first_receipt_hash=$(sha256sum "$scratch/receipt.$index" | awk '{print $1}')
      first_archive_hash=$hash
    else
      receipt_hash=$(sha256sum "$scratch/receipt.$index" | awk '{print $1}')
      [[ "$receipt_hash" == "$first_receipt_hash" &&
        "$hash" == "$first_archive_hash" ]] ||
        die "destination copies disagree"
    fi
  done
)

destination_index() {
  local wanted=$1 index
  for index in 0 1; do
    if [[ "${PROFILE_DEST_IDS[index]}" == "$wanted" ]]; then
      printf '%s\n' "$index"
      return
    fi
  done
  die "unknown destination id"
}

receipt_export() {
  local wanted=$1 generation=$2 output=$3 index temporary
  valid_generation "$generation" || die "invalid generation"
  require_absolute receipt_export "$output"
  [[ ! -e "$output" ]] || die "receipt export destination already exists"
  [[ -d "$(dirname -- "$output")" &&
    ! -L "$(dirname -- "$output")" ]] ||
    die "receipt export parent must be a real directory"
  verify_generation "$generation"
  index=$(destination_index "$wanted")
  temporary=$(mktemp "$(dirname -- "$output")/.receipt.XXXXXX")
  chmod 600 "$temporary"
  destination_copy_from "$index" "$(receipt_path "$index" "$generation")" "$temporary"
  read_receipt "$temporary"
  [[ "${RECEIPT[generation]}" == "$generation" ]] ||
    die "exported receipt generation mismatch"
  mv -T "$temporary" "$output"
  printf 'receipt_exported=%s\ngeneration=%s\ndestination=%s\n' \
    "$output" "$generation" "$wanted"
}

verify_receipt_command() {
  local supplied=$1 expected_path=${2:-} generation expected_hash index
  local supplied_hash destination_receipt_hash
  local expected_tree_hash
  read_receipt "$supplied"
  generation=${RECEIPT[generation]}
  verify_generation "$generation"
  supplied_hash=$(sha256sum "$supplied" | awk '{print $1}')
  for index in 0 1; do
    destination_receipt_hash=$(
      destination_sha256 "$index" "$(receipt_path "$index" "$generation")"
    )
    [[ "$destination_receipt_hash" == "$supplied_hash" ]] ||
      die "supplied receipt is not the committed receipt"
  done
  if [[ -n "$expected_path" ]]; then
    require_absolute expected_profile_path "$expected_path"
    expected_hash=$(printf '%s' "$expected_path" | sha256sum | awk '{print $1}')
  else
    ensure_source_stopped
    expected_hash=$(profile_path_hash)
    expected_tree_hash=$(profile_tree_fingerprint)
    [[ "${RECEIPT[source_tree_sha256]}" == "$expected_tree_hash" ]] ||
      die "profile changed after the admitted backup"
  fi
  [[ "${RECEIPT[profile_path_sha256]}" == "$expected_hash" ]] ||
    die "backup receipt belongs to a different profile path"
  printf 'profile_backup_admission=verified\ngeneration=%s\nsource_device=%s\nprofile_id=%s\nprofile_path_sha256=%s\nsource_tree_sha256=%s\n' \
    "$generation" "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID" \
    "${RECEIPT[profile_path_sha256]}" "${RECEIPT[source_tree_sha256]}"
}

retention_apply() {
  local index generation dir listing peer_listing
  require_ssh_material
  for index in 0 1; do
    verify_destination_host "$index"
  done
  listing=$(destination_run 0 find "$(destination_namespace 0)/generations" \
    -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  peer_listing=$(destination_run 1 find "$(destination_namespace 1)/generations" \
    -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  [[ "$listing" == "$peer_listing" ]] ||
    die "destination active-generation inventories disagree"
  if [[ -n $listing ]]; then
    mapfile -t generations <<<"$listing"
  else
    generations=()
  fi
  [[ ${#generations[@]} -gt PROFILE_RETENTION_KEEP ]] ||
    { echo 'retention=unchanged'; return; }
  for generation in "${generations[@]:PROFILE_RETENTION_KEEP}"; do
    valid_generation "$generation" ||
      die "destination contains an invalid generation directory"
    verify_generation "$generation"
  done
  for generation in "${generations[@]:PROFILE_RETENTION_KEEP}"; do
    for index in 0 1; do
      dir="$(destination_namespace "$index")/retired/$generation"
      destination_run "$index" test ! -e "$dir"
      destination_run "$index" mv -T \
        "$(generation_dir "$index" "$generation")" "$dir"
    done
    printf 'retired_generation=%s\n' "$generation"
  done
}

quarantine() {
  local wanted=$1 generation=$2 reason=$3 index source target suffix
  valid_generation "$generation" || die "invalid generation"
  valid_slug "$reason" || die "invalid quarantine reason"
  require_ssh_material
  index=$(destination_index "$wanted")
  verify_destination_host "$index"
  source=$(generation_dir "$index" "$generation")
  suffix="$(date -u +%Y%m%dT%H%M%SZ).$reason"
  target="$(destination_namespace "$index")/quarantine/$generation.$suffix"
  destination_run "$index" test -d "$source"
  destination_run "$index" test ! -e "$target"
  destination_run "$index" mv -T "$source" "$target"
  printf 'quarantined=%s\ndestination=%s\nreason=%s\n' \
    "$generation" "$wanted" "$reason"
}

stream_destination_archive() {
  destination_run "$1" cat "$(archive_path "$1" "$2")"
}

restore_to_disposable() {
  local wanted=$1 generation=$2 destination=$3 index parent temporary listing
  local archive_root scratch restored_tree_hash restored_stream_hash
  local raw_hash_pid=
  valid_generation "$generation" || die "invalid generation"
  require_absolute restore_destination "$destination"
  [[ ! -e "$destination" ]] ||
    die "restore destination must be a new path"
  [[ "$(basename -- "$destination")" == drill-* ]] ||
    die "restore destination name must start with drill-"
  parent=$(dirname -- "$destination")
  [[ -d "$parent" && ! -L "$parent" &&
    -f "$parent/.helium-disposable-profile-restore-root" ]] ||
    die "restore parent lacks the disposable marker"
  [[ "$(stat -c %a -- "$parent")" == 700 ]] ||
    die "restore parent must have mode 0700"
  verify_generation "$generation"
  index=$(destination_index "$wanted")
  scratch=$(mktemp -d "$parent/.profile-restore.XXXXXX")
  chmod 700 "$scratch"
  cleanup_restore() {
    local result=$?
    [[ -z "$raw_hash_pid" ]] ||
      kill "$raw_hash_pid" >/dev/null 2>&1 || true
    find "$scratch" -depth -delete 2>/dev/null || true
    return "$result"
  }
  trap cleanup_restore EXIT
  destination_copy_from "$index" "$(receipt_path "$index" "$generation")" \
    "$scratch/receipt.env"
  read_receipt "$scratch/receipt.env"
  archive_root=${RECEIPT[archive_root]}
  listing=$scratch/archive.list
  mkfifo -m 600 "$scratch/archive.hash.pipe"
  sha256sum <"$scratch/archive.hash.pipe" |
    awk '{print $1}' >"$scratch/archive.sha256" &
  raw_hash_pid=$!
  stream_destination_archive "$index" "$generation" |
    zstd -q -d |
    tee "$scratch/archive.hash.pipe" |
    tar -tf - >"$listing"
  wait "$raw_hash_pid"
  raw_hash_pid=
  restored_stream_hash=$(tr -d '\r\n' <"$scratch/archive.sha256")
  [[ "$restored_stream_hash" =~ ^[a-f0-9]{64}$ ]] ||
    die "restored archive stream fingerprint is invalid"
  if [[ "${RECEIPT[source_fingerprint_kind]}" == tar-stream-v1 ]]; then
    [[ "$restored_stream_hash" == "${RECEIPT[source_tree_sha256]}" ]] ||
      die "restored archive stream does not match the admitted source"
  fi
  awk -v root="$archive_root" '
    /^\// {exit 1}
    /(^|\/)\.\.($|\/)/ {exit 1}
    $0 != root && index($0, root "/") != 1 {exit 1}
    END {if (NR == 0) exit 1}
  ' "$listing" || die "backup archive contains unsafe or foreign paths"
  temporary=$scratch/extracted
  mkdir -m 700 "$temporary"
  stream_destination_archive "$index" "$generation" |
    zstd -q -d |
    tar --no-same-owner --no-same-permissions -xf - -C "$temporary"
  [[ -d "$temporary/$archive_root" && ! -L "$temporary/$archive_root" ]] ||
    die "restored archive root is invalid"
  restored_tree_hash=$(profile_tree_fingerprint "$temporary/$archive_root")
  if [[ "${RECEIPT[source_fingerprint_kind]}" == normalized-tree-v1 ]]; then
    [[ "$restored_tree_hash" == "${RECEIPT[source_tree_sha256]}" ]] ||
      die "restored profile content does not match the admitted source"
  fi
  mv -T "$temporary/$archive_root" "$destination"
  {
    printf 'schema_version=3\ngeneration=%s\nsource_device=%s\nprofile_id=%s\n' \
      "$generation" "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
    printf 'archive_sha256=%s\nsource_destination=%s\nrestored_at=%s\n' \
      "${RECEIPT[archive_sha256]}" "$wanted" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$destination/.helium-profile-restore-receipt.env"
  chmod 600 "$destination/.helium-profile-restore-receipt.env"
  find "$scratch" -depth -delete
  trap - EXIT
  printf 'restore=disposable-only\ngeneration=%s\nsource_destination=%s\ndestination=%s\n' \
    "$generation" "$wanted" "$destination"
}

command=${1:-}
config=${2:-}
[[ -n "$command" && -n "$config" ]] || { usage; exit 64; }
load_config "$config"
case "$command" in
  preflight)
    [[ $# -eq 2 ]] || { usage; exit 64; }
    preflight
    ;;
  backup)
    [[ $# -le 3 ]] || { usage; exit 64; }
    backup "${3:-}"
    ;;
  backup-stream)
    [[ $# -eq 6 ]] || { usage; exit 64; }
    backup_stream "$3" "$4" "$5" "$6"
    ;;
  status)
    [[ $# -eq 3 ]] || { usage; exit 64; }
    verify_generation "$3"
    printf 'status=healthy\ngeneration=%s\n' "$3"
    ;;
  receipt-export)
    [[ $# -eq 5 ]] || { usage; exit 64; }
    receipt_export "$3" "$4" "$5"
    ;;
  verify-receipt)
    [[ $# -ge 3 && $# -le 4 ]] || { usage; exit 64; }
    verify_receipt_command "$3" "${4:-}"
    ;;
  retention-apply)
    [[ $# -eq 2 ]] || { usage; exit 64; }
    retention_apply
    ;;
  quarantine)
    [[ $# -eq 5 ]] || { usage; exit 64; }
    quarantine "$3" "$4" "$5"
    ;;
  restore-to-disposable)
    [[ $# -eq 5 ]] || { usage; exit 64; }
    restore_to_disposable "$3" "$4" "$5"
    ;;
  *) usage; exit 64 ;;
esac
