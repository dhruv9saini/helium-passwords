#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner=$repo_root/scripts/native-recovery/runtime-drill.sh
temporary=$(mktemp -d)
cleanup() { find "$temporary" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT
chmod 0700 "$temporary"

records_sha=$(printf '[]' | sha256sum | cut -d' ' -f1)
state_sha=$(printf '' | sha256sum | cut -d' ' -f1)
snapshot=$temporary/passwords.current.json
printf '{"schema_version":1,"kind":"passwords","format":"chromium-password-specifics-neutral-v1","source_device":"da","captured_at_windows_us":"13397000000000000","record_count":0,"records":[],"records_sha256":"%s","state_sha256":"%s"}\n' \
  "$records_sha" "$state_sha" >"$snapshot"
chmod 0600 "$snapshot"

browser=$temporary/fake-helium
cat >"$browser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
profile=
snapshot=
for argument in "$@"; do
  case "$argument" in
    --user-data-dir=*) profile=${argument#*=} ;;
    --helium-restore-disposable-native-passwords=*) snapshot=${argument#*=} ;;
  esac
done
[[ -n "$profile" && -n "$snapshot" ]]
receipt=$profile/Default/helium-sync/native-recovery-receipt-v1.json
mkdir -m 0700 "$profile/Default/helium-sync"
snapshot_sha=$(sha256sum "$snapshot" | cut -d' ' -f1)
records_sha=$(jq -er '.records_sha256' "$snapshot")
state_sha=$(jq -er '.state_sha256' "$snapshot")
printf '{"schema_version":1,"result":"passed","kind":"passwords","snapshot_sha256":"%s","records_sha256":"%s","restored_state_sha256":"%s","restored_count":0,"browser_api":"PasswordStoreInterface","completed_at_windows_us":"13397000000000100"}\n' \
  "$snapshot_sha" "$records_sha" "$state_sha" >"$receipt"
chmod 0600 "$receipt"
sleep 30
EOF
chmod 0700 "$browser"

root=$temporary/drills
mkdir -m 0700 "$root"
printf 'helium-native-recovery-drill-root-v1\n' \
  >"$root/.helium-native-recovery-drill-root-v1"
chmod 0600 "$root/.helium-native-recovery-drill-root-v1"
profile=$root/drill-fixture
output=$("$runner" desktop "$browser" da passwords "$snapshot" "$profile" \
  headless 15)
grep -qx 'runtime_recovery=passed' <<<"$output"
grep -qx 'platform=desktop' <<<"$output"
grep -qx 'device=da' <<<"$output"
grep -qx 'kind=passwords' <<<"$output"
grep -qx "profile=$profile" <<<"$output"
test -s "$profile/Default/helium-sync/native-recovery-receipt-v1.json"
test "$(stat -c %a \
  "$profile/Default/helium-sync/native-recovery-receipt-v1.json")" = 600

if "$runner" desktop "$browser" da passwords "$snapshot" "$profile" \
  headless 15 >/dev/null 2>&1; then
  echo "runtime drill unexpectedly reused an existing profile" >&2
  exit 1
fi

echo "native recovery runtime drill tests passed"
