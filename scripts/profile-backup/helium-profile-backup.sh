#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: helium-profile-backup.sh <preflight|backup|status|verify-receipt|retention-apply|quarantine|restore-to-disposable> CONFIG [arguments]

  backup CONFIG [GENERATION]
  status CONFIG GENERATION
  verify-receipt CONFIG RECEIPT
  retention-apply CONFIG
  quarantine CONFIG DESTINATION-ID GENERATION REASON-SLUG
  restore-to-disposable CONFIG GENERATION NEW-DIRECTORY

CONFIG is a mode-0600 key/value file with exactly two destination=ID|PATH
entries.  Backup and restore never launch a browser or alter the source profile.
EOF
}

die() { echo "$*" >&2; exit 1; }
valid_generation() { [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]]; }
valid_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }

load_config() {
  local config=$1 line key value mode
  [[ -f "$config" && ! -L "$config" ]] || die "config must be a regular non-symlink file"
  mode=$(stat -c %a -- "$config")
  (( (8#$mode & 077) == 0 )) || die "config must not be accessible by group or other users"

  PROFILE_DEST_IDS=()
  PROFILE_DEST_ROOTS=()
  unset PROFILE_VERSION PROFILE_SOURCE_DEVICE PROFILE_ID PROFILE_SOURCE_PATH
  unset PROFILE_AGE_RECIPIENTS PROFILE_AGE_IDENTITY PROFILE_RETENTION_KEEP
  unset PROFILE_DESTINATION_RESERVE_BYTES
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || die "invalid profile backup config line"
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version) [[ -z "${PROFILE_VERSION+x}" ]] || die "duplicate version"; PROFILE_VERSION=$value ;;
      source_device) [[ -z "${PROFILE_SOURCE_DEVICE+x}" ]] || die "duplicate source_device"; PROFILE_SOURCE_DEVICE=$value ;;
      profile_id) [[ -z "${PROFILE_ID+x}" ]] || die "duplicate profile_id"; PROFILE_ID=$value ;;
      source_path) [[ -z "${PROFILE_SOURCE_PATH+x}" ]] || die "duplicate source_path"; PROFILE_SOURCE_PATH=$value ;;
      age_recipients) [[ -z "${PROFILE_AGE_RECIPIENTS+x}" ]] || die "duplicate age_recipients"; PROFILE_AGE_RECIPIENTS=$value ;;
      age_identity) [[ -z "${PROFILE_AGE_IDENTITY+x}" ]] || die "duplicate age_identity"; PROFILE_AGE_IDENTITY=$value ;;
      retention_keep) [[ -z "${PROFILE_RETENTION_KEEP+x}" ]] || die "duplicate retention_keep"; PROFILE_RETENTION_KEEP=$value ;;
      destination_reserve_bytes) [[ -z "${PROFILE_DESTINATION_RESERVE_BYTES+x}" ]] || die "duplicate destination_reserve_bytes"; PROFILE_DESTINATION_RESERVE_BYTES=$value ;;
      destination)
        IFS='|' read -r dest_id dest_root extra <<<"$value"
        [[ -n "$dest_id" && -n "$dest_root" && -z "$extra" ]] || die "invalid destination entry"
        PROFILE_DEST_IDS+=("$dest_id")
        PROFILE_DEST_ROOTS+=("$dest_root")
        ;;
      *) die "unknown profile backup config field: $key" ;;
    esac
  done <"$config"

  [[ "${PROFILE_VERSION:-}" == 1 ]] || die "unsupported profile backup config schema"
  [[ "${PROFILE_SOURCE_DEVICE:-}" =~ ^(d|da|oneplus|fixture)$ ]] || die "invalid source_device"
  valid_slug "${PROFILE_ID:-}" || die "invalid profile_id"
  [[ "${PROFILE_SOURCE_PATH:-}" == /* ]] || die "source_path must be absolute"
  [[ "${PROFILE_AGE_RECIPIENTS:-}" == /* ]] || die "age_recipients must be absolute"
  [[ "${PROFILE_AGE_IDENTITY:-}" == /* ]] || die "age_identity must be absolute"
  [[ "${PROFILE_RETENTION_KEEP:-}" =~ ^[1-9][0-9]*$ ]] || die "retention_keep must be positive"
  [[ "${PROFILE_DESTINATION_RESERVE_BYTES:-}" =~ ^[0-9]+$ ]] || die "destination_reserve_bytes must be non-negative"
  [[ ${#PROFILE_DEST_IDS[@]} -eq 2 ]] || die "exactly two destinations are required"
  [[ "${PROFILE_DEST_IDS[0]}" != "${PROFILE_DEST_IDS[1]}" ]] || die "destination ids must differ"
  local index
  for index in 0 1; do
    valid_slug "${PROFILE_DEST_IDS[$index]}" || die "invalid destination id"
    [[ "${PROFILE_DEST_ROOTS[$index]}" == /* ]] || die "destination paths must be absolute"
  done
}

recipients_fingerprint() {
  local count
  [[ -f "$PROFILE_AGE_RECIPIENTS" && ! -L "$PROFILE_AGE_RECIPIENTS" ]] || die "age recipients file is unavailable"
  count=$(awk 'NF && $1 !~ /^#/ {print $1}' "$PROFILE_AGE_RECIPIENTS" | sort -u | wc -l)
  [[ "$count" -ge 2 ]] || die "at least two distinct recovery recipients are required"
  awk 'NF && $1 !~ /^#/ {print $1}' "$PROFILE_AGE_RECIPIENTS" | sort -u | sha256sum | awk '{print $1}'
}

namespace() {
  local index=$1
  printf '%s/helium-profile-backups/%s/%s\n' \
    "${PROFILE_DEST_ROOTS[$index]%/}" "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
}

cipher_path() { printf '%s/generations/%s.tar.zst.age\n' "$(namespace "$1")" "$2"; }
receipt_path() { printf '%s/generations/%s.receipt.env\n' "$(namespace "$1")" "$2"; }

profile_path_hash() {
  printf '%s' "$(realpath -e -- "$PROFILE_SOURCE_PATH")" | sha256sum | awk '{print $1}'
}

profile_open_pid() {
  local proc fd target canonical
  canonical=$(realpath -e -- "$PROFILE_SOURCE_PATH")/
  shopt -s nullglob
  for proc in /proc/[0-9]*; do
    for fd in "$proc"/fd/*; do
      target=$(readlink -- "$fd" 2>/dev/null || true)
      case "$target" in "$canonical"*) printf '%s\n' "${proc##*/}"; shopt -u nullglob; return 0 ;; esac
    done
  done
  shopt -u nullglob
  return 1
}

