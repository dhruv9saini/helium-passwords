#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-device-probe-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

acceptance="$test_root/acceptance"
mkdir -p "$acceptance/runtime-acceptance" "$acceptance/media" "$test_root/bin"
touch "$acceptance/runtime-acceptance/fixture-server.mjs"
touch "$acceptance/runtime-acceptance/run-cdp-probe.mjs"
printf 'fixture\n' > "$acceptance/media/synthetic"
cat > "$acceptance/acceptance.env" <<'EOF'
schema_version=2
package=computer.helium.sync.test
helium_sync_commit=1111111111111111111111111111111111111111
chromium_commit=2222222222222222222222222222222222222222
version_code=787500005
version_name=150.0.7871.181
source_archive_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apk_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
runtime_kit_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
prepared_at=2026-07-22T00:00:00+00:00
EOF
(
  cd "$acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)
spki=$(printf 'A%.0s' {1..43})=
printf '{"schema_version":1,"disposable_only":true,"tls_mode":"private-ca-spki","hostname":"lm.tail0168aa.ts.net","h2_port":44723,"h3_port":44724,"leaf_spki_sha256_base64":"%s","leaf_cert_sha256":"%s","required_chromium_switch":"--ignore-certificate-errors-spki-list=%s"}\n' \
  "$spki" "$(printf 'a%.0s' {1..64})" "$spki" >"$test_root/fixture-provenance.json"

cat > "$test_root/bin/adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HELIUM_TEST_ADB_LOG"
case "$*" in
  *' get-state') printf 'device\n' ;;
  *' shell pm path computer.helium.sync.test') printf 'package:/data/app/test/base.apk\n' ;;
  *' shell dumpsys package computer.helium.sync.test')
    printf '  versionCode=787500005 minSdk=29 targetSdk=36\n  versionName=150.0.7871.181\n'
    ;;
  *' shell settings get global wifi_on') printf '1\n' ;;
  *' shell settings get global mobile_data') printf '1\n' ;;
esac
EOF
cat > "$test_root/bin/node" <<'EOF'
#!/usr/bin/env bash
script=$1
shift
case "$script" in
  */fixture-server.mjs)
    printf '{"event":"listening","origin":"http://127.0.0.1:44721"}\n'
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  */run-cdp-probe.mjs)
    output=
    ready=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output) output=$2 ;;
        --ready-file) ready=$2 ;;
      esac
      shift 2
    done
    printf '{"schema_version":1,"state":"probe_page_connected"}\n' > "$ready"
    printf '{"schema_version":1,"finished_at":"2026-07-22T00:00:00Z"}\n' > "$output"
    ;;
  *) echo "unexpected fake node script: $script" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/adb" "$test_root/bin/node"

export HELIUM_TEST_ADB_LOG="$test_root/adb.log"
PATH="$test_root/bin:$PATH" \
  "$repo_root/scripts/android-media/run-device-probe.sh" \
  "$acceptance" USB-SERIAL "$test_root/evidence" \
  --h2 'https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity' \
  --h3 'https://lm.tail0168aa.ts.net:44724/stream/fetch?encoding=identity' \
  --fixture-receipt "$test_root/fixture-provenance.json" \
  --background-foreground true --network-handoff wifi-to-cellular \
  > "$test_root/result"

grep -qx "evidence_directory=$test_root/evidence" "$test_root/result"
grep -Eq '^result_sha256=[0-9a-f]{64}$' "$test_root/result"
grep -qx 'background_foreground=true' "$test_root/evidence/actions.env"
grep -qx 'network_handoff=wifi-to-cellular' "$test_root/evidence/actions.env"
grep -qx 'version_code=787500005' "$test_root/evidence/actions.env"
grep -qx 'version_name=150.0.7871.181' "$test_root/evidence/actions.env"
grep -qx "fixture_spki_sha256_base64=$spki" "$test_root/evidence/actions.env"
grep -Eq '^fixture_receipt_sha256=[0-9a-f]{64}$' "$test_root/evidence/actions.env"
cmp "$test_root/fixture-provenance.json" "$test_root/evidence/fixture-provenance.json"
(
  cd "$test_root/evidence"
  sha256sum -c EVIDENCE_SHA256SUMS
)
grep -q 'shell input keyevent KEYCODE_HOME' "$test_root/adb.log"
grep -q 'shell monkey -p computer.helium.sync.test' "$test_root/adb.log"
grep -q 'shell svc wifi disable' "$test_root/adb.log"
grep -q 'shell svc wifi enable' "$test_root/adb.log"
grep -q 'shell dumpsys package computer.helium.sync.test' "$test_root/adb.log"
grep -q 'forward --remove tcp:9222' "$test_root/adb.log"
grep -q 'reverse --remove tcp:44721' "$test_root/adb.log"

if PATH="$test_root/bin:$PATH" \
  "$repo_root/scripts/android-media/run-device-probe.sh" \
  "$acceptance" USB-SERIAL "$test_root/missing-receipt-evidence" \
  --h2 'https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity' \
  >"$test_root/missing-receipt.out" 2>&1; then
  echo 'private fixture without its receipt unexpectedly passed' >&2
  exit 1
fi
grep -q 'require --fixture-receipt' "$test_root/missing-receipt.out"

if PATH="$test_root/bin:$PATH" \
  "$repo_root/scripts/android-media/run-device-probe.sh" \
  "$acceptance" 192.0.2.1:5555 "$test_root/network-adb-evidence" \
  --network-handoff wifi-to-cellular > "$test_root/network-adb.out" 2>&1; then
  echo 'network handoff over network ADB unexpectedly passed' >&2
  exit 1
fi
grep -q 'requires a non-network ADB transport' "$test_root/network-adb.out"

echo 'Android device probe orchestration contract passed'
