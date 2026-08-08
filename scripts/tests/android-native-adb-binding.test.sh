#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-native-adb-binding.XXXXXX")
cleanup() { find "$temporary" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

mkdir -m 0700 "$temporary/bin"
cat >"$temporary/bin/adb" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>'$temporary/adb.log'
case "\$*" in
  'connect oneplus:5555') ;;
  '-s oneplus:5555 get-state') printf 'device\n' ;;
  *) exit 70 ;;
esac
EOF
chmod 0700 "$temporary/bin/adb"

backup=$repo_root/scripts/android-local/backup-android-native-recovery.sh
if ADB="$temporary/bin/adb" ANDROID_ADB_SERIAL=other:5555 \
  "$backup" "$temporary/missing.conf" >/dev/null 2>&1; then
  echo "Android native backup accepted a foreign ADB endpoint" >&2
  exit 1
fi
test ! -e "$temporary/adb.log"

if ADB="$temporary/bin/adb" ANDROID_ADB_SERIAL=oneplus:5555 \
  "$backup" "$temporary/missing.conf" >/dev/null 2>&1; then
  echo "Android native backup accepted a missing config" >&2
  exit 1
fi
test "$(cat "$temporary/adb.log")" = $'connect oneplus:5555\n-s oneplus:5555 get-state'

printf 'android_native_adb_binding=passed\n'
