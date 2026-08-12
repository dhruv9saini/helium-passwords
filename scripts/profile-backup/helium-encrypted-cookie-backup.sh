#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat >&2 <<'EOF'
usage: helium-encrypted-cookie-backup.sh <init|backup|check|retention|restore> CONFIG [SNAPSHOT NEW-DIRECTORY NEW-RECEIPT]

Create and restore the independent C3 encrypted disposable-profile repository.
Real repositories are owned by da below
/home/d/.local/share/helium-encrypted-profile-backups/DEVICE/PROFILE.
EOF
}

die() { echo "$*" >&2; exit 1; }
host_short() { uname -n | cut -d. -f1; }
safe_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }
absolute_safe() {
  [[ "$1" == /* && "$1" != *$'\n'* && "/$1/" != *"/../"* ]]
}

load_config() {
  local file=$1 line key value mode
  [[ -f "$file" && ! -L "$file" ]] || die "config must be a regular non-symlink file"
  mode=$(stat -c %a -- "$file")
  (( (8#$mode & 077) == 0 )) || die "config must be private"
  unset C3_VERSION C3_DEVICE C3_PROFILE C3_SOURCE C3_REPOSITORY
  unset C3_PASSWORD_FILE C3_KEEP_LAST C3_KEEP_DAILY C3_KEEP_WEEKLY
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] ||
      die "invalid config line"
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version) [[ -z ${C3_VERSION+x} ]] || die "duplicate version"; C3_VERSION=$value ;;
      source_device) [[ -z ${C3_DEVICE+x} ]] || die "duplicate source_device"; C3_DEVICE=$value ;;
      profile_id) [[ -z ${C3_PROFILE+x} ]] || die "duplicate profile_id"; C3_PROFILE=$value ;;
      source_path) [[ -z ${C3_SOURCE+x} ]] || die "duplicate source_path"; C3_SOURCE=$value ;;
      repository) [[ -z ${C3_REPOSITORY+x} ]] || die "duplicate repository"; C3_REPOSITORY=$value ;;
      password_file) [[ -z ${C3_PASSWORD_FILE+x} ]] || die "duplicate password_file"; C3_PASSWORD_FILE=$value ;;
      keep_last) [[ -z ${C3_KEEP_LAST+x} ]] || die "duplicate keep_last"; C3_KEEP_LAST=$value ;;
      keep_daily) [[ -z ${C3_KEEP_DAILY+x} ]] || die "duplicate keep_daily"; C3_KEEP_DAILY=$value ;;
      keep_weekly) [[ -z ${C3_KEEP_WEEKLY+x} ]] || die "duplicate keep_weekly"; C3_KEEP_WEEKLY=$value ;;
      *) die "unknown config field: $key" ;;
    esac
  done <"$file"
  [[ ${C3_VERSION:-} == 1 ]] || die "unsupported config version"
  [[ ${C3_DEVICE:-} =~ ^(d|da|oneplus|fixture)$ ]] || die "invalid source_device"
  safe_slug "${C3_PROFILE:-}" || die "invalid profile_id"
  absolute_safe "${C3_SOURCE:-}" || die "source_path must be safe and absolute"
  absolute_safe "${C3_REPOSITORY:-}" || die "repository must be safe and absolute"
  absolute_safe "${C3_PASSWORD_FILE:-}" || die "password_file must be safe and absolute"
  for value in "${C3_KEEP_LAST:-}" "${C3_KEEP_DAILY:-}" "${C3_KEEP_WEEKLY:-}"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "retention values must be positive"
  done
  [[ $(host_short) == da ]] || die "encrypted recovery repositories are owned by da"
  if [[ $C3_DEVICE != fixture ]]; then
    [[ "$C3_REPOSITORY" == "/home/d/.local/share/helium-encrypted-profile-backups/$C3_DEVICE/$C3_PROFILE" ]] ||
      die "repository is outside the fixed da-owned namespace"
  fi
  [[ -f "$C3_PASSWORD_FILE" && ! -L "$C3_PASSWORD_FILE" &&
    $(stat -c %a -- "$C3_PASSWORD_FILE") == 600 &&
    $(stat -c %u -- "$C3_PASSWORD_FILE") == "$(id -u)" &&
    -s "$C3_PASSWORD_FILE" ]] || die "password_file must be owned, nonempty, mode 0600, and not a symlink"
  command -v restic >/dev/null || die "restic is required"
  export RESTIC_REPOSITORY=$C3_REPOSITORY
  export RESTIC_PASSWORD_FILE=$C3_PASSWORD_FILE
}

require_disposable_stopped_source() {
  [[ -d "$C3_SOURCE" && ! -L "$C3_SOURCE" &&
    $(stat -c %u -- "$C3_SOURCE") == "$(id -u)" ]] ||
    die "source profile must be an owned real directory"
  [[ -f "$C3_SOURCE/.helium-cookie-backup-disposable-v1" &&
    ! -L "$C3_SOURCE/.helium-cookie-backup-disposable-v1" ]] ||
    die "source profile lacks the disposable cookie-backup marker"
  grep -Fqx 'helium-cookie-backup-disposable-v1' \
    "$C3_SOURCE/.helium-cookie-backup-disposable-v1" ||
    die "source profile has an invalid disposable marker"
  [[ ! -e "$C3_SOURCE/SingletonLock" && ! -L "$C3_SOURCE/SingletonLock" ]] ||
    die "source profile may still be open"
}

restic_run() { restic "$@"; }

initialize() {
  [[ ! -e "$C3_REPOSITORY" && ! -L "$C3_REPOSITORY" ]] ||
    die "repository already exists"
  mkdir -p "$(dirname "$C3_REPOSITORY")"
  restic_run init
  restic_run check
  printf 'repository=initialized\npath=%s\n' "$C3_REPOSITORY"
}

backup_profile() {
  require_disposable_stopped_source
  [[ -f "$C3_REPOSITORY/config" && ! -L "$C3_REPOSITORY/config" ]] ||
    die "repository is not initialized"
  local source_parent source_name output snapshot
  source_parent=$(dirname "$C3_SOURCE")
  source_name=$(basename "$C3_SOURCE")
  output=$(cd "$source_parent" && restic_run backup --json --one-file-system \
    --host "da-$C3_DEVICE" --tag helium-cookie-c3-v1 -- "$source_name")
  snapshot=$(node -e '
    const lines = require("fs").readFileSync(0, "utf8").trim().split(/\n/);
    const item = lines.map(line => JSON.parse(line)).find(value => value.message_type === "summary");
    if (!item || !/^[0-9a-f]{64}$/.test(item.snapshot_id || "")) process.exit(1);
    process.stdout.write(item.snapshot_id);
  ' <<<"$output")
  restic_run check --read-data-subset=10%
  printf 'backup=verified\nsnapshot=%s\ndevice=%s\nprofile=%s\n' \
    "$snapshot" "$C3_DEVICE" "$C3_PROFILE"
}

check_repository() {
  restic_run check --read-data
  restic_run snapshots --json --host "da-$C3_DEVICE" --tag helium-cookie-c3-v1 \
    | node -e '
      const value = JSON.parse(require("fs").readFileSync(0, "utf8"));
      if (!Array.isArray(value) || value.some(item => !/^[0-9a-f]{64}$/.test(item.id || ""))) process.exit(1);
      process.stdout.write(`integrity=verified\nsnapshots=${value.length}\n`);
    '
}

apply_retention() {
  restic_run forget --host "da-$C3_DEVICE" --tag helium-cookie-c3-v1 \
    --keep-last "$C3_KEEP_LAST" --keep-daily "$C3_KEEP_DAILY" \
    --keep-weekly "$C3_KEEP_WEEKLY" --prune
  restic_run check --read-data-subset=10%
  echo 'retention=verified'
}

restore_profile() {
  [[ $# -eq 3 ]] || { usage; exit 64; }
  local snapshot=$1 target=$2 receipt=$3 parent incoming source_name
  local tree_sha repository_config_sha restic_version completed_at temporary_receipt
  [[ "$snapshot" =~ ^[0-9a-f]{64}$ ]] || die "snapshot must be an exact full ID"
  absolute_safe "$target" || die "restore target must be safe and absolute"
  absolute_safe "$receipt" || die "restore receipt must be safe and absolute"
  [[ ! -e "$target" && ! -L "$target" ]] || die "restore target already exists"
  [[ ! -e "$receipt" && ! -L "$receipt" ]] || die "restore receipt already exists"
  parent=$(dirname "$target")
  [[ -d "$parent" && ! -L "$parent" &&
    -f "$parent/.helium-disposable-profile-restore-root" &&
    ! -L "$parent/.helium-disposable-profile-restore-root" ]] ||
    die "restore parent lacks the disposable restore marker"
  source_name=$(basename "$C3_SOURCE")
  incoming=$(mktemp -d "$parent/.helium-restic-restore.XXXXXX")
  trap 'find "${incoming:-}" -depth -delete 2>/dev/null || true' EXIT
  restic_run restore "$snapshot" --target "$incoming" --include "/$source_name"
  [[ -d "$incoming/$source_name" && ! -L "$incoming/$source_name" ]] ||
    die "restic restore did not contain the expected profile"
  mv "$incoming/$source_name" "$target"
  find "$incoming" -depth -delete
  trap - EXIT
  restic_run check --read-data-subset=10%
  tree_sha=$(tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --format=posix --pax-option=delete=atime,delete=ctime -cf - -C "$target" . \
    | sha256sum | cut -d' ' -f1)
  repository_config_sha=$(sha256sum "$C3_REPOSITORY/config" | cut -d' ' -f1)
  restic_version=$(restic version | awk 'NR == 1 {print $2}')
  [[ "$restic_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "restic emitted an invalid version"
  completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$receipt")"
  temporary_receipt=$(mktemp "$(dirname "$receipt")/.helium-cookie-c3-receipt.XXXXXX")
  {
    printf 'schema_version=1\n'
    printf 'mechanism=encrypted-restic-profile\n'
    printf 'source_device=%s\n' "$C3_DEVICE"
    printf 'profile_id=%s\n' "$C3_PROFILE"
    printf 'snapshot=%s\n' "$snapshot"
    printf 'repository_config_sha256=%s\n' "$repository_config_sha"
    printf 'restored_tree_sha256=%s\n' "$tree_sha"
    printf 'restic_version=%s\n' "$restic_version"
    printf 'integrity_check=read-data-subset-10-percent-after-restore\n'
    printf 'completed_at=%s\n' "$completed_at"
  } >"$temporary_receipt"
  chmod 0600 "$temporary_receipt"
  ln "$temporary_receipt" "$receipt"
  find "$temporary_receipt" -delete
  printf 'restore=verified\nsnapshot=%s\ntarget=%s\nreceipt=%s\nrestored_tree_sha256=%s\n' \
    "$snapshot" "$target" "$receipt" "$tree_sha"
}

[[ $# -ge 2 ]] || { usage; exit 64; }
command=$1
config=$2
shift 2
load_config "$config"
case "$command" in
  init) [[ $# -eq 0 ]] || { usage; exit 64; }; initialize ;;
  backup) [[ $# -eq 0 ]] || { usage; exit 64; }; backup_profile ;;
  check) [[ $# -eq 0 ]] || { usage; exit 64; }; check_repository ;;
  retention) [[ $# -eq 0 ]] || { usage; exit 64; }; apply_retention ;;
  restore) restore_profile "$@" ;;
  *) usage; exit 64 ;;
esac
