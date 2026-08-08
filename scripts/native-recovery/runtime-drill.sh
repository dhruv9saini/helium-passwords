#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
acceptance=${HELIUM_NATIVE_RECOVERY_ACCEPTANCE:-$script_dir/acceptance.mjs}
android_boundary=$repo_root/scripts/android-media/disposable-browser.sh
package=computer.helium.sync.test
profile_marker=.helium-native-recovery-disposable-profile-v1
profile_marker_content=helium-native-recovery-disposable-profile-v1
desktop_root_marker=.helium-native-recovery-drill-root-v1
desktop_root_marker_content=helium-native-recovery-drill-root-v1
receipt_relative=Default/helium-sync/native-recovery-receipt-v1.json

usage() {
  cat >&2 <<'EOF'
usage:
  runtime-drill.sh desktop BROWSER d|da passwords|cookies SNAPSHOT \
    DRILL-PROFILE headless|headed [TIMEOUT-SECONDS]
  runtime-drill.sh android ACCEPTANCE-DIR ADB-SERIAL passwords|cookies \
    SNAPSHOT DRILL-SLUG NEW-RECEIPT [TIMEOUT-SECONDS]

Desktop DRILL-PROFILE must be a new direct child of a private directory marked
.helium-native-recovery-drill-root-v1. Android operates only inside the exact
checksum-admitted computer.helium.sync.test sandbox. Both modes launch a fresh
marked profile, wait for Chromium's native readback receipt, and never touch a
personal profile or the production Android package.
EOF
}

fail() { echo "native recovery runtime drill: $*" >&2; exit 1; }

private_file() {
  [[ -f "$1" && ! -L "$1" && -s "$1" && "$(stat -c %a "$1")" == 600 ]] ||
    fail "$2 must be a private nonempty regular file"
}

private_directory() {
  [[ -d "$1" && ! -L "$1" && "$(stat -c %a "$1")" == 700 ]] ||
    fail "$2 must be a private real directory"
}

parse_timeout() {
  local value=${1:-120}
  [[ "$value" =~ ^[0-9]+$ && "$value" -ge 15 && "$value" -le 300 ]] ||
    fail "timeout must be 15 through 300 seconds"
  printf '%s\n' "$value"
}

verify_snapshot() {
  local kind=$1 device=$2 snapshot=$3
  node "$acceptance" verify-snapshot --kind "$kind" --device "$device" \
    --snapshot "$snapshot" >/dev/null
}

verify_browser_receipt() {
  local kind=$1 snapshot=$2 receipt=$3
  private_file "$receipt" "native browser receipt"
  local snapshot_sha records_sha state_sha count api
  snapshot_sha=$(sha256sum "$snapshot" | cut -d' ' -f1)
  records_sha=$(jq -er '.records_sha256' "$snapshot")
  state_sha=$(jq -er '.state_sha256' "$snapshot")
  count=$(jq -er '.record_count' "$snapshot")
  case "$kind" in
    passwords) api=PasswordStoreInterface ;;
    cookies) api=network::mojom::CookieManager ;;
    *) fail "invalid recovery kind" ;;
  esac
  jq -e --arg kind "$kind" --arg snapshot "$snapshot_sha" \
    --arg records "$records_sha" --arg state "$state_sha" \
    --argjson count "$count" --arg api "$api" '
      (keys | sort) == ([
        "browser_api", "completed_at_windows_us", "kind", "records_sha256",
        "restored_count", "restored_state_sha256", "result",
        "schema_version", "snapshot_sha256"
      ] | sort) and
      .schema_version == 1 and .result == "passed" and .kind == $kind and
      .snapshot_sha256 == $snapshot and .records_sha256 == $records and
      .restored_state_sha256 == $state and .restored_count == $count and
      .browser_api == $api and
      (.completed_at_windows_us | type == "string" and test("^[1-9][0-9]*$"))
    ' "$receipt" >/dev/null || fail "browser receipt does not bind the snapshot"
}

wait_local_receipt() {
  local receipt=$1 pid=$2 timeout=$3 log=$4
  local deadline=$((SECONDS + timeout))
  while (( SECONDS <= deadline )); do
    [[ -s "$receipt" ]] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 80 "$log" >&2 || true
      fail "browser exited before producing a recovery receipt"
    fi
    sleep 1
  done
  tail -n 80 "$log" >&2 || true
  fail "browser did not produce a recovery receipt before timeout"
}

