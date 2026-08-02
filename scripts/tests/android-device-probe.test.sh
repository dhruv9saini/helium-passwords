#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-device-probe-test.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

acceptance="$test_root/acceptance"
mkdir -p "$acceptance/runtime-acceptance" "$acceptance/media" "$test_root/bin"
touch "$acceptance/runtime-acceptance/fixture-server.mjs"
touch "$acceptance/runtime-acceptance/run-cdp-probe.mjs"
printf 'fixture\n' > "$acceptance/media/synthetic"
printf 'admitted disposable APK\n' > "$acceptance/Browser-test.apk"
apk_sha256=$(sha256sum "$acceptance/Browser-test.apk" | cut -d' ' -f1)
cat > "$acceptance/acceptance.env" <<EOF
schema_version=2
package=computer.helium.sync.test
helium_sync_commit=1111111111111111111111111111111111111111
chromium_commit=2222222222222222222222222222222222222222
version_code=787500005
version_name=150.0.7871.181
source_archive_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apk_sha256=$apk_sha256
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
  'devices -l') printf 'List of devices attached\nUSB-SERIAL\tdevice usb:1-2 product:CPH2655 model:CPH2655 device:dodge transport_id:7\n' ;;
  *' get-state') printf 'device\n' ;;
  *' shell getprop ro.product.model') printf 'CPH2655\n' ;;
  *' shell getprop ro.product.device') printf 'dodge\n' ;;
  *' shell getprop ro.product.name') printf 'CPH2655\n' ;;
  *' shell getprop ro.product.manufacturer') printf 'OnePlus\n' ;;
  *' shell getprop ro.build.fingerprint') printf 'OnePlus/CPH2655/dodge:15/fixture:user/release-keys\n' ;;
  *' shell pm path computer.helium.sync.test') printf 'package:/data/app/test/base.apk\n' ;;
  *' exec-out cat /data/app/test/base.apk') cat "$HELIUM_TEST_INSTALLED_APK" ;;
  *' shell dumpsys package computer.helium.sync.test')
    printf '  userId=10123\n  versionCode=787500005 minSdk=29 targetSdk=36\n  versionName=150.0.7871.181\n'
    ;;
  *' shell pidof computer.helium.sync.test') printf '1234\n' ;;
  *' shell cat /proc/net/unix')
    printf '00000000: 00000002 00000000 00010000 0001 01 12345 @helium_sync_test_devtools_remote\n'
    ;;
  *' shell settings get global wifi_on') printf '1\n' ;;
  *' shell settings get global mobile_data') printf '1\n' ;;
  *' logcat --uid=10123 -v threadtime '*)
    printf 'synthetic package-only logcat\n'
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  *' exec-out run-as computer.helium.sync.test cat app_chrome/Default/helium-sync/cookie-native-acceptance.json')
    cat "$HELIUM_TEST_COOKIE_REPORT"
    ;;
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
    printf '%s\n' "$*" > "$HELIUM_TEST_NODE_LOG"
    output=
    media=
    ready=
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output) output=$2 ;;
        --media-diagnostics) media=$2 ;;
        --ready-file) ready=$2 ;;
      esac
      shift 2
    done
    printf '{"schema_version":1,"state":"probe_page_connected"}\n' > "$ready"
    if [[ "${HELIUM_TEST_PROBE_FAIL:-false}" == true ]]; then
      printf '{"schema_version":1,"synthetic_fixture_only":true,"source":"CDP Media domain","enabled":true,"event_count":1,"player_count":1,"method_counts":{"Media.playerErrorsRaised":1},"events":[{"method":"Media.playerErrorsRaised","params":{"playerId":"synthetic"}}]}\n' > "$media"
      echo 'synthetic probe failure' >&2
      exit 7
    fi
    printf '{"schema_version":1,"finished_at":"2026-07-22T00:00:00Z"}\n' > "$output"
    printf '{"schema_version":1,"synthetic_fixture_only":true,"source":"CDP Media domain","enabled":true,"event_count":1,"player_count":1,"method_counts":{"Media.playerEventsAdded":1},"events":[{"method":"Media.playerEventsAdded","params":{"playerId":"synthetic"}}]}\n' > "$media"
    ;;
  *) echo "unexpected fake node script: $script" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/adb" "$test_root/bin/node"

