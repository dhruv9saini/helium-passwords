#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-media-pair-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

chromium_commit=2222222222222222222222222222222222222222
sync_commit=1111111111111111111111111111111111111111
fixture='{"schema_version":1,"disposable_only":true,"hostname":"lm.tail0168aa.ts.net"}'

make_generation() {
  local role=$1
  local package socket archive_sha apk_sha
  case "$role" in
    sync)
      package=computer.helium.sync.test
      socket=helium_sync_test_devtools_remote
      archive_sha=$(printf 'a%.0s' {1..64})
      apk_sha=$(printf 'b%.0s' {1..64})
      ;;
    control)
      package=computer.helium.control.test
      socket=helium_control_test_devtools_remote
      archive_sha=$(printf 'c%.0s' {1..64})
      apk_sha=$(printf 'd%.0s' {1..64})
      ;;
    *) exit 64 ;;
  esac
  local acceptance="$test_root/$role-acceptance"
  local evidence="$test_root/$role-evidence"
  mkdir -p "$acceptance/runtime-acceptance" "$evidence"
  for name in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh verify-probe-pair.sh; do
    cp "$repo_root/scripts/android-media/$name" "$acceptance/runtime-acceptance/$name"
  done
  printf 'package=%s\n' "$package" > "$acceptance/runtime-acceptance/kit.env"
  (
    cd "$acceptance/runtime-acceptance"
    sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
      disposable-browser.sh prepare-cookie-acceptance-profile.sh \
      run-device-probe.sh verify-probe-pair.sh kit.env > SHA256SUMS
  )
  local runtime_sha
  runtime_sha=$(sha256sum "$acceptance/runtime-acceptance/SHA256SUMS" | cut -d' ' -f1)
  printf 'synthetic %s APK\n' "$role" > "$acceptance/Browser-test.apk"
  cat > "$acceptance/acceptance.env" <<EOF
schema_version=2
package=$package
helium_sync_commit=$sync_commit
chromium_commit=$chromium_commit
version_code=787500005
version_name=150.0.7871.181
source_archive_sha256=$archive_sha
apk_sha256=$apk_sha
runtime_kit_sha256=$runtime_sha
prepared_at=2026-07-22T00:00:00+00:00
EOF
  (
    cd "$acceptance"
    find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
      | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
  )
  cp "$acceptance/acceptance.env" "$evidence/acceptance.env"
  printf '%s\n' "$fixture" > "$evidence/fixture-provenance.json"
  local fixture_sha
  fixture_sha=$(sha256sum "$evidence/fixture-provenance.json" | cut -d' ' -f1)
  cat > "$evidence/actions.env" <<EOF