desktop_drill() {
  [[ $# -ge 6 && $# -le 7 ]] || { usage; exit 64; }
  local browser=$1 device=$2 kind=$3 snapshot=$4 profile=$5 display_mode=$6
  local timeout
  timeout=$(parse_timeout "${7:-}")
  case "$device" in d|da) ;; *) usage; exit 64 ;; esac
  case "$kind" in passwords|cookies) ;; *) usage; exit 64 ;; esac
  case "$display_mode" in headless|headed) ;; *) usage; exit 64 ;; esac
  [[ "$(uname -n | cut -d. -f1)" == "$device" ]] ||
    fail "desktop device does not match this host"
  [[ "$browser" == /* && -x "$browser" && -f "$browser" &&
      ! -L "$browser" && "$(realpath -e -- "$browser")" == "$browser" ]] ||
    fail "browser must be an explicit real executable"
  snapshot=$(realpath -e -- "$snapshot")
  private_file "$snapshot" "snapshot"
  verify_snapshot "$kind" "$device" "$snapshot"
  [[ "$profile" == /* && "$(realpath -ms -- "$profile")" == "$profile" &&
      "$(basename "$profile")" =~ ^drill-[a-z0-9][a-z0-9._-]{0,57}$ ]] ||
    fail "desktop drill profile path is invalid"
  local parent marker default receipt log pid
  parent=$(dirname "$profile")
  private_directory "$parent" "desktop drill root"
  marker=$parent/$desktop_root_marker
  private_file "$marker" "desktop drill root marker"
  [[ "$(<"$marker")" == "$desktop_root_marker_content" ]] ||
    fail "desktop drill root marker is invalid"
  [[ ! -e "$profile" && ! -L "$profile" ]] ||
    fail "desktop drill profile must not exist"
  mkdir -m 0700 "$profile"
  default=$profile/Default
  mkdir -m 0700 "$default"
  (umask 077; printf '%s\n' "$profile_marker_content" >"$default/$profile_marker")
  log=$profile/native-recovery-browser.log
  (umask 077; : >"$log")
  receipt=$profile/$receipt_relative
  local -a args=(
    "--user-data-dir=$profile"
    --no-first-run
    --no-default-browser-check
    --disable-component-update
    --disable-default-apps
    --disable-extensions
    --disable-sync
    "--helium-restore-disposable-native-$kind=$snapshot"
  )
  [[ "$display_mode" == headed ]] || args+=(--headless=new)
  setsid "$browser" "${args[@]}" </dev/null >"$log" 2>&1 &
  pid=$!
  cleanup_desktop() {
    local result=$?
    trap - EXIT INT TERM
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    exit "$result"
  }
  trap cleanup_desktop EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wait_local_receipt "$receipt" "$pid" "$timeout" "$log"
  verify_browser_receipt "$kind" "$snapshot" "$receipt"
  printf 'runtime_recovery=passed\nplatform=desktop\ndevice=%s\nkind=%s\n' \
    "$device" "$kind"
  printf 'profile=%s\nreceipt=%s\nartifact_sha256=%s\n' "$profile" "$receipt" \
    "$(sha256sum "$browser" | cut -d' ' -f1)"
  cleanup_desktop
}

android_drill() {
  [[ $# -ge 6 && $# -le 7 ]] || { usage; exit 64; }
  local acceptance_dir=$1 serial=$2 kind=$3 snapshot=$4 slug=$5 output=$6
  local timeout
  timeout=$(parse_timeout "${7:-}")
  case "$kind" in passwords|cookies) ;; *) usage; exit 64 ;; esac
  [[ "$serial" =~ ^[A-Za-z0-9._:-]+$ &&
      "$slug" =~ ^drill-[a-z0-9][a-z0-9._-]{0,57}$ ]] || {
    usage
    exit 64
  }
  acceptance_dir=$(realpath -e -- "$acceptance_dir")
  snapshot=$(realpath -e -- "$snapshot")
  private_file "$snapshot" "snapshot"
  verify_snapshot "$kind" oneplus "$snapshot"
  [[ "$output" == /* && "$(realpath -ms -- "$output")" == "$output" ]] ||
    fail "Android receipt output must be an absolute normalized path"
  private_directory "$(dirname "$output")" "Android receipt output parent"
  [[ ! -e "$output" && ! -L "$output" ]] ||
    fail "Android receipt output already exists"
  local -a adb_command=(adb -s "$serial")
  [[ "$("${adb_command[@]}" get-state | tr -d '\r')" == device ]] ||
    fail "ADB target is not in device state"
  local package_dump data_dir profile_parent profile default input_parent
  local device_snapshot device_receipt local_snapshot_sha device_snapshot_sha
  package_dump=$("${adb_command[@]}" shell dumpsys package "$package" | tr -d '\r')
  data_dir=$(sed -n 's/^[[:space:]]*dataDir=//p' <<<"$package_dump" | head -n1)
  [[ "$data_dir" == "/data/user/0/$package" ]] ||
    fail "disposable package dataDir is not its canonical sandbox"
  profile_parent=$data_dir/helium-native-recovery-drills
  profile=$profile_parent/$slug
  default=$profile/Default
  input_parent=$data_dir/helium-native-recovery-drill-inputs/$slug
  device_snapshot=$input_parent/$kind.current.json
  device_receipt=$profile/$receipt_relative
  "${adb_command[@]}" shell am force-stop "$package" >/dev/null
  "${adb_command[@]}" exec-out run-as "$package" sh -c \
    "umask 077; test -d '$data_dir'; test ! -L '$data_dir'; if test -e '$profile_parent' || test -L '$profile_parent'; then test -d '$profile_parent'; test ! -L '$profile_parent'; test \"\$(readlink -f '$profile_parent')\" = '$profile_parent'; else mkdir '$profile_parent'; fi; if test -e '$data_dir/helium-native-recovery-drill-inputs' || test -L '$data_dir/helium-native-recovery-drill-inputs'; then test -d '$data_dir/helium-native-recovery-drill-inputs'; test ! -L '$data_dir/helium-native-recovery-drill-inputs'; test \"\$(readlink -f '$data_dir/helium-native-recovery-drill-inputs')\" = '$data_dir/helium-native-recovery-drill-inputs'; else mkdir '$data_dir/helium-native-recovery-drill-inputs'; fi; chmod 700 '$profile_parent' '$data_dir/helium-native-recovery-drill-inputs'; test ! -e '$profile'; test ! -L '$profile'; test ! -e '$input_parent'; test ! -L '$input_parent'; mkdir '$profile' '$default' '$input_parent'; chmod 700 '$profile' '$default' '$input_parent'; printf '$profile_marker_content\n' >'$default/$profile_marker'; chmod 600 '$default/$profile_marker'; cat >'$device_snapshot'; chmod 600 '$device_snapshot'" \
    <"$snapshot" >/dev/null || fail "could not stage disposable Android recovery input"
  local_snapshot_sha=$(sha256sum "$snapshot" | cut -d' ' -f1)
  device_snapshot_sha=$("${adb_command[@]}" exec-out run-as "$package" \
    sha256sum "$device_snapshot" | tr -d '\r' | cut -d' ' -f1)
  [[ "$device_snapshot_sha" == "$local_snapshot_sha" ]] ||
    fail "Android staged snapshot hash changed"
  local launched=false
  cleanup_android() {
    local result=$?
    trap - EXIT INT TERM
    if [[ "$launched" == true ]]; then
      "${adb_command[@]}" shell am force-stop "$package" >/dev/null 2>&1 || true
    fi
    [[ "$result" -eq 0 ]] || rm -f -- "$output"
    exit "$result"
  }
  trap cleanup_android EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local launch
  launch=$("$android_boundary" launch "$acceptance_dir" "$serial" \
    --native-recovery-profile "$slug" --native-recovery-kind "$kind" \
    --native-recovery-source "$device_snapshot")
  launched=true
  grep -qx 'operation=launch' <<<"$launch" || fail "Android launch was not admitted"
  grep -qx "package=$package" <<<"$launch" || fail "Android launch package changed"
  grep -qx "native_recovery_kind=$kind" <<<"$launch" ||
    fail "Android launch kind changed"
  grep -qx "native_recovery_user_data_dir=$profile" <<<"$launch" ||
    fail "Android launch profile changed"
  grep -qx "native_recovery_source=$device_snapshot" <<<"$launch" ||
    fail "Android launch source changed"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS <= deadline )); do
    if "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -s '$device_receipt' && test -f '$device_receipt' && test ! -L '$device_receipt' && test \"\$(stat -c %a '$device_receipt')\" = 600" \
      >/dev/null 2>&1; then
      break
    fi
    [[ -n "$("${adb_command[@]}" shell pidof "$package" | tr -d '\r')" ]] ||
      fail "Android browser exited before producing a recovery receipt"
    sleep 1
  done
  "${adb_command[@]}" exec-out run-as "$package" sh -c \
    "test -s '$device_receipt' && test -f '$device_receipt' && test ! -L '$device_receipt' && test \"\$(stat -c %a '$device_receipt')\" = 600" \
    >/dev/null 2>&1 || fail "Android browser did not produce a receipt before timeout"
  (umask 077; set -o noclobber; : >"$output")
  "${adb_command[@]}" exec-out run-as "$package" cat "$device_receipt" >"$output"
  private_file "$output" "fetched Android native browser receipt"
  verify_browser_receipt "$kind" "$snapshot" "$output"
  local artifact_sha
  artifact_sha=$(sed -n 's/^apk_sha256=//p' "$acceptance_dir/acceptance.env")
  [[ "$artifact_sha" =~ ^[0-9a-f]{64}$ ]] || fail "acceptance APK hash is invalid"
  printf 'runtime_recovery=passed\nplatform=android\ndevice=oneplus\nkind=%s\n' \
    "$kind"
  printf 'device_profile=%s\ndevice_snapshot=%s\nreceipt=%s\nartifact_sha256=%s\n' \
    "$profile" "$device_snapshot" "$output" "$artifact_sha"
  cleanup_android
}

command=${1:-}
shift || true
case "$command" in
  desktop) desktop_drill "$@" ;;
  android) android_drill "$@" ;;
  *) usage; exit 64 ;;
esac
