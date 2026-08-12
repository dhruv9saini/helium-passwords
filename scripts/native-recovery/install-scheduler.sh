#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
home_dir=${HOME:?HOME is required}
unit_root=${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user
config_root=${XDG_CONFIG_HOME:-$home_dir/.config}/helium-native-recovery
release_root=$home_dir/.local/libexec/helium-native-recovery
service=helium-native-recovery-backup.service
timer=helium-native-recovery-backup.timer

usage() {
  cat >&2 <<'EOF'
usage: install-scheduler.sh <install CONFIG|enable|disable|status>

Install one inactive six-hour native password/cookie snapshot backup timer on
d, da, or lm (for OnePlus). Enable first runs a complete two-destination
generation; it never activates a timer on write-only or unverified routes.
EOF
}

host_short() { uname -n | cut -d. -f1; }

install_scheduler() {
  [[ $# -eq 1 ]] || { usage; exit 64; }
  local source_config=$1 device host commit release incoming package exec_line
  source_config=$(realpath -e -- "$source_config")
  [[ -f "$source_config" && ! -L "$source_config" ]] || {
    echo "scheduler config must be a real file" >&2
    exit 1
  }
  [[ "$(stat -c %a "$source_config")" == 600 ]] || {
    echo "scheduler config must have mode 0600" >&2
    exit 1
  }
  device=$(awk -F= '$1 == "source_device" {print $2}' "$source_config")
  host=$(host_short)
  case "$device:$host" in
    d:d|da:da|oneplus:lm) ;;
    *) echo "native recovery source/host pairing is invalid: $device on $host" >&2; exit 1 ;;
  esac
  [[ ! -e "$config_root/backup.conf" && ! -L "$config_root/backup.conf" &&
    ! -e "$unit_root/$service" && ! -L "$unit_root/$service" &&
    ! -e "$unit_root/$timer" && ! -L "$unit_root/$timer" ]] || {
    echo "native recovery scheduler already has local state" >&2
    exit 1
  }
  git -C "$repo_root" diff --quiet
  git -C "$repo_root" diff --cached --quiet
  commit=$(git -C "$repo_root" rev-parse HEAD)
  release=$release_root/$commit
  if [[ ! -d "$release" ]]; then
    incoming=$release_root/.incoming-$commit.$$
    trap 'find "${incoming:-}" -depth -delete 2>/dev/null || true' EXIT
    mkdir -p "$incoming" "$release_root"
    install -m0755 "$repo_root/scripts/profile-backup/helium-profile-backup.sh" \
      "$incoming/helium-profile-backup"
    install -m0755 "$repo_root/scripts/android-local/backup-android-native-recovery.sh" \
      "$incoming/backup-android-native-recovery"
    install -m0755 "$repo_root/scripts/native-recovery/backup.sh" \
      "$incoming/backup-native-recovery"
    install -m0755 "$repo_root/scripts/native-recovery/acceptance.mjs" \
      "$incoming/acceptance.mjs"
    mv "$incoming" "$release"
    trap - EXIT
  fi
  mkdir -p "$config_root" "$unit_root"
  chmod 0700 "$config_root"
  install -m0600 "$source_config" "$config_root/backup.conf"

  if [[ "$device" == oneplus ]]; then
    case $(awk -F= '$1 == "source_path" {print $2}' "$source_config") in
      /data/user/0/computer.helium.passwords.test/*) package=computer.helium.passwords.test ;;
      *) echo "OnePlus scheduler is disposable .test-package only" >&2; exit 1 ;;
    esac
    exec_line="Environment=CHROMIUM_ANDROID_PACKAGE=$package ANDROID_ADB_SERIAL=oneplus:5555 HELIUM_PROFILE_BACKUP_TOOL=$release/helium-profile-backup HELIUM_NATIVE_RECOVERY_ACCEPTANCE=$release/acceptance.mjs
ExecStart=$release/backup-android-native-recovery $config_root/backup.conf"
  else
    exec_line="Environment=HELIUM_PROFILE_BACKUP_TOOL=$release/helium-profile-backup HELIUM_NATIVE_RECOVERY_ACCEPTANCE=$release/acceptance.mjs
ExecStart=$release/backup-native-recovery $config_root/backup.conf"
  fi

  {
    printf '[Unit]\nDescription=Helium browser-native password/cookie snapshot backup\nAfter=network-online.target tailscaled.service\nWants=network-online.target\n\n'
    printf '[Service]\nType=oneshot\nUMask=0077\n%s\n' "$exec_line"
    printf 'NoNewPrivileges=true\nPrivateTmp=true\nProtectSystem=strict\nProtectHome=read-only\n'
    printf 'ProtectControlGroups=true\nProtectKernelModules=true\nProtectKernelTunables=true\nRestrictSUIDSGID=true\nLockPersonality=true\n'
    if [[ "$device" == oneplus ]]; then
      printf 'ReadWritePaths=/srv/nas/helium-profile-backups\n'
    fi
  } >"$unit_root/$service"
  {
    printf '[Unit]\nDescription=Six-hour Helium browser-native password/cookie backup\n\n'
    printf '[Timer]\nOnCalendar=*-*-* 00,06,12,18:17:00\nRandomizedDelaySec=5m\nPersistent=true\nUnit=%s\n\n' "$service"
    printf '[Install]\nWantedBy=timers.target\n'
  } >"$unit_root/$timer"
  chmod 0600 "$unit_root/$service" "$unit_root/$timer"
  systemctl --user daemon-reload
  printf 'scheduler=installed-inactive\nsource_device=%s\nrelease=%s\n' "$device" "$release"
}

enable_scheduler() {
  [[ -f "$unit_root/$service" && -f "$unit_root/$timer" &&
    -f "$config_root/backup.conf" ]] || {
    echo "native recovery scheduler is not installed" >&2
    exit 1
  }
  systemctl --user start "$service"
  [[ "$(systemctl --user show "$service" -p Result --value)" == success ]] || {
    echo "initial native recovery backup did not pass" >&2
    exit 1
  }
  systemctl --user enable --now "$timer"
  systemctl --user is-active --quiet "$timer"
  echo 'scheduler=enabled-after-verified-generation'
}

disable_scheduler() {
  systemctl --user disable --now "$timer"
  echo 'scheduler=disabled'
}

status_scheduler() {
  systemctl --user show "$timer" -p ActiveState -p SubState -p Result
  systemctl --user show "$service" -p ActiveState -p SubState -p Result \
    -p ExecMainCode -p ExecMainStatus
  journalctl --user-unit "$service" -n 20 --no-pager
}

case ${1:-} in
  install) shift; install_scheduler "$@" ;;
  enable) [[ $# -eq 1 ]] || { usage; exit 64; }; enable_scheduler ;;
  disable) [[ $# -eq 1 ]] || { usage; exit 64; }; disable_scheduler ;;
  status) [[ $# -eq 1 ]] || { usage; exit 64; }; status_scheduler ;;
  *) usage; exit 64 ;;
esac