ensure_source_stopped() {
  local pid
  [[ -d "$PROFILE_SOURCE_PATH" && ! -L "$PROFILE_SOURCE_PATH" ]] || die "source profile must be a real directory"
  pid=$(profile_open_pid || true)
  [[ -z "$pid" ]] || die "source profile has an open file in process $pid; stop the browser first"
}

filesystem_id() { findmnt --noheadings --output MAJ:MIN --target "$1" | awk 'NF {print $1; exit}'; }

preflight() {
  local source_real source_fs dest_real dest_fs available needed recipients index
  command -v age >/dev/null || die "age is required"
  command -v zstd >/dev/null || die "zstd is required"
  command -v findmnt >/dev/null || die "findmnt is required"
  ensure_source_stopped
  recipients=$(recipients_fingerprint)
  source_real=$(realpath -e -- "$PROFILE_SOURCE_PATH")
  source_fs=$(filesystem_id "$source_real")
  [[ -n "$source_fs" ]] || die "could not identify the source filesystem"
  needed=$(du -sb -- "$source_real" | awk '{print $1}')
  PROFILE_DEST_FILESYSTEMS=()
  for index in 0 1; do
    [[ -d "${PROFILE_DEST_ROOTS[$index]}" && ! -L "${PROFILE_DEST_ROOTS[$index]}" ]] || die "destination root must be an existing non-symlink directory"
    [[ -w "${PROFILE_DEST_ROOTS[$index]}" ]] || die "destination root is not writable"
    dest_real=$(realpath -e -- "${PROFILE_DEST_ROOTS[$index]}")
    case "$dest_real/" in "$source_real/"*) die "destination is inside the source profile" ;; esac
    case "$source_real/" in "$dest_real/"*) die "source profile is inside a destination" ;; esac
    dest_fs=$(filesystem_id "$dest_real")
    [[ -n "$dest_fs" && "$dest_fs" != "$source_fs" ]] || die "destination must use a filesystem independent of the source"
    PROFILE_DEST_FILESYSTEMS+=("$dest_fs")
    available=$(df --output=avail -B1 "$dest_real" | awk 'NR==2 {print $1}')
    (( available >= needed + PROFILE_DESTINATION_RESERVE_BYTES )) || die "destination lacks source-size budget plus reserve"
  done
  [[ "${PROFILE_DEST_FILESYSTEMS[0]}" != "${PROFILE_DEST_FILESYSTEMS[1]}" ]] || die "the two destinations must use different filesystems"
  printf 'preflight=ok\nsource_device=%s\nprofile_id=%s\nsource_bytes=%s\nrecipients_sha256=%s\n' \
    "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID" "$needed" "$recipients"
}

