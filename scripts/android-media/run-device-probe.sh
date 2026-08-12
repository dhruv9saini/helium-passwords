#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-device-probe.sh ACCEPTANCE_DIRECTORY ADB_SERIAL NEW_EVIDENCE_DIRECTORY [OPTIONS]

The admitted .test APK must already be installed and running with exactly one
--enable-automation switch and its package-specific DevTools socket:
  computer.helium.passwords.test     helium_sync_test_devtools_remote
  computer.helium.control.test  helium_control_test_devtools_remote
The runner verifies the installed base.apk hash, CDP Android-Package and source
revision, and the effective --remote-debugging-socket-name before probing.

Options:
  --h2 URL                         Require the exact HTTPS HTTP/2 fixture endpoint.
  --h3 URL                         Require the exact HTTPS HTTP/3 fixture endpoint.
  --fixture-receipt FILE           Require the private fixture's exact leaf-SPKI
                                   receipt and effective disposable browser switch.
  --background-foreground true    Exercise and require one background/resume cycle.
  --network-handoff none          Do not change device networking (default).
  --network-handoff wifi-to-cellular
                                   Disable Wi-Fi during the probe, require a browser
                                   connection-change event, and restore Wi-Fi on exit.
EOF
}

[[ $# -ge 3 ]] || { usage; exit 64; }
acceptance=$(realpath "$1")
serial=$2
evidence=$(realpath -m "$3")
shift 3

h2=
h3=
fixture_receipt=
background_foreground=false
network_handoff=none
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage; exit 64; }
  case "$1" in
    --h2) h2=$2 ;;
    --h3) h3=$2 ;;
    --fixture-receipt) fixture_receipt=$2 ;;
    --background-foreground) background_foreground=$2 ;;
    --network-handoff) network_handoff=$2 ;;
    *) echo "unknown device probe option: $1" >&2; exit 64 ;;
  esac
  shift 2
done

case "$background_foreground" in true|false) ;; *) echo 'background/foreground must be true or false' >&2; exit 64 ;; esac
case "$network_handoff" in none|wifi-to-cellular) ;; *) echo 'unsupported network handoff' >&2; exit 64 ;; esac
[[ -d "$acceptance" && -f "$acceptance/PACKAGE_SHA256SUMS" ]] || {
  echo "acceptance directory is incomplete" >&2
  exit 1
}
[[ ! -e "$evidence" ]] || { echo "evidence directory already exists" >&2; exit 1; }
command -v adb >/dev/null
command -v jq >/dev/null
command -v node >/dev/null
command -v sha256sum >/dev/null

metadata() {
  local name=$1
  local file=$2
  local value
  value=$(sed -n "s/^${name}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${name}=" "$file")" -eq 1 ]] || {
    echo "acceptance metadata is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS)
package=$(metadata package "$acceptance/acceptance.env")
case "$package" in
  computer.helium.passwords.test|computer.helium.control.test) ;;
  *) echo "device probe requires a disposable package" >&2; exit 1 ;;
esac
artifact_sha256=$(metadata source_archive_sha256 "$acceptance/acceptance.env")
apk_sha256=$(metadata apk_sha256 "$acceptance/acceptance.env")
chromium_commit=$(metadata chromium_commit "$acceptance/acceptance.env")
helium_sync_commit=$(metadata helium_sync_commit "$acceptance/acceptance.env")
version_code=$(metadata version_code "$acceptance/acceptance.env")
version_name=$(metadata version_name "$acceptance/acceptance.env")
[[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ && "$apk_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$chromium_commit" =~ ^[0-9a-f]{40}$ && "$helium_sync_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$version_code" =~ ^[1-9][0-9]*$ && "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ -f "$acceptance/Browser-test.apk" && ! -L "$acceptance/Browser-test.apk" ]] || {
  echo "prepared disposable APK is missing or unsafe" >&2
  exit 1
}
[[ "$(sha256sum "$acceptance/Browser-test.apk" | cut -d' ' -f1)" == "$apk_sha256" ]] || {
  echo "prepared disposable APK hash does not match acceptance metadata" >&2
  exit 1
}

case "$package" in
  computer.helium.passwords.test)
    device_socket=helium_sync_test_devtools_remote
    cookie_acceptance=true
    ;;
  computer.helium.control.test)
    device_socket=helium_control_test_devtools_remote
    cookie_acceptance=false
    ;;
esac

