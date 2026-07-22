#!/usr/bin/env bash
set -euo pipefail
umask 077

systemctl_bin=${HELIUM_BACKUP_SYSTEMCTL:-/usr/bin/systemctl}
daemon_service=${HELIUM_BACKUP_DAEMON_SERVICE:-helium-syncd.service}
archive_service=${HELIUM_BACKUP_ARCHIVE_SERVICE:-helium-sync-server-backup-archive.service}
operator_lock=${HELIUM_BACKUP_OPERATOR_LOCK:-/run/helium-sync-operator.lock}
restart_marker=${HELIUM_BACKUP_RESTART_MARKER:-/run/helium-sync-server-backup/restart-required}
command_name=${1:-}

require_absolute() {
  [[ $1 == /* ]] || {
    echo "backup control path must be absolute: $1" >&2
    exit 2
  }
}

require_root() {
  [[ $EUID -eq 0 ]] || {
    echo "server backup control must run as root" >&2
    exit 1
  }
}

validate_configuration() {
  require_absolute "$systemctl_bin"
  require_absolute "$operator_lock"
  require_absolute "$restart_marker"
  [[ "$daemon_service" == helium-syncd.service &&
      "$archive_service" == helium-sync-server-backup-archive.service ]] || {
    echo "server backup service identities are fixed" >&2
    exit 2
  }
  [[ -x "$systemctl_bin" ]] || {
    echo "systemctl is unavailable: $systemctl_bin" >&2
    exit 1
  }
}

lock_operator() {
  exec 8>"$operator_lock"
  chmod 0600 "$operator_lock"
  flock -n 8 || {
    echo "another Helium Sync production operator action is running" >&2
    exit 1
  }
}

marker_is_valid() {
  [[ -f "$restart_marker" && ! -L "$restart_marker" &&
      $(stat -c '%u:%a' "$restart_marker") == 0:600 &&
      $(cat "$restart_marker") == restart-helium-syncd-v1 ]]
}

write_restart_marker() {
  local marker_dir marker_temp
  marker_dir=$(dirname "$restart_marker")
  [[ -d "$marker_dir" && ! -L "$marker_dir" ]] || {
    echo "backup runtime directory is missing or unsafe" >&2
    return 1
  }
  [[ ! -e "$restart_marker" && ! -L "$restart_marker" ]] || {
    echo "refusing to replace an existing Helium Sync restart marker" >&2
    return 1
  }
  marker_temp=$marker_dir/.restart-required.$$
  printf 'restart-helium-syncd-v1\n' >"$marker_temp"
  chmod 0600 "$marker_temp"
  mv "$marker_temp" "$restart_marker"
}

resume_daemon() {
  [[ -e "$restart_marker" || -L "$restart_marker" ]] || return 0
  marker_is_valid || {
    echo "refusing an invalid Helium Sync restart marker" >&2
    return 1
  }
  # The archive unit is independently supervised. A controller timeout, TERM,
  # or SIGKILL must not let the daemon resume while that worker still has a
  # read-only view of a store which is becoming writable again.
  "$systemctl_bin" stop "$archive_service" || {
    echo "Helium Sync archive worker could not be stopped" >&2
    return 1
  }
  if "$systemctl_bin" is-active --quiet "$archive_service"; then
    echo "Helium Sync archive worker remained active" >&2
    return 1
  fi
  if ! "$systemctl_bin" start "$daemon_service"; then
    "$systemctl_bin" stop "$daemon_service" >/dev/null 2>&1 || true
    echo "Helium Sync daemon failed to return after backup" >&2
    return 1
  fi
  "$systemctl_bin" is-active --quiet "$daemon_service" || {
    "$systemctl_bin" stop "$daemon_service" >/dev/null 2>&1 || true
    echo "Helium Sync daemon failed to return after backup" >&2
    return 1
  }
  find "$restart_marker" -maxdepth 0 -type f -delete
  echo 'daemon_restart=verified'
}

run_backup() {
  "$systemctl_bin" is-active --quiet "$daemon_service" || {
    echo "refusing a scheduled backup while Helium Sync is not active" >&2
    return 1
  }
  write_restart_marker
  restart_required=true
  finish() {
    local result=$?
    trap - EXIT INT TERM
    if [[ ${restart_required:-false} == true ]]; then
      resume_daemon || result=1
    fi
    exit "$result"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  "$systemctl_bin" stop "$daemon_service" || {
    echo "Helium Sync daemon stop failed during backup quiesce" >&2
    return 1
  }
  if "$systemctl_bin" is-active --quiet "$daemon_service"; then
    echo "Helium Sync daemon remained active during backup quiesce" >&2
    return 1
  fi
  "$systemctl_bin" start "$archive_service"
  [[ $("$systemctl_bin" show "$archive_service" --property=Result --value) == success ]] || {
    echo "sandboxed Helium Sync archive service did not finish successfully" >&2
    return 1
  }
  resume_daemon
  restart_required=false
  trap - EXIT INT TERM
  echo 'scheduled_backup=verified'
}

require_root
validate_configuration
case "$command_name" in
  run)
    [[ $# -eq 1 ]] || exit 2
    lock_operator
    run_backup
    ;;
  resume)
    [[ $# -eq 1 ]] || exit 2
    lock_operator
    resume_daemon
    ;;
  *)
    echo "usage: $0 <run|resume>" >&2
    exit 2
    ;;
esac