read_receipt() {
  local file=$1 line key value allowed
  [[ -f "$file" && ! -L "$file" ]] || die "receipt is unavailable: $file"
  declare -gA RECEIPT=()
  allowed=' schema_version source_device profile_id profile_path_sha256 archive_root generation cipher_sha256 cipher_size source_bytes recipients_sha256 created_at '
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" == *=* ]] || die "invalid profile backup receipt line"
    key=${line%%=*}; value=${line#*=}
    [[ "$key" =~ ^[a-z][a-z0-9_]*$ && "$allowed" == *" $key "* ]] || die "unknown profile backup receipt field: $key"
    [[ -z "${RECEIPT[$key]+set}" ]] || die "duplicate profile backup receipt field: $key"
    [[ -n "$value" ]] || die "empty profile backup receipt field: $key"
    RECEIPT[$key]=$value
  done <"$file"
  [[ ${#RECEIPT[@]} -eq 11 ]] || die "incomplete profile backup receipt"
  [[ "${RECEIPT[schema_version]:-}" == 1 && "${RECEIPT[source_device]:-}" == "$PROFILE_SOURCE_DEVICE" && "${RECEIPT[profile_id]:-}" == "$PROFILE_ID" ]] || die "profile backup receipt namespace mismatch"
  valid_generation "${RECEIPT[generation]:-}" || die "invalid receipt generation"
  [[ "${RECEIPT[cipher_sha256]:-}" =~ ^[a-f0-9]{64}$ && "${RECEIPT[recipients_sha256]:-}" =~ ^[a-f0-9]{64}$ && "${RECEIPT[profile_path_sha256]:-}" =~ ^[a-f0-9]{64}$ ]] || die "invalid profile backup receipt hashes"
  [[ "${RECEIPT[cipher_size]:-}" =~ ^[1-9][0-9]*$ && "${RECEIPT[source_bytes]:-}" =~ ^[0-9]+$ ]] || die "invalid profile backup receipt sizes"
  [[ "${RECEIPT[archive_root]:-}" != */* && "${RECEIPT[archive_root]:-}" != . && "${RECEIPT[archive_root]:-}" != .. ]] || die "invalid archive root"
}

verify_generation() {
  local generation=$1 index receipt cipher hash
  valid_generation "$generation" || die "invalid generation"
  for index in 0 1; do
    receipt=$(receipt_path "$index" "$generation")
    cipher=$(cipher_path "$index" "$generation")
    read_receipt "$receipt"
    [[ "${RECEIPT[generation]}" == "$generation" ]] || die "receipt generation mismatch"
    [[ "${RECEIPT[recipients_sha256]}" == "$(recipients_fingerprint)" ]] || die "recovery recipients changed"
    [[ -f "$cipher" && ! -L "$cipher" && "$(stat -c %s -- "$cipher")" == "${RECEIPT[cipher_size]}" ]] || die "cipher size mismatch at ${PROFILE_DEST_IDS[$index]}"
    hash=$(sha256sum -- "$cipher" | awk '{print $1}')
    [[ "$hash" == "${RECEIPT[cipher_sha256]}" ]] || die "cipher checksum mismatch at ${PROFILE_DEST_IDS[$index]}"
    if [[ $index -eq 0 ]]; then
      first_hash=$hash
      first_receipt_hash=$(sha256sum -- "$receipt" | awk '{print $1}')
    else
      [[ "$hash" == "$first_hash" && "$(sha256sum -- "$receipt" | awk '{print $1}')" == "$first_receipt_hash" ]] || die "destination copies disagree"
    fi
  done
}

backup() {
  local generation=${1:-} index ns incoming first_cipher first_receipt archive_root
  local cipher_hash cipher_size source_bytes recipients profile_hash temporary_receipt
  preflight >/dev/null
  [[ -n "$generation" ]] || generation="$(date -u +%Y%m%dT%H%M%SZ)-$(tr -d - </proc/sys/kernel/random/uuid | cut -c1-16)"
  valid_generation "$generation" || die "invalid generation"
  archive_root=$(basename -- "$(realpath -e -- "$PROFILE_SOURCE_PATH")")
  [[ "$archive_root" != . && "$archive_root" != .. && "$archive_root" != */* ]] || die "invalid source profile basename"
  source_bytes=$(du -sb -- "$PROFILE_SOURCE_PATH" | awk '{print $1}')
  recipients=$(recipients_fingerprint)
  profile_hash=$(profile_path_hash)

  for index in 0 1; do
    ns=$(namespace "$index")
    mkdir -p -- "$ns/generations" "$ns/incoming" "$ns/quarantine" "$ns/retired"
    chmod 700 "$ns" "$ns/generations" "$ns/incoming" "$ns/quarantine" "$ns/retired"
    [[ ! -e "$(cipher_path "$index" "$generation")" && ! -e "$(receipt_path "$index" "$generation")" ]] || die "generation already exists"
  done

  first_cipher="$(namespace 0)/incoming/$generation.tar.zst.age.partial"
  first_receipt="$(namespace 0)/incoming/$generation.receipt.env.partial"
  trap 'rm -f -- "${first_cipher:-}" "${first_receipt:-}" "${second_cipher:-}" "${second_receipt:-}"' EXIT
  tar --format=pax --numeric-owner -C "$(dirname -- "$PROFILE_SOURCE_PATH")" -cf - "$archive_root" | \
    zstd -q -T1 -3 | age --encrypt --recipients-file "$PROFILE_AGE_RECIPIENTS" --output "$first_cipher"
  chmod 600 "$first_cipher"
  cipher_hash=$(sha256sum -- "$first_cipher" | awk '{print $1}')
  cipher_size=$(stat -c %s -- "$first_cipher")
  {
    printf 'schema_version=1\nsource_device=%s\nprofile_id=%s\n' "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
    printf 'profile_path_sha256=%s\narchive_root=%s\ngeneration=%s\n' "$profile_hash" "$archive_root" "$generation"
    printf 'cipher_sha256=%s\ncipher_size=%s\nsource_bytes=%s\n' "$cipher_hash" "$cipher_size" "$source_bytes"
    printf 'recipients_sha256=%s\ncreated_at=%s\n' "$recipients" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$first_receipt"
  chmod 600 "$first_receipt"

  second_cipher="$(namespace 1)/incoming/$generation.tar.zst.age.partial"
  second_receipt="$(namespace 1)/incoming/$generation.receipt.env.partial"
  cp --reflink=never -- "$first_cipher" "$second_cipher"
  cp --reflink=never -- "$first_receipt" "$second_receipt"
  chmod 600 "$second_cipher" "$second_receipt"
  [[ "$(sha256sum -- "$second_cipher" | awk '{print $1}')" == "$cipher_hash" ]] || die "second destination copy checksum mismatch"

  mv -- "$first_cipher" "$(cipher_path 0 "$generation")"
  mv -- "$first_receipt" "$(receipt_path 0 "$generation")"
  mv -- "$second_cipher" "$(cipher_path 1 "$generation")"
  mv -- "$second_receipt" "$(receipt_path 1 "$generation")"
  trap - EXIT
  verify_generation "$generation"
  printf 'backup=committed\ngeneration=%s\ncipher_sha256=%s\nreceipt=%s\n' \
    "$generation" "$cipher_hash" "$(receipt_path 0 "$generation")"
}

verify_receipt_command() {
  local supplied=$1 expected_path=${2:-} generation canonical supplied_hash expected_hash
  read_receipt "$supplied"
  generation=${RECEIPT[generation]}
  canonical=$(receipt_path 0 "$generation")
  supplied_hash=$(sha256sum -- "$supplied" | awk '{print $1}')
  verify_generation "$generation"
  [[ "$supplied_hash" == "$(sha256sum -- "$canonical" | awk '{print $1}')" ]] || die "supplied receipt is not the committed receipt"
  if [[ -n "$expected_path" ]]; then
    [[ "$expected_path" == /* ]] || die "expected profile path must be absolute"
    expected_hash=$(printf '%s' "$expected_path" | sha256sum | awk '{print $1}')
  else
    expected_hash=$(profile_path_hash)
  fi
  [[ "${RECEIPT[profile_path_sha256]}" == "$expected_hash" ]] || die "backup receipt belongs to a different profile path"
  printf 'profile_backup_admission=verified\ngeneration=%s\nsource_device=%s\nprofile_id=%s\nprofile_path_sha256=%s\n' \
    "$generation" "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID" "${RECEIPT[profile_path_sha256]}"
}

retention_apply() {
  local index receipt generation
  mapfile -t generations < <(find "$(namespace 0)/generations" -maxdepth 1 -type f -name '*.receipt.env' -printf '%f\n' | sed 's/\.receipt\.env$//' | sort -r)
  [[ ${#generations[@]} -gt PROFILE_RETENTION_KEEP ]] || { echo 'retention=unchanged'; return; }
  for generation in "${generations[@]:PROFILE_RETENTION_KEEP}"; do
    verify_generation "$generation"
  done
  for generation in "${generations[@]:PROFILE_RETENTION_KEEP}"; do
    for index in 0 1; do
      mkdir -p "$(namespace "$index")/retired/$generation"
      chmod 700 "$(namespace "$index")/retired/$generation"
      mv -- "$(cipher_path "$index" "$generation")" "$(namespace "$index")/retired/$generation/"
      mv -- "$(receipt_path "$index" "$generation")" "$(namespace "$index")/retired/$generation/"
    done
    printf 'retired_generation=%s\n' "$generation"
  done
}

quarantine() {
  local wanted=$1 generation=$2 reason=$3 index=-1 suffix ns
  valid_generation "$generation" || die "invalid generation"
  valid_slug "$reason" || die "invalid quarantine reason"
  [[ "${PROFILE_DEST_IDS[0]}" == "$wanted" ]] && index=0
  [[ "${PROFILE_DEST_IDS[1]}" == "$wanted" ]] && index=1
  [[ $index -ge 0 ]] || die "unknown destination id"
  ns=$(namespace "$index")
  suffix="$(date -u +%Y%m%dT%H%M%SZ).$reason"
  mkdir -p "$ns/quarantine/$generation.$suffix"
  chmod 700 "$ns/quarantine/$generation.$suffix"
  [[ -e "$(cipher_path "$index" "$generation")" || -e "$(receipt_path "$index" "$generation")" ]] || die "generation is absent at destination"
  [[ ! -e "$ns/quarantine/$generation.$suffix/$generation.tar.zst.age" ]] || die "quarantine target exists"
  [[ ! -e "$(cipher_path "$index" "$generation")" ]] || mv -- "$(cipher_path "$index" "$generation")" "$ns/quarantine/$generation.$suffix/"
  [[ ! -e "$(receipt_path "$index" "$generation")" ]] || mv -- "$(receipt_path "$index" "$generation")" "$ns/quarantine/$generation.$suffix/"
  printf 'quarantined=%s\ndestination=%s\nreason=%s\n' "$generation" "$wanted" "$reason"
}

restore_to_disposable() {
  local generation=$1 destination=$2 parent temporary listing archive_root
  valid_generation "$generation" || die "invalid generation"
  [[ -f "$PROFILE_AGE_IDENTITY" && ! -L "$PROFILE_AGE_IDENTITY" ]] || die "age identity is unavailable"
  [[ "$destination" == /* && ! -e "$destination" ]] || die "restore destination must be a new absolute path"
  [[ "$(basename -- "$destination")" == drill-* ]] || die "restore destination name must start with drill-"
  parent=$(dirname -- "$destination")
  [[ -d "$parent" && ! -L "$parent" && -f "$parent/.helium-disposable-profile-restore-root" ]] || die "restore parent lacks the disposable marker"
  [[ "$(stat -c %a -- "$parent")" == 700 ]] || die "restore parent must have mode 0700"
  verify_generation "$generation"
  read_receipt "$(receipt_path 0 "$generation")"
  archive_root=${RECEIPT[archive_root]}
  temporary="$parent/.restore-$generation.$$"
  listing="$parent/.restore-list-$generation.$$.txt"
  trap 'rm -rf -- "${temporary:-}"; rm -f -- "${listing:-}"' EXIT
  mkdir -m 700 "$temporary"
  age --decrypt --identity "$PROFILE_AGE_IDENTITY" "$(cipher_path 0 "$generation")" | zstd -q -d | tar -tf - >"$listing"
  awk -v root="$archive_root" '
    /^\// {exit 1}
    /(^|\/)\.\.($|\/)/ {exit 1}
    $0 != root && index($0, root "/") != 1 {exit 1}
    END {if (NR == 0) exit 1}
  ' "$listing" || die "backup archive contains unsafe or foreign paths"
  age --decrypt --identity "$PROFILE_AGE_IDENTITY" "$(cipher_path 0 "$generation")" | zstd -q -d | tar --no-same-owner --no-same-permissions -xf - -C "$temporary"
  [[ -d "$temporary/$archive_root" && ! -L "$temporary/$archive_root" ]] || die "restored archive root is invalid"
  mv -- "$temporary/$archive_root" "$destination"
  rmdir "$temporary"
  {
    printf 'schema_version=1\ngeneration=%s\nsource_device=%s\nprofile_id=%s\n' "$generation" "$PROFILE_SOURCE_DEVICE" "$PROFILE_ID"
    printf 'cipher_sha256=%s\nrestored_at=%s\n' "${RECEIPT[cipher_sha256]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$destination/.helium-profile-restore-receipt.env"
  chmod 600 "$destination/.helium-profile-restore-receipt.env"
  rm -f "$listing"
  trap - EXIT
  printf 'restore=disposable-only\ngeneration=%s\ndestination=%s\n' "$generation" "$destination"
}

command=${1:-}; config=${2:-}
[[ -n "$command" && -n "$config" ]] || { usage; exit 64; }
load_config "$config"
case "$command" in
  preflight) [[ $# -eq 2 ]] || { usage; exit 64; }; preflight ;;
  backup) [[ $# -le 3 ]] || { usage; exit 64; }; backup "${3:-}" ;;
  status) [[ $# -eq 3 ]] || { usage; exit 64; }; verify_generation "$3"; printf 'status=healthy\ngeneration=%s\n' "$3" ;;
  verify-receipt) [[ $# -ge 3 && $# -le 4 ]] || { usage; exit 64; }; verify_receipt_command "$3" "${4:-}" ;;
  retention-apply) [[ $# -eq 2 ]] || { usage; exit 64; }; retention_apply ;;
  quarantine) [[ $# -eq 5 ]] || { usage; exit 64; }; quarantine "$3" "$4" "$5" ;;
  restore-to-disposable) [[ $# -eq 4 ]] || { usage; exit 64; }; restore_to_disposable "$3" "$4" ;;
  *) usage; exit 64 ;;
esac