fixture_spki=
fixture_cert_sha256=
if [[ -n "$h2" || -n "$h3" ]]; then
  [[ -n "$fixture_receipt" ]] || {
    echo "private protocol fixtures require --fixture-receipt" >&2
    exit 1
  }
  [[ -f "$fixture_receipt" && ! -L "$fixture_receipt" ]] || {
    echo "fixture receipt must be a regular non-symlink file" >&2
    exit 1
  }
  fixture_receipt=$(realpath "$fixture_receipt")
  [[ -f "$fixture_receipt" && ! -L "$fixture_receipt" ]] || {
    echo "fixture receipt must be a regular non-symlink file" >&2
    exit 1
  }
  fixture_spki=$(jq -er '.leaf_spki_sha256_base64' "$fixture_receipt")
  fixture_cert_sha256=$(jq -er '.leaf_cert_sha256' "$fixture_receipt")
  fixture_receipt_sha256=$(sha256sum "$fixture_receipt" | cut -d' ' -f1)
  fixture_host=$(jq -er '.hostname' "$fixture_receipt")
  fixture_h2_port=$(jq -er '.h2_port' "$fixture_receipt")
  fixture_h3_port=$(jq -er '.h3_port' "$fixture_receipt")
  jq -e --arg spki "$fixture_spki" '
    .schema_version == 1 and .disposable_only == true and
    .tls_mode == "private-ca-spki" and
    .required_chromium_switch == ("--ignore-certificate-errors-spki-list=" + $spki)
  ' "$fixture_receipt" >/dev/null
  [[ "$fixture_host" == lm.tail0168aa.ts.net && "$fixture_h2_port" == 44723 &&
      "$fixture_h3_port" == 44724 && "$fixture_spki" =~ ^[A-Za-z0-9+/]{43}=$ &&
      "$fixture_cert_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "fixture receipt identity, ports, or fingerprints are invalid" >&2
    exit 1
  }
  [[ -z "$h2" || "$h2" == "https://$fixture_host:$fixture_h2_port/stream/fetch?encoding=identity" ]]
  [[ -z "$h3" || "$h3" == "https://$fixture_host:$fixture_h3_port/stream/fetch?encoding=identity" ]]
elif [[ -n "$fixture_receipt" ]]; then
  echo "fixture receipt is allowed only with a private protocol fixture URL" >&2
  exit 1
fi

[[ "$serial" =~ ^[A-Za-z0-9._-]+$ && "$serial" != emulator-* ]] || {
  echo "device probe requires a non-network, non-emulator ADB serial" >&2
  exit 1
}
[[ "$(adb -s "$serial" get-state)" == device ]]
device_line=$(adb devices -l | awk -v serial="$serial" \
  '$1 == serial && $2 == "device" {print; count++} END {if (count != 1) exit 1}') || {
  echo "device probe requires one unambiguous physical ADB transport" >&2
  exit 1
}
[[ " $device_line " == *" usb:"* ]] || {
  echo "device probe requires a physical USB ADB transport" >&2
  exit 1
}
adb_field() {
  local name=$1 value
  value=$(sed -n "s/.*[[:space:]]${name}:\\([^[:space:]]*\\).*/\\1/p" <<<"$device_line")
  [[ -n "$value" && "$value" != *$'\n'* ]] || {
    echo "ADB inventory is missing $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}
android_model=$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')
android_device=$(adb -s "$serial" shell getprop ro.product.device | tr -d '\r')
android_product=$(adb -s "$serial" shell getprop ro.product.name | tr -d '\r')
android_manufacturer=$(adb -s "$serial" shell getprop ro.product.manufacturer | tr -d '\r')
android_fingerprint=$(adb -s "$serial" shell getprop ro.build.fingerprint | tr -d '\r')
adb_transport_id=$(adb_field transport_id)
adb_usb_path=$(adb_field usb)
[[ "$(adb_field model)" == "$android_model" &&
    "$(adb_field device)" == "$android_device" &&
    "$(adb_field product)" == "$android_product" &&
    "$android_model" == CPH2655 && "$android_device" == dodge &&
    "$android_manufacturer" == OnePlus &&
    "$android_product" =~ ^[A-Za-z0-9._-]+$ &&
    "$adb_transport_id" =~ ^[1-9][0-9]*$ &&
    -n "$android_fingerprint" && "$android_fingerprint" != *$'\n'* ]] || {
  echo "ADB transport is not the admitted physical OnePlus" >&2
  exit 1
}
adb_usb_path_sha256=$(printf '%s\n' "$adb_usb_path" | sha256sum | cut -d' ' -f1)
build_fingerprint_sha256=$(printf '%s\n' "$android_fingerprint" | sha256sum | cut -d' ' -f1)
physical_identity_sha256=$(
  printf 'helium-physical-oneplus-v1\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$serial" "$android_model" "$android_device" "$android_product" \
    "$android_manufacturer" "$build_fingerprint_sha256" |
    sha256sum | cut -d' ' -f1
)
physical_identity_captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mapfile -t package_paths < <(adb -s "$serial" shell pm path "$package" | tr -d '\r')
[[ ${#package_paths[@]} -eq 1 && "${package_paths[0]}" == package:/data/app/*/base.apk ]] || {
  echo "disposable browser must be one installed monolithic base APK" >&2
  exit 1
}
installed_apk=${package_paths[0]#package:}
[[ "$installed_apk" != *[[:space:]]* && "$installed_apk" != *"'"* && \
    "$installed_apk" != *'"'* ]] || {
  echo "installed disposable APK path is unsafe" >&2
  exit 1
}
installed_apk_sha256=$(adb -s "$serial" exec-out cat "$installed_apk" | sha256sum | cut -d' ' -f1)
[[ "$installed_apk_sha256" == "$apk_sha256" ]] || {
  echo "installed disposable base APK does not match the admitted artifact" >&2
  exit 1
}
package_dump=$(adb -s "$serial" shell dumpsys package "$package" | tr -d '\r')
installed_version_code=$(sed -n 's/^[[:space:]]*versionCode=\([^ ]*\).*/\1/p' <<<"$package_dump" | head -n 1)
installed_version_name=$(sed -n 's/^[[:space:]]*versionName=//p' <<<"$package_dump" | head -n 1)
package_uid=$(sed -n 's/^[[:space:]]*userId=//p' <<<"$package_dump" | head -n 1)
[[ "$installed_version_code" == "$version_code" ]] || {
  echo "installed package versionCode does not match the admitted artifact" >&2
  exit 1
}
[[ "$installed_version_name" == "$version_name" ]] || {
  echo "installed package versionName does not match the admitted artifact" >&2
  exit 1
}
[[ "$package_uid" =~ ^[1-9][0-9]*$ ]] || {
  echo "installed disposable package UID is unavailable" >&2
  exit 1
}
browser_pid=$(adb -s "$serial" shell pidof "$package" | tr -d '\r')
[[ "$browser_pid" =~ ^[1-9][0-9]*$ ]] || {
  echo "exact disposable browser package is not running as one main process" >&2
  exit 1
}
socket_count=$(adb -s "$serial" shell cat /proc/net/unix | tr -d '\r' | \
  grep -Ec "[[:space:]]@${device_socket}$" || true)
[[ "$socket_count" -eq 1 ]] || {
  echo "exact disposable browser DevTools socket is not uniquely available" >&2
  exit 1
}

evidence_parent=$(dirname "$evidence")
mkdir -p "$evidence_parent"
temporary=$(mktemp -d "$evidence_parent/.helium-device-probe.XXXXXX")
staged="$temporary/staged"
mkdir -p "$staged"
fixture_log="$staged/fixture-server.log"
result="$staged/result.json"
media_diagnostics="$staged/media-diagnostics.json"
package_logcat="$staged/package-logcat.txt"
probe_log="$staged/probe-runner.log"
ready="$temporary/ready.json"
action_log="$staged/actions.env"
fixture_pid=
probe_pid=
logcat_pid=
reverse_created=false
forward_created=false
wifi_changed=false

cleanup() {
  local status=$?
  if [[ "$wifi_changed" == true ]]; then
    adb -s "$serial" shell svc wifi enable >/dev/null 2>&1 || true
  fi
  if [[ "$probe_pid" ]]; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  if [[ "$logcat_pid" ]]; then
    kill "$logcat_pid" 2>/dev/null || true
    wait "$logcat_pid" 2>/dev/null || true
  fi
  if [[ "$forward_created" == true ]]; then
    adb -s "$serial" forward --remove tcp:9222 >/dev/null 2>&1 || true
  fi
  if [[ "$reverse_created" == true ]]; then
    adb -s "$serial" reverse --remove tcp:44721 >/dev/null 2>&1 || true
  fi
  if [[ "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 && -d "$staged" && ! -e "$evidence" ]]; then
    printf 'schema_version=1\nstatus=failed\nexit_code=%s\nfailed_at=%s\n' \
      "$status" "$(date --iso-8601=seconds)" > "$staged/failure.env"
    [[ -f "$staged/acceptance.env" ]] ||
      cp "$acceptance/acceptance.env" "$staged/acceptance.env"
    if [[ -n "$fixture_receipt" &&
          ! -f "$staged/fixture-provenance.json" ]]; then
      cp "$fixture_receipt" "$staged/fixture-provenance.json"
    fi
    (
      cd "$staged"
      find . -maxdepth 1 -type f ! -name EVIDENCE_SHA256SUMS -printf '%f\0' |
        sort -z | xargs -0 sha256sum > EVIDENCE_SHA256SUMS
    )
    mv "$staged" "$evidence"
    printf 'failed_evidence_directory=%s\n' "$evidence" >&2
  fi
  if [[ -d "$temporary" ]]; then
    find "$temporary" -depth -delete
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

node "$acceptance/runtime-acceptance/fixture-server.mjs" \
  --host 127.0.0.1 --port 44721 --media-dir "$acceptance/media" \
  > "$fixture_log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 100); do
  grep -q '"event":"listening"' "$fixture_log" && break
  kill -0 "$fixture_pid" 2>/dev/null || { cat "$fixture_log" >&2; exit 1; }
  sleep 0.1
done
grep -q '"event":"listening"' "$fixture_log" || { echo "fixture server did not become ready" >&2; exit 1; }

adb -s "$serial" reverse --no-rebind tcp:44721 tcp:44721 >/dev/null
reverse_created=true
adb -s "$serial" forward --no-rebind tcp:9222 "localabstract:$device_socket" >/dev/null
forward_created=true

adb -s "$serial" logcat --uid="$package_uid" -v threadtime '*:V' \
  > "$package_logcat" 2>&1 &
logcat_pid=$!
sleep 0.2
kill -0 "$logcat_pid" 2>/dev/null || {
  wait "$logcat_pid" || true
  echo "package-scoped Android logcat capture could not start" >&2
  exit 1
}

probe_args=(
  --cdp http://127.0.0.1:9222
  --fixture http://127.0.0.1:44721/probe
  --output "$result"
  --media-diagnostics "$media_diagnostics"
  --ready-file "$ready"
  --require-lifecycle "$background_foreground"
  --require-network-handoff "$([[ "$network_handoff" == none ]] && echo false || echo true)"
  --expected-package "$package"
  --expected-artifact-sha256 "$apk_sha256"
  --expected-chromium-commit "$chromium_commit"
  --expected-helium-sync-commit "$helium_sync_commit"
  --expected-device-socket "$device_socket"
)
[[ -z "$h2" ]] || probe_args+=(--h2 "$h2")
[[ -z "$h3" ]] || probe_args+=(--h3 "$h3")
[[ -z "$fixture_spki" ]] || probe_args+=(--fixture-spki "$fixture_spki")
node "$acceptance/runtime-acceptance/run-cdp-probe.mjs" "${probe_args[@]}" \
  > "$probe_log" 2>&1 &
probe_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$ready" ]] && break
  kill -0 "$probe_pid" 2>/dev/null || { wait "$probe_pid"; exit 1; }
  sleep 0.1
done
[[ -f "$ready" ]] || { echo "browser probe did not become ready" >&2; exit 1; }

{
  printf 'schema_version=2\n'
  printf 'package=%s\n' "$package"
  printf 'identity_schema=helium-physical-oneplus-v1\n'
  printf 'adb_serial=%s\nadb_transport=physical-usb\n' "$serial"
  printf 'adb_transport_id=%s\nadb_usb_path_sha256=%s\n' \
    "$adb_transport_id" "$adb_usb_path_sha256"
  printf 'android_model=%s\nandroid_device=%s\nandroid_product=%s\n' \
    "$android_model" "$android_device" "$android_product"
  printf 'android_manufacturer=%s\nbuild_fingerprint_sha256=%s\n' \
    "$android_manufacturer" "$build_fingerprint_sha256"
  printf 'physical_identity_sha256=%s\nphysical_identity_captured_at=%s\n' \
    "$physical_identity_sha256" "$physical_identity_captured_at"
  printf 'background_foreground=%s\n' "$background_foreground"
  printf 'network_handoff=%s\n' "$network_handoff"
  printf 'version_code=%s\n' "$installed_version_code"
  printf 'version_name=%s\n' "$installed_version_name"
  printf 'installed_apk_sha256=%s\n' "$installed_apk_sha256"
  printf 'package_uid=%s\n' "$package_uid"
  printf 'logcat_scope=package-uid\n'
  printf 'cookie_acceptance=%s\n' "$cookie_acceptance"
  printf 'device_socket=%s\n' "$device_socket"
  if [[ -n "$fixture_spki" ]]; then
    printf 'fixture_spki_sha256_base64=%s\n' "$fixture_spki"
    printf 'fixture_cert_sha256=%s\n' "$fixture_cert_sha256"
    printf 'fixture_receipt_sha256=%s\n' "$fixture_receipt_sha256"
  fi
  printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
} > "$action_log"

if [[ "$background_foreground" == true ]]; then
  adb -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null
  sleep 1
  adb -s "$serial" shell monkey -p "$package" \
    -c android.intent.category.LAUNCHER 1 >/dev/null
  sleep 1
fi

if [[ "$network_handoff" == wifi-to-cellular ]]; then
  wifi_on=$(adb -s "$serial" shell settings get global wifi_on | tr -d '\r')
  mobile_data=$(adb -s "$serial" shell settings get global mobile_data | tr -d '\r')
  [[ "$wifi_on" == 1 ]] || { echo "wifi-to-cellular requires Wi-Fi to start enabled" >&2; exit 1; }
  [[ "$mobile_data" == 1 ]] || { echo "wifi-to-cellular requires mobile data to start enabled" >&2; exit 1; }
  adb -s "$serial" shell svc wifi disable >/dev/null
  wifi_changed=true
  sleep 3
fi

wait "$probe_pid"
probe_pid=
[[ -f "$result" && -f "$media_diagnostics" ]]
kill "$logcat_pid" 2>/dev/null || true
wait "$logcat_pid" 2>/dev/null || true
logcat_pid=
[[ -f "$package_logcat" ]]
if [[ "$wifi_changed" == true ]]; then
  adb -s "$serial" shell svc wifi enable >/dev/null
  wifi_changed=false
fi

if [[ "$cookie_acceptance" == true ]]; then
  cookie_remote=app_chrome/Default/helium-sync/cookie-native-acceptance.json
  cookie_temporary="$temporary/cookie-native-acceptance.json"
  for _ in $(seq 1 300); do
    if adb -s "$serial" exec-out run-as "$package" cat "$cookie_remote" \
        > "$cookie_temporary" 2>/dev/null &&
       jq -e '.status == "passed"' "$cookie_temporary" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  jq -e '
    (keys | sort) == ([
      "cleanup", "cookie_api", "destination_rejection",
      "destination_snapshot", "fixture", "import", "origin_state", "reason",
      "schema_version", "status", "synthetic_only"
    ] | sort) and
    .schema_version == 1 and
    .fixture == "helium-cookie-manager-disposable-v1" and
    .synthetic_only == true and .status == "passed" and .reason == "" and
    .cookie_api == "network::mojom::CookieManager" and
    .destination_snapshot.complete_profile_cookie_count == 1 and
    .destination_snapshot.snapshot_persisted_before_apply == true and
    (.destination_snapshot.fingerprint | test("^[0-9a-f]{64}$")) and
    .import.record_count == 3 and
    .import.apply_result == "accepted" and
    .import.readback_result == "exact" and
    (.import.fingerprint | test("^[0-9a-f]{64}$")) and
    .import.canonical_record_keys_unique == true and
    .import.partitioned_and_unpartitioned_identity_distinct == true and
    ([.import.attribute_coverage[]] | all(. == true)) and
    .destination_rejection.set_result == "rejected" and
    .destination_rejection.rollback_result == "exact" and
    .origin_state.cookie_names_guessed == false and
    .origin_state.cookie_manager_supported == true and
    .origin_state.registered_adapter_count == 0 and
    .origin_state.non_cookie_transfer_result == "not-tested" and
    .cleanup.complete_profile_cookie_store == "empty"
  ' "$cookie_temporary" >/dev/null || {
    echo "browser-native disposable cookie acceptance did not pass" >&2
    exit 1
  }
  install -m 600 "$cookie_temporary" \
    "$staged/cookie-native-acceptance.json"
fi

printf 'completed_at=%s\n' "$(date --iso-8601=seconds)" >> "$action_log"
cp "$acceptance/acceptance.env" "$staged/acceptance.env"
if [[ -n "$fixture_receipt" ]]; then
  echo "$fixture_receipt_sha256  $fixture_receipt" | sha256sum -c - >/dev/null
  cp "$fixture_receipt" "$staged/fixture-provenance.json"
  [[ "$(sha256sum "$staged/fixture-provenance.json" | cut -d' ' -f1)" == \
      "$fixture_receipt_sha256" ]]
fi
(
  cd "$staged"
  find . -maxdepth 1 -type f ! -name EVIDENCE_SHA256SUMS -printf '%f\0' \
    | sort -z | xargs -0 sha256sum > EVIDENCE_SHA256SUMS
)
mv "$staged" "$evidence"
cleanup
trap - EXIT INT TERM
printf 'evidence_directory=%s\n' "$evidence"
printf 'result_sha256=%s\n' "$(sha256sum "$evidence/result.json" | cut -d' ' -f1)"
