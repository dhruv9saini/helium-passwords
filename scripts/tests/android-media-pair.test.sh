#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-media-pair-test.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

chromium_commit=2222222222222222222222222222222222222222
sync_commit=1111111111111111111111111111111111111111
fixture_spki=$(printf 'A%.0s' {1..43})=
fixture_cert=$(printf 'f%.0s' {1..64})
adb_usb_path_sha256=$(printf '8%.0s' {1..64})
build_fingerprint_sha256=$(printf '9%.0s' {1..64})
physical_identity_sha256=$(
  printf '%s\n' helium-physical-oneplus-v1 ONEPLUS-USB CPH2655 dodge \
    dodge OnePlus "$build_fingerprint_sha256" | sha256sum | cut -d' ' -f1
)
fixture=$(jq -cn \
  --arg spki "$fixture_spki" --arg cert "$fixture_cert" \
  '{schema_version:1,disposable_only:true,tls_mode:"private-ca-spki",
    hostname:"lm.tail0168aa.ts.net",h2_port:44723,h3_port:44724,
    leaf_spki_sha256_base64:$spki,leaf_cert_sha256:$cert,
    required_chromium_switch:("--ignore-certificate-errors-spki-list=" + $spki)}')

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
  mkdir -p "$acceptance/runtime-acceptance" \
    "$acceptance/build-provenance" "$evidence"
  cp "$repo_root/helium-chromium/flags.gn" \
    "$acceptance/build-provenance/flags.gn"
  sed 's/=/ = /' "$repo_root/helium-chromium/flags.gn" | sort \
    > "$acceptance/build-provenance/locked-gn-args-resolved.txt"
  for name in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh; do
    cp "$repo_root/scripts/android-media/$name" "$acceptance/runtime-acceptance/$name"
  done
  printf 'package=%s\n' "$package" > "$acceptance/runtime-acceptance/kit.env"
  (
    cd "$acceptance/runtime-acceptance"
    sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
      disposable-browser.sh prepare-cookie-acceptance-profile.sh \
      run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh \
      kit.env > SHA256SUMS
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
schema_version=2
package=$package
identity_schema=helium-physical-oneplus-v1
adb_serial=ONEPLUS-USB
adb_transport=physical-usb
adb_transport_id=1
adb_usb_path_sha256=$adb_usb_path_sha256
android_model=CPH2655
android_device=dodge
android_product=dodge
android_manufacturer=OnePlus
build_fingerprint_sha256=$build_fingerprint_sha256
physical_identity_sha256=$physical_identity_sha256
physical_identity_captured_at=2026-07-22T00:00:00Z
background_foreground=true
network_handoff=wifi-to-cellular
version_code=787500005
version_name=150.0.7871.181
installed_apk_sha256=$apk_sha
package_uid=10123
logcat_scope=package-uid
cookie_acceptance=$([[ "$role" == sync ]] && echo true || echo false)
device_socket=$socket
fixture_spki_sha256_base64=$fixture_spki
fixture_cert_sha256=$fixture_cert
fixture_receipt_sha256=$fixture_sha
started_at=2026-07-22T00:01:00Z
completed_at=2026-07-22T00:02:00Z
EOF
  jq -n \
    --arg package "$package" --arg apk "$apk_sha" --arg chromium "$chromium_commit" \
    --arg sync "$sync_commit" --arg socket "$socket" --arg spki "$fixture_spki" '
      def stream: {
        text:"chunk-01\nchunk-02\nchunk-03\nchunk-04\n",
        arrivals:[10,110,210,310],interaction_ticks:3,
        chunk_milestones:[
          {count:1,at_ms:10},{count:2,at_ms:110},
          {count:3,at_ms:210},{count:4,at_ms:310}],
        headers_ms:1,completed_ms:350};
      def played($name): {name:$name,ok:true,duration:2,width:320,height:180,
        audio_decoded_bytes:10,total_frames:60,dropped_frames:0};
      {
        schema_version:1,expected_chunks:4,expected_delay_ms:100,
        finished_at:"2026-07-22T00:02:00Z",
        fetch_identity:stream,fetch_gzip:stream,fetch_br:stream,
        fetch_h2:(stream + {protocol:"h2"}),
        fetch_h3:(stream + {protocol:"h3"}),
        transport_warmup_h3:{status:200,completed_ms:100,protocol:"h2"},
        required_transport_protocols:["h2","h3"],
        required_lifecycle:{background_foreground:true,network_handoff:true},
        service_worker:{supported:true,controlled:true,script_url:"/service-worker.js",
          stream:stream},
        sse:{values:["chunk-01","chunk-02","chunk-03","chunk-04"],
          arrivals:[10,110,210,310],interaction_ticks:3},
        capabilities:{mp4_h264_aac:"probably",mp4_h264_high_aac:"",
          webm_vp9_opus:"probably",webm_av1_opus:"",hls:"probably",
          mse_mp4_h264_aac:true},
        media_capabilities:{mp4_file:{supported:true},mp4_high_file:{supported:false},
          webm_file:{supported:true},av1_file:{supported:false},
          mp4_mse:{supported:true}},
        runtime:{browser_product:"Chrome/150",browser_protocol_version:"1.3",
          browser_webkit_version:"537.36 (@synthetic)",
          fixture_origin:"http://127.0.0.1:44721",android_package:$package,
          artifact_sha256:$apk,chromium_commit:$chromium,
          helium_sync_commit:$sync,device_socket:$socket,
          fixture_spki_sha256_base64:$spki},
        drm:{widevine:{api_available:true,key_system_available:false,
          key_system:"com.widevine.alpha"}},
        media_manifest:{schema_version:1,files:{
          mp4:{name:"h264-aac.mp4",bytes:10,sha256:("a"*64)},
          mp4_high:{name:"h264-high-aac.mp4",bytes:10,sha256:("b"*64)},
          webm:{name:"vp9-opus.webm",bytes:10,sha256:("c"*64)},
          av1:{name:"av1-opus.webm",bytes:10,sha256:("d"*64)},
          mse:{name:"h264-aac-fragmented.mp4",bytes:10,sha256:("e"*64)},
          hls_manifest:{name:"hls/stream.m3u8",bytes:10,sha256:("f"*64)},
          hls_init:{name:"hls/init.mp4",bytes:10,sha256:("0"*64)},
          hls_segment_0:{name:"hls/segment-000.m4s",bytes:10,sha256:("1"*64)},
          hls_segment_1:{name:"hls/segment-001.m4s",bytes:10,sha256:("2"*64)},
          dash_manifest:{name:"dash/stream.mpd",bytes:10,sha256:("3"*64)},
          dash_media:{name:"dash/h264-aac-fragmented.mp4",bytes:10,
            sha256:("4"*64)}}},
        playback:[played("mp4"),
          {name:"mp4_high",ok:false,error:"synthetic unsupported"},
          played("webm"),{name:"av1",ok:false,error:"synthetic unsupported"},
          played("mse"),played("hls"),played("dash")],
        lifecycle:{events:[
          {event:"started",at_ms:1,visibility:"visible",online:true},
          {event:"visibilitychange",at_ms:100,visibility:"hidden",online:true},
          {event:"connectionchange",at_ms:200,visibility:"hidden",online:true},
          {event:"visibilitychange",at_ms:300,visibility:"visible",online:true},
          {event:"completed",at_ms:1000,visibility:"visible",online:true}]},
        media_diagnostics:{source:"CDP Media domain",enabled:true,event_count:1,
          player_count:1,method_counts:{"Media.playerEventsAdded":1}}
      }
    ' > "$evidence/result.json"
  jq -n '{
    schema_version:1,synthetic_fixture_only:true,source:"CDP Media domain",
    enabled:true,event_count:1,player_count:1,
    method_counts:{"Media.playerEventsAdded":1},
    events:[{method:"Media.playerEventsAdded",params:{playerId:"synthetic"}}]
  }' > "$evidence/media-diagnostics.json"
  printf 'synthetic package-scoped logcat\n' > "$evidence/package-logcat.txt"
  printf 'synthetic probe runner log\n' > "$evidence/probe-runner.log"
  printf 'synthetic fixture server log\n' > "$evidence/fixture-server.log"
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
grep -Eq '^shared_flags_gn_sha256=[0-9a-f]{64}$' "$test_root/pair.env"
grep -Eq '^shared_locked_gn_args_sha256=[0-9a-f]{64}$' "$test_root/pair.env"
grep -Eq '^media_manifest_sha256=[0-9a-f]{64}$' "$test_root/pair.env"

