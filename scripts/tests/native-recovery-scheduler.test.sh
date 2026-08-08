#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
installer=$repo_root/scripts/native-recovery/install-scheduler.sh
temporary=$(mktemp -d)
cleanup() { find "$temporary" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT
chmod 0700 "$temporary"
mkdir -m 0700 "$temporary/home" "$temporary/config" "$temporary/bin"

cat >"$temporary/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --user && "$2" == daemon-reload ]]
EOF
chmod 0700 "$temporary/bin/systemctl"

config=$temporary/da.conf
cp "$repo_root/scripts/native-recovery/da.conf.example" "$config"
chmod 0600 "$config"
HOME=$temporary/home XDG_CONFIG_HOME=$temporary/config \
  PATH="$temporary/bin:$PATH" "$installer" install "$config" \
  >"$temporary/result.env"
grep -qx 'scheduler=installed-inactive' "$temporary/result.env"
grep -qx 'source_device=da' "$temporary/result.env"
commit=$(git -C "$repo_root" rev-parse HEAD)
grep -qx "release=$temporary/home/.local/libexec/helium-native-recovery/$commit" \
  "$temporary/result.env"

service=$temporary/config/systemd/user/helium-native-recovery-backup.service
timer=$temporary/config/systemd/user/helium-native-recovery-backup.timer
installed_config=$temporary/config/helium-native-recovery/backup.conf
test -f "$service" -a ! -L "$service"
test -f "$timer" -a ! -L "$timer"
test "$(stat -c %a "$service")" = 600
test "$(stat -c %a "$timer")" = 600
test "$(stat -c %a "$installed_config")" = 600
grep -qx 'Type=oneshot' "$service"
grep -qx 'UMask=0077' "$service"
grep -qx 'NoNewPrivileges=true' "$service"
grep -qx 'ProtectSystem=strict' "$service"
grep -qx 'ProtectHome=read-only' "$service"
grep -qx 'OnCalendar=\*-\*-\* 00,06,12,18:17:00' "$timer"
grep -qx 'Persistent=true' "$timer"
test -x "$temporary/home/.local/libexec/helium-native-recovery/$commit/backup-native-recovery"
test -x "$temporary/home/.local/libexec/helium-native-recovery/$commit/acceptance.mjs"

if HOME=$temporary/home XDG_CONFIG_HOME=$temporary/config \
  PATH="$temporary/bin:$PATH" "$installer" install "$config" \
  >/dev/null 2>&1; then
  echo "scheduler installer unexpectedly replaced existing state" >&2
  exit 1
fi

echo "native recovery scheduler tests passed"
