#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  reset-disposable-package.sh ACCEPTANCE_DIRECTORY ADB_SERIAL \
    media-cookie password-sync NEW_RECEIPT
  reset-disposable-package.sh ACCEPTANCE_DIRECTORY ADB_SERIAL \
    password-sync tab-recovery NEW_RECEIPT

Clear only the checksum-admitted computer.helium.sync.test sandbox between
phases of one full Android end-to-end acceptance. The production package,
installed APK, global debug selection, and Chromium command-line files must be
unchanged. A network ADB serial is rejected.
EOF
}

[[ $# -eq 5 ]] || { usage; exit 64; }
acceptance_input=$1
serial=$2
from_phase=$3
to_phase=$4
receipt_input=$5
package=computer.helium.sync.test
production_package=computer.helium.sync

case "$from_phase:$to_phase" in
  media-cookie:password-sync|password-sync:tab-recovery) ;;
  *) usage; exit 64 ;;
esac
[[ "$serial" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "ADB serial must identify a non-network device" >&2
  exit 64
}
[[ -d "$acceptance_input" && ! -L "$acceptance_input" ]] || {
  echo "acceptance directory must be a real directory" >&2
  exit 1
}
acceptance=$(realpath -e -- "$acceptance_input")
[[ "$receipt_input" == /* &&
    "$(realpath -ms -- "$receipt_input")" == "$receipt_input" ]] || {
  echo "receipt path must be absolute and lexically normalized" >&2
  exit 64
}
receipt_parent=$(dirname -- "$receipt_input")
[[ -d "$receipt_parent" && ! -L "$receipt_parent" &&
    "$(realpath -e -- "$receipt_parent")" == "$receipt_parent" &&
    "$(stat -c %a -- "$receipt_parent")" == 700 ]] || {
  echo "receipt parent must be a resolved mode-0700 directory" >&2
  exit 1
}
[[ ! -e "$receipt_input" && ! -L "$receipt_input" ]] || {
  echo "reset receipt already exists" >&2
  exit 1
}

for tool in adb awk chmod date dirname find grep head ln mktemp node realpath sed \
  sha256sum sort stat tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

identity_tool=$(realpath -e "$(dirname "${BASH_SOURCE[0]}")/physical-device-identity.mjs")
identity_output=$(node "$identity_tool" capture --adb-serial "$serial")
declare -A physical_identity=()
identity_fields=(
  schema_version identity_schema adb_serial adb_transport adb_transport_id
  adb_usb_path_sha256 android_model android_device android_product
  android_manufacturer build_fingerprint_sha256 physical_identity_sha256
  captured_at
)
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([a-z][a-z0-9_]*)=(.+)$ ]] || {
    echo "physical device identity output is malformed" >&2
    exit 1
  }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  admitted=false
  for candidate in "${identity_fields[@]}"; do
    if [[ "$key" == "$candidate" ]]; then admitted=true; break; fi
  done
  [[ "$admitted" == true && ! -v "physical_identity[$key]" ]] || {
    echo "physical device identity output is unexpected" >&2
    exit 1
  }
  physical_identity[$key]=$value
done <<<"$identity_output"
[[ "${#physical_identity[@]}" -eq "${#identity_fields[@]}" &&
    "${physical_identity[adb_serial]}" == "$serial" ]] || {
  echo "physical device identity output is incomplete" >&2
  exit 1
}

[[ -f "$acceptance/acceptance.env" &&
    ! -L "$acceptance/acceptance.env" &&
    -f "$acceptance/PACKAGE_SHA256SUMS" &&
    ! -L "$acceptance/PACKAGE_SHA256SUMS" ]] || {
  echo "acceptance directory is incomplete or unsafe" >&2
  exit 1
}
if [[ -n "$(find "$acceptance" -type l -print -quit)" ||
      -n "$(find "$acceptance" ! -type d ! -type f -print -quit)" ]]; then
  echo "acceptance directory contains a symlink or special entry" >&2
  exit 1
fi

recorded_inventory=
while IFS= read -r checksum_line || [[ -n "$checksum_line" ]]; do
  if [[ "$checksum_line" =~ ^[0-9a-f]{64}\ \ \./([A-Za-z0-9._/-]+)$ ]]; then
    relative=${BASH_REMATCH[1]}
  else
    echo "acceptance checksum inventory contains an unsafe line" >&2
    exit 1
  fi
  case "/$relative/" in
    *"/../"*|*"//"*)
      echo "acceptance checksum path is unsafe" >&2
      exit 1
      ;;
  esac
  recorded_inventory+="${relative}"$'\n'
done <"$acceptance/PACKAGE_SHA256SUMS"
recorded_inventory=$(printf '%s' "$recorded_inventory" | LC_ALL=C sort)
actual_inventory=$(
  cd "$acceptance"
  find . -type f ! -name PACKAGE_SHA256SUMS -printf '%P\n' | LC_ALL=C sort
)
[[ "$recorded_inventory" == "$actual_inventory" ]] || {
  echo "acceptance checksum inventory is incomplete or unexpected" >&2
  exit 1
}
(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS >/dev/null)
acceptance_inventory_sha256=$(sha256sum \
  "$acceptance/PACKAGE_SHA256SUMS" | awk '{print $1}')

declare -A metadata=()
allowed_metadata=(
  schema_version package helium_sync_commit chromium_commit version_code
  version_name source_archive_sha256 apk_sha256 runtime_kit_sha256 prepared_at
)
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([a-z][a-z0-9_]*)=(.+)$ ]] || {
    echo "acceptance metadata contains a malformed line" >&2
    exit 1
  }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  allowed=false
  for candidate in "${allowed_metadata[@]}"; do
    if [[ "$key" == "$candidate" ]]; then allowed=true; break; fi
  done
  [[ "$allowed" == true && ! -v "metadata[$key]" ]] || {
    echo "acceptance metadata contains an unknown or duplicate field" >&2
    exit 1
  }
  metadata[$key]=$value
done <"$acceptance/acceptance.env"
for key in "${allowed_metadata[@]}"; do
  [[ -v "metadata[$key]" ]] || {
    echo "acceptance metadata is incomplete" >&2
    exit 1
  }
done
[[ "${metadata[schema_version]}" == 2 &&
    "${metadata[package]}" == "$package" &&
    "${metadata[helium_sync_commit]}" =~ ^[0-9a-f]{40}$ &&
    "${metadata[chromium_commit]}" =~ ^[0-9a-f]{40}$ &&
    "${metadata[source_archive_sha256]}" =~ ^[0-9a-f]{64}$ &&
    "${metadata[apk_sha256]}" =~ ^[0-9a-f]{64}$ &&
    "${metadata[version_code]}" =~ ^[1-9][0-9]*$ &&
    "${metadata[version_name]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "acceptance metadata is not the admitted Sync test package" >&2
  exit 1
}
[[ -f "$acceptance/Browser-test.apk" &&
    ! -L "$acceptance/Browser-test.apk" &&
    "$(sha256sum "$acceptance/Browser-test.apk" | awk '{print $1}')" == \
      "${metadata[apk_sha256]}" ]] || {
  echo "acceptance APK is missing or changed" >&2
  exit 1
}

adb_command=(adb -s "$serial")
[[ "$("${adb_command[@]}" get-state | tr -d '\r')" == device ]] || {
  echo "ADB target is not in device state" >&2
  exit 1
}
device_line=$(adb devices -l | awk -v serial="$serial" \
  '$1 == serial && $2 == "device" {print; count++} END {if (count != 1) exit 1}') || {
  echo "ADB target does not have one unambiguous device transport" >&2
  exit 1
}
[[ " $device_line " == *" usb:"* && "$serial" != emulator-* ]] || {
  echo "full Android acceptance requires a physical USB ADB transport" >&2
  exit 1
}

installed_test_apk=
installed_test_apk_sha256=
installed_test_version_code=
installed_test_version_name=
installed_test_data_dir=
snapshot_test_package() {
  local dump
  local -a paths=()
  mapfile -t paths < <(
    "${adb_command[@]}" shell pm path "$package" | tr -d '\r'
  )
  [[ ${#paths[@]} -eq 1 && "${paths[0]}" == package:/data/app/*/base.apk ]] || {
    echo "Sync test package is not one monolithic installed APK" >&2
    return 1
  }
  installed_test_apk=${paths[0]#package:}
  [[ "$installed_test_apk" != *[[:space:]\'\"]* ]] || {
    echo "installed Sync test APK path is unsafe" >&2
    return 1
  }
  installed_test_apk_sha256=$(
    "${adb_command[@]}" exec-out cat "$installed_test_apk" |
      sha256sum | awk '{print $1}'
  )
  [[ "$installed_test_apk_sha256" == "${metadata[apk_sha256]}" ]] || {
    echo "installed Sync test APK does not match the admission" >&2
    return 1
  }
  dump=$("${adb_command[@]}" shell dumpsys package "$package" | tr -d '\r')
  installed_test_version_code=$(
    sed -n 's/^[[:space:]]*versionCode=\([^ ]*\).*/\1/p' <<<"$dump" |
      head -n 1
  )
  installed_test_version_name=$(
    sed -n 's/^[[:space:]]*versionName=//p' <<<"$dump" | head -n 1
  )
  installed_test_data_dir=$(
    sed -n 's/^[[:space:]]*dataDir=//p' <<<"$dump" | head -n 1
  )
  [[ "$installed_test_version_code" == "${metadata[version_code]}" &&
      "$installed_test_version_name" == "${metadata[version_name]}" &&
      ( "$installed_test_data_dir" == "/data/user/0/$package" ||
        "$installed_test_data_dir" == "/data/data/$package" ) ]] || {
    echo "installed Sync test package identity does not match the admission" >&2
    return 1
  }
}

snapshot_production_package() {
  local dump path_output apk_path apk_sha version_code version_name data_dir
  path_output=$("${adb_command[@]}" shell pm path "$production_package" |
    tr -d '\r')
  if [[ -z "$path_output" ]]; then
    printf '%s\n' 'state=absent'
    return
  fi
  [[ "$path_output" != *$'\n'* &&
      "$path_output" == package:/data/app/*/base.apk ]] || {
    echo "production package has an unsupported APK layout" >&2
    return 1
  }
  apk_path=${path_output#package:}
  [[ "$apk_path" != *[[:space:]\'\"]* ]] || {
    echo "production APK path is unsafe" >&2
    return 1
  }
  apk_sha=$("${adb_command[@]}" exec-out cat "$apk_path" |
    sha256sum | awk '{print $1}')
  dump=$("${adb_command[@]}" shell dumpsys package "$production_package" |
    tr -d '\r')
  version_code=$(sed -n 's/^[[:space:]]*versionCode=\([^ ]*\).*/\1/p' \
    <<<"$dump" | head -n 1)
  version_name=$(sed -n 's/^[[:space:]]*versionName=//p' \
    <<<"$dump" | head -n 1)
  data_dir=$(sed -n 's/^[[:space:]]*dataDir=//p' \
    <<<"$dump" | head -n 1)
  [[ "$apk_sha" =~ ^[0-9a-f]{64}$ &&
      "$version_code" =~ ^[1-9][0-9]*$ &&
      -n "$version_name" &&
      ( "$data_dir" == "/data/user/0/$production_package" ||
        "$data_dir" == "/data/data/$production_package" ) ]] || {
    echo "production package identity cannot be safely recorded" >&2
    return 1
  }
  printf 'state=present\napk_sha256=%s\nversion_code=%s\nversion_name=%s\ndata_dir=%s\n' \
    "$apk_sha" "$version_code" "$version_name" "$data_dir"
}

remote_file_identity() {
  local remote=$1 kind mode hash
  kind=$("${adb_command[@]}" shell \
    "if [ -L '$remote' ]; then printf unsafe; elif [ -f '$remote' ]; then printf file; elif [ -e '$remote' ]; then printf unsafe; else printf absent; fi" |
    tr -d '\r')
  case "$kind" in
    absent) printf '%s=absent\n' "$remote" ;;
    file)
      mode=$("${adb_command[@]}" shell stat -c %a "$remote" | tr -d '\r')
      hash=$("${adb_command[@]}" exec-out cat "$remote" |
        sha256sum | awk '{print $1}')
      [[ "$mode" =~ ^[0-7]{3,4}$ && "$hash" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Android Chromium command-line identity is invalid" >&2
        return 1
      }
      printf '%s=file:%s:%s\n' "$remote" "$mode" "$hash"
      ;;
    *)
      echo "Android Chromium command-line path is unsafe" >&2
      return 1
      ;;
  esac
}

snapshot_global_state() {
  local debug wait
  debug=$("${adb_command[@]}" shell settings get global debug_app | tr -d '\r')
  wait=$("${adb_command[@]}" shell settings get global wait_for_debugger |
    tr -d '\r')
  [[ "$debug" != *$'\n'* && "$wait" != *$'\n'* ]] || {
    echo "Android debug state is malformed" >&2
    return 1
  }
  printf 'debug_app=%s\nwait_for_debugger=%s\n' "$debug" "$wait"
  remote_file_identity /data/local/tmp/chrome-command-line
  remote_file_identity /data/local/chrome-command-line
}

snapshot_test_package
before_test_apk=$installed_test_apk
before_test_hash=$installed_test_apk_sha256
before_test_version_code=$installed_test_version_code
before_test_version_name=$installed_test_version_name
before_test_data_dir=$installed_test_data_dir
before_production=$(snapshot_production_package)
before_global=$(snapshot_global_state)

"${adb_command[@]}" shell am force-stop "$package" >/dev/null
[[ -z "$("${adb_command[@]}" shell pidof "$package" | tr -d '\r')" ]] || {
  echo "Sync test package did not stop before phase reset" >&2
  exit 1
}
clear_output=$("${adb_command[@]}" shell pm clear --user 0 "$package" |
  tr -d '\r')
[[ "$clear_output" == Success ]] || {
  echo "Android did not confirm the Sync test sandbox reset" >&2
  exit 1
}

snapshot_test_package
after_production=$(snapshot_production_package)
after_global=$(snapshot_global_state)
[[ "$installed_test_apk" == "$before_test_apk" &&
    "$installed_test_apk_sha256" == "$before_test_hash" &&
    "$installed_test_version_code" == "$before_test_version_code" &&
    "$installed_test_version_name" == "$before_test_version_name" &&
    "$installed_test_data_dir" == "$before_test_data_dir" ]] || {
  echo "Sync test package identity changed during phase reset" >&2
  exit 1
}
[[ "$after_production" == "$before_production" ]] || {
  echo "production package identity changed during Sync test reset" >&2
  exit 1
}
[[ "$after_global" == "$before_global" ]] || {
  echo "Android global browser state changed during Sync test reset" >&2
  exit 1
}
"${adb_command[@]}" exec-out run-as "$package" sh -c \
  "test ! -e '$installed_test_data_dir/app_chrome' && test ! -L '$installed_test_data_dir/app_chrome' && test ! -e '$installed_test_data_dir/helium-tab-runtime-neutral' && test ! -L '$installed_test_data_dir/helium-tab-runtime-neutral' && test ! -e '$installed_test_data_dir/helium-tab-runtime-full-profile' && test ! -L '$installed_test_data_dir/helium-tab-runtime-full-profile'" \
  >/dev/null || {
  echo "Sync test browser roots remain after phase reset" >&2
  exit 1
}

production_state=$(sed -n 's/^state=//p' <<<"$before_production")
production_identity_sha256=$(printf '%s\n' "$before_production" |
  sha256sum | awk '{print $1}')
global_state_sha256=$(printf '%s\n' "$before_global" |
  sha256sum | awk '{print $1}')
reset_boundary_sha256=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
temporary=$(mktemp "$receipt_parent/.helium-android-reset.XXXXXX")
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT
chmod 0600 "$temporary"
{
  printf 'schema_version=2\nresult=passed\n'
  printf 'package=%s\n' "$package"
  for key in identity_schema adb_serial adb_transport adb_transport_id \
    adb_usb_path_sha256 android_model android_device android_product \
    android_manufacturer build_fingerprint_sha256 physical_identity_sha256; do
    printf '%s=%s\n' "$key" "${physical_identity[$key]}"
  done
  printf 'physical_identity_captured_at=%s\n' "${physical_identity[captured_at]}"
  printf 'physical_identity_tool_sha256=%s\n' \
    "$(sha256sum "$identity_tool" | awk '{print $1}')"
  printf 'from_phase=%s\nto_phase=%s\n' "$from_phase" "$to_phase"
  printf 'helium_sync_commit=%s\nchromium_commit=%s\n' \
    "${metadata[helium_sync_commit]}" "${metadata[chromium_commit]}"
  printf 'source_archive_sha256=%s\nacceptance_inventory_sha256=%s\n' \
    "${metadata[source_archive_sha256]}" "$acceptance_inventory_sha256"
  printf 'apk_sha256=%s\nversion_code=%s\nversion_name=%s\n' \
    "$installed_test_apk_sha256" "$installed_test_version_code" \
    "$installed_test_version_name"
  printf 'production_package=%s\nproduction_state=%s\n' \
    "$production_package" "$production_state"
  printf 'production_identity_sha256=%s\nglobal_state_sha256=%s\n' \
    "$production_identity_sha256" "$global_state_sha256"
  printf 'reset_boundary_sha256=%s\ncleared_at=%s\n' \
    "$reset_boundary_sha256" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$temporary"
ln "$temporary" "$receipt_input"
rm -f -- "$temporary"
trap - EXIT
printf 'reset_receipt=%s\nreset_receipt_sha256=%s\n' \
  "$receipt_input" "$(sha256sum "$receipt_input" | awk '{print $1}')"