schema_version=1
package=$package
background_foreground=true
network_handoff=wifi-to-cellular
version_code=787500005
version_name=150.0.7871.181
installed_apk_sha256=$apk_sha
package_uid=10123
logcat_scope=package-uid
cookie_acceptance=$([[ "$role" == sync ]] && echo true || echo false)
device_socket=$socket
fixture_receipt_sha256=$fixture_sha
EOF
  jq -n \
    --arg package "$package" --arg apk "$apk_sha" --arg chromium "$chromium_commit" \
    --arg sync "$sync_commit" --arg socket "$socket" '
      {
        runtime:{android_package:$package,artifact_sha256:$apk,chromium_commit:$chromium,
          helium_sync_commit:$sync,device_socket:$socket},
        required_transport_protocols:["h2","h3"],
        required_lifecycle:{background_foreground:true,network_handoff:true},
        service_worker:{supported:true,controlled:true,script_url:"/service-worker.js"},
        media_diagnostics:{source:"CDP Media domain",enabled:true,event_count:1,
          player_count:1,method_counts:{"Media.playerEventsAdded":1}},
        drm:{widevine:{api_available:true,key_system_available:false,
          key_system:"com.widevine.alpha"}},
        media_manifest:{schema_version:1,files:{mp4:{name:"h264-aac.mp4",bytes:10,
          sha256:("e" * 64)}}}
      }
    ' > "$evidence/result.json"
  jq -n '{
    schema_version:1,synthetic_fixture_only:true,source:"CDP Media domain",
    enabled:true,event_count:1,player_count:1,
    method_counts:{"Media.playerEventsAdded":1},
    events:[{method:"Media.playerEventsAdded",params:{playerId:"synthetic"}}]
  }' > "$evidence/media-diagnostics.json"
  printf 'synthetic package-scoped logcat\n' > "$evidence/package-logcat.txt"
  if [[ "$role" == sync ]]; then
    jq -n '{
      schema_version:1,fixture:"helium-cookie-manager-disposable-v1",
      synthetic_only:true,status:"passed",reason:"",
      cookie_api:"network::mojom::CookieManager",
      destination_snapshot:{complete_profile_cookie_count:1,
        snapshot_persisted_before_apply:true,fingerprint:("a" * 64)},
      import:{record_count:3,apply_result:"accepted",readback_result:"exact",
        fingerprint:("b" * 64),canonical_record_keys_unique:true,
        partitioned_and_unpartitioned_identity_distinct:true,
        attribute_coverage:{session:true,persistent:true,http_only:true,
          secure:true,same_site:true,host_only:true,domain:true,partitioned:true}},
      destination_rejection:{set_result:"rejected",rollback_result:"exact",
        destination_fingerprint:("a" * 64)},
      origin_state:{cookie_names_guessed:false,cookie_manager_supported:true,
        registered_adapter_count:0,non_cookie_transfer_result:"not-tested"},
      cleanup:{complete_profile_cookie_store:"empty"}
    }' > "$evidence/cookie-native-acceptance.json"
  fi
  (
    cd "$evidence"
    find . -maxdepth 1 -type f ! -name EVIDENCE_SHA256SUMS -printf '%f\0' |
      sort -z | xargs -0 sha256sum > EVIDENCE_SHA256SUMS
  )
}

make_generation sync
make_generation control

"$repo_root/scripts/android-media/verify-probe-pair.sh" \
  "$test_root/sync-acceptance" "$test_root/sync-evidence" \
  "$test_root/control-acceptance" "$test_root/control-evidence" \
  "$test_root/pair.env" > "$test_root/pass.out"
grep -qx "pair_receipt=$test_root/pair.env" "$test_root/pass.out"
grep -Eq '^pair_receipt_sha256=[0-9a-f]{64}$' "$test_root/pass.out"
grep -qx "helium_sync_commit=$sync_commit" "$test_root/pair.env"
grep -qx "chromium_commit=$chromium_commit" "$test_root/pair.env"
grep -Eq '^media_manifest_sha256=[0-9a-f]{64}$' "$test_root/pair.env"

sed -i 's/1111111111111111111111111111111111111111/3333333333333333333333333333333333333333/' \
  "$test_root/control-acceptance/acceptance.env" "$test_root/control-evidence/acceptance.env" \
  "$test_root/control-evidence/result.json"
(
  cd "$test_root/control-acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)
(
  cd "$test_root/control-evidence"
  find . -maxdepth 1 -type f ! -name EVIDENCE_SHA256SUMS -printf '%f\0' |
    sort -z | xargs -0 sha256sum > EVIDENCE_SHA256SUMS
)
if "$repo_root/scripts/android-media/verify-probe-pair.sh" \
  "$test_root/sync-acceptance" "$test_root/sync-evidence" \
  "$test_root/control-acceptance" "$test_root/control-evidence" \
  "$test_root/different-source.env" > "$test_root/fail.out" 2>&1; then
  echo 'different-source Sync/control evidence unexpectedly passed' >&2
  exit 1
fi
grep -q 'do not share helium_sync_commit' "$test_root/fail.out"

echo 'Android media A/B pair gate passed'