printf 'enable_mdns=true\n' \
  >> "$test_root/control-acceptance/build-provenance/flags.gn"
(
  cd "$test_root/control-acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)
if "$repo_root/scripts/android-media/verify-probe-pair.sh" \
  "$test_root/sync-acceptance" "$test_root/sync-evidence" \
  "$test_root/control-acceptance" "$test_root/control-evidence" \
  "$test_root/different-flags.env" > "$test_root/different-flags.out" 2>&1; then
  echo 'different-flags Sync/control evidence unexpectedly passed' >&2
  exit 1
fi
grep -q 'not built from byte-identical flags.gn' "$test_root/different-flags.out"
cp "$test_root/sync-acceptance/build-provenance/flags.gn" \
  "$test_root/control-acceptance/build-provenance/flags.gn"
(
  cd "$test_root/control-acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)

printf 'enable_mdns = true\n' \
  >> "$test_root/control-acceptance/build-provenance/locked-gn-args-resolved.txt"
(
  cd "$test_root/control-acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)
if "$repo_root/scripts/android-media/verify-probe-pair.sh" \
  "$test_root/sync-acceptance" "$test_root/sync-evidence" \
  "$test_root/control-acceptance" "$test_root/control-evidence" \
  "$test_root/different-effective-locked.env" \
  > "$test_root/different-effective-locked.out" 2>&1; then
  echo 'different effective locked GN values unexpectedly passed' >&2
  exit 1
fi
grep -q 'do not have byte-identical effective locked GN values' \
  "$test_root/different-effective-locked.out"
cp "$test_root/sync-acceptance/build-provenance/locked-gn-args-resolved.txt" \
  "$test_root/control-acceptance/build-provenance/locked-gn-args-resolved.txt"
(
  cd "$test_root/control-acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -print0 \
    | sort -z | xargs -0 sha256sum > PACKAGE_SHA256SUMS
)

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