export HELIUM_TEST_ADB_LOG="$test_root/adb.log"
export HELIUM_TEST_INSTALLED_APK="$acceptance/Browser-test.apk"
export HELIUM_TEST_NODE_LOG="$test_root/node.log"
export HELIUM_TEST_COOKIE_REPORT="$test_root/cookie-native-acceptance.json"
jq -n '{
  schema_version:1,fixture:"helium-cookie-manager-disposable-v1",
  synthetic_only:true,status:"passed",reason:"",
  cookie_api:"network::mojom::CookieManager",
  destination_snapshot:{complete_profile_cookie_count:1,
    snapshot_persisted_before_apply:true,fingerprint:("a" * 64)},
  import:{record_count:3,apply_result:"accepted",readback_result:"exact",
    fingerprint:("b" * 64),canonical_record_keys_unique:true,
    partitioned_and_unpartitioned_identity_distinct:true,
    attribute_coverage:{session:true,persistent:true,http_only:true,secure:true,
      same_site:true,host_only:true,domain:true,partitioned:true}},
  destination_rejection:{set_result:"rejected",rollback_result:"exact",
    destination_fingerprint:("a" * 64)},
  origin_state:{cookie_names_guessed:false,cookie_manager_supported:true,
    registered_adapter_count:0,non_cookie_transfer_result:"not-tested"},
  cleanup:{complete_profile_cookie_store:"empty"}
}' > "$HELIUM_TEST_COOKIE_REPORT"
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
grep -qx 'package_uid=10123' "$test_root/evidence/actions.env"
grep -qx 'logcat_scope=package-uid' "$test_root/evidence/actions.env"
grep -qx 'cookie_acceptance=true' "$test_root/evidence/actions.env"
grep -qx "installed_apk_sha256=$apk_sha256" "$test_root/evidence/actions.env"
grep -qx 'device_socket=helium_sync_test_devtools_remote' "$test_root/evidence/actions.env"
grep -qx "fixture_spki_sha256_base64=$spki" "$test_root/evidence/actions.env"
grep -Eq '^fixture_receipt_sha256=[0-9a-f]{64}$' "$test_root/evidence/actions.env"
cmp "$test_root/fixture-provenance.json" "$test_root/evidence/fixture-provenance.json"
cmp "$HELIUM_TEST_COOKIE_REPORT" "$test_root/evidence/cookie-native-acceptance.json"
grep -q 'synthetic package-only logcat' "$test_root/evidence/package-logcat.txt"
jq -e '.source == "CDP Media domain" and .player_count == 1' \
  "$test_root/evidence/media-diagnostics.json" >/dev/null
(
  cd "$test_root/evidence"
  sha256sum -c EVIDENCE_SHA256SUMS
)
grep -q 'shell input keyevent KEYCODE_HOME' "$test_root/adb.log"
grep -q 'shell monkey -p computer.helium.sync.test' "$test_root/adb.log"
grep -q 'shell svc wifi disable' "$test_root/adb.log"
grep -q 'shell svc wifi enable' "$test_root/adb.log"
grep -q 'shell dumpsys package computer.helium.sync.test' "$test_root/adb.log"
grep -q 'exec-out cat /data/app/test/base.apk' "$test_root/adb.log"
grep -q 'localabstract:helium_sync_test_devtools_remote' "$test_root/adb.log"
grep -q 'logcat --uid=10123' "$test_root/adb.log"
grep -q -- '--expected-helium-sync-commit 1111111111111111111111111111111111111111' \
  "$test_root/node.log"
! grep -q 'localabstract:chrome_devtools_remote' "$test_root/adb.log"
grep -q 'forward --remove tcp:9222' "$test_root/adb.log"
grep -q 'reverse --remove tcp:44721' "$test_root/adb.log"

export HELIUM_TEST_PROBE_FAIL=true
if PATH="$test_root/bin:$PATH" \
  "$repo_root/scripts/android-media/run-device-probe.sh" \
  "$acceptance" USB-SERIAL "$test_root/failed-evidence" \
  >"$test_root/failed-probe.out" 2>&1; then
  echo 'synthetic failed probe unexpectedly passed' >&2
  exit 1
fi
unset HELIUM_TEST_PROBE_FAIL
grep -qx 'status=failed' "$test_root/failed-evidence/failure.env"
grep -qx 'exit_code=7' "$test_root/failed-evidence/failure.env"
grep -q 'synthetic probe failure' "$test_root/failed-evidence/probe-runner.log"
grep -q 'synthetic package-only logcat' \
  "$test_root/failed-evidence/package-logcat.txt"
jq -e '.method_counts["Media.playerErrorsRaised"] == 1' \
  "$test_root/failed-evidence/media-diagnostics.json" >/dev/null
(
  cd "$test_root/failed-evidence"
  sha256sum -c EVIDENCE_SHA256SUMS
)

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
grep -q 'requires a non-network, non-emulator ADB serial' "$test_root/network-adb.out"

printf 'different installed APK\n' > "$test_root/different.apk"
export HELIUM_TEST_INSTALLED_APK="$test_root/different.apk"
if PATH="$test_root/bin:$PATH" \
  "$repo_root/scripts/android-media/run-device-probe.sh" \
  "$acceptance" USB-SERIAL "$test_root/wrong-apk-evidence" \
  > "$test_root/wrong-apk.out" 2>&1; then
  echo 'different installed APK unexpectedly passed admission' >&2
  exit 1
fi
grep -q 'installed disposable base APK does not match' "$test_root/wrong-apk.out"

echo 'Android device probe orchestration contract passed'
