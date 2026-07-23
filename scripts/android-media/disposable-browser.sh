#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  disposable-browser.sh install ACCEPTANCE_DIRECTORY ADB_SERIAL
  disposable-browser.sh launch ACCEPTANCE_DIRECTORY ADB_SERIAL [--fixture-receipt FILE]

Install or launch only a checksum-admitted computer.helium.sync.test or
computer.helium.control.test APK. The launch command temporarily owns Android's
two Chromium command-line files and debug-app selection, verifies the expected
package-specific DevTools socket, and restores all temporary global state
before returning.
EOF
}

[[ $# -ge 3 ]] || { usage; exit 64; }
operation=$1
acceptance_input=$2
serial=$3
shift 3

case "$operation" in
  install) [[ $# -eq 0 ]] || { usage; exit 64; } ;;
  launch) ;;
  *) usage; exit 64 ;;
esac
[[ "$serial" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "ADB serial contains unsupported characters" >&2
  exit 64
}
[[ -d "$acceptance_input" && ! -L "$acceptance_input" ]] || {
  echo "acceptance directory must be a real directory, not a symlink" >&2
  exit 1
}
acceptance=$(realpath -e -- "$acceptance_input")

fixture_receipt=
if [[ "$operation" == launch ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fixture-receipt)
        [[ $# -eq 2 && -z "$fixture_receipt" ]] || { usage; exit 64; }
        fixture_receipt=$2
        shift 2
        ;;
      *) usage; exit 64 ;;
    esac
  done
fi

for tool in adb awk find grep jq realpath sed sha256sum sort; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

[[ -f "$acceptance/acceptance.env" &&
    ! -L "$acceptance/acceptance.env" &&
    -f "$acceptance/PACKAGE_SHA256SUMS" &&
    ! -L "$acceptance/PACKAGE_SHA256SUMS" ]] || {
  echo "acceptance directory is incomplete or unsafe" >&2
  exit 1
}
if [[ -n "$(find "$acceptance" -type l -print -quit)" ||
      -n "$(find "$acceptance" ! -type d ! -type f -print -quit)" ]]; then
  echo "acceptance directory contains a symlink or non-file entry" >&2
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
    *"/../"*|*"//"*) echo "acceptance checksum path is unsafe" >&2; exit 1 ;;
  esac
  recorded_inventory+="${relative}"$'\n'
done < "$acceptance/PACKAGE_SHA256SUMS"
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

declare -A metadata=()
allowed_metadata=(
  schema_version package helium_sync_commit chromium_commit version_code
  version_name source_archive_sha256 apk_sha256 runtime_kit_sha256 prepared_at
)
while IFS= read -r metadata_line || [[ -n "$metadata_line" ]]; do
  [[ "$metadata_line" =~ ^([a-z][a-z0-9_]*)=(.+)$ ]] || {
    echo "acceptance metadata contains a malformed line" >&2
    exit 1
  }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  allowed=false
  for candidate in "${allowed_metadata[@]}"; do
    if [[ "$key" == "$candidate" ]]; then
      allowed=true
      break
    fi
  done
  [[ "$allowed" == true ]] || {
    echo "acceptance metadata contains an unknown field: $key" >&2
    exit 1
  }
  [[ ! -v "metadata[$key]" ]] || {
    echo "acceptance metadata contains a duplicate field: $key" >&2
    exit 1
  }
  metadata[$key]=$value
done < "$acceptance/acceptance.env"
for key in "${allowed_metadata[@]}"; do
  [[ -v "metadata[$key]" ]] || {
    echo "acceptance metadata is missing: $key" >&2
    exit 1
  }
done
[[ "${metadata[schema_version]}" == 2 ]] || {
  echo "unsupported acceptance schema" >&2
  exit 1
}

package=${metadata[package]}
case "$package" in
  computer.helium.sync.test)
    device_socket=helium_sync_test_devtools_remote
    ;;
  computer.helium.control.test)
    device_socket=helium_control_test_devtools_remote
    ;;
  *)
    echo "only disposable Helium test packages are admitted" >&2
    exit 1
    ;;
esac
[[ "${metadata[helium_sync_commit]}" =~ ^[0-9a-f]{40}$ &&
    "${metadata[chromium_commit]}" =~ ^[0-9a-f]{40}$ &&
    "${metadata[source_archive_sha256]}" =~ ^[0-9a-f]{64}$ &&
    "${metadata[apk_sha256]}" =~ ^[0-9a-f]{64}$ &&
    "${metadata[runtime_kit_sha256]}" =~ ^[0-9a-f]{64}$ &&
    "${metadata[version_code]}" =~ ^[1-9][0-9]*$ &&
    "${metadata[version_name]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "acceptance metadata has an invalid source, hash, or version value" >&2
  exit 1
}

apk="$acceptance/Browser-test.apk"
[[ -f "$apk" && ! -L "$apk" ]] || {
  echo "admitted disposable APK is missing or unsafe" >&2
  exit 1
}
apk=$(realpath -e -- "$apk")
apk_sha256=$(sha256sum "$apk" | awk '{print $1}')
[[ "$apk_sha256" == "${metadata[apk_sha256]}" ]] || {
  echo "admitted disposable APK hash does not match acceptance metadata" >&2
  exit 1
}

fixture_spki=
fixture_switch=
fixture_receipt_sha256=
if [[ -n "$fixture_receipt" ]]; then
  [[ -f "$fixture_receipt" && ! -L "$fixture_receipt" ]] || {
    echo "fixture receipt must be a regular non-symlink file" >&2
    exit 1
  }
  fixture_receipt=$(realpath -e -- "$fixture_receipt")
  mapfile -t fixture_values < <(
    jq -er '
      if
        (keys | sort) == ([
          "disposable_only", "h2_port", "h3_port", "hostname",
          "leaf_cert_sha256", "leaf_spki_sha256_base64",
          "required_chromium_switch", "schema_version", "tls_mode"
        ] | sort) and
        .schema_version == 1 and .disposable_only == true and
        .tls_mode == "private-ca-spki" and
        .hostname == "lm.tail0168aa.ts.net" and
        .h2_port == 44723 and .h3_port == 44724
      then
        .leaf_spki_sha256_base64,
        .leaf_cert_sha256,
        .required_chromium_switch
      else
        error("fixture receipt is not the admitted disposable endpoint")
      end
    ' "$fixture_receipt"
  )
  [[ ${#fixture_values[@]} -eq 3 ]] || {
    echo "fixture receipt is incomplete" >&2
    exit 1
  }
  fixture_spki=${fixture_values[0]}
  fixture_cert_sha256=${fixture_values[1]}
  fixture_switch=${fixture_values[2]}
  [[ "$fixture_spki" =~ ^[A-Za-z0-9+/]{43}=$ &&
      "$fixture_cert_sha256" =~ ^[0-9a-f]{64}$ &&
      "$fixture_switch" == "--ignore-certificate-errors-spki-list=$fixture_spki" ]] || {
    echo "fixture receipt has an invalid or mismatched SPKI override" >&2
    exit 1
  }
  fixture_receipt_sha256=$(sha256sum "$fixture_receipt" | awk '{print $1}')
fi

adb_command=(adb -s "$serial")
[[ "$("${adb_command[@]}" get-state | tr -d '\r')" == device ]] || {
  echo "ADB target is not in device state" >&2
  exit 1
}

installed_apk_sha256=
verify_installed() {
  local package_dump installed_apk
  local -a package_paths=()
  mapfile -t package_paths < <(
    "${adb_command[@]}" shell pm path "$package" | tr -d '\r'
  )
  [[ ${#package_paths[@]} -eq 1 &&
      "${package_paths[0]}" == package:/data/app/*/base.apk ]] || {
    echo "disposable browser is not one monolithic installed base APK" >&2
    return 1
  }
  installed_apk=${package_paths[0]#package:}
  [[ "$installed_apk" != *[[:space:]\'\"]* ]] || {
    echo "installed disposable APK path is unsafe" >&2
    return 1
  }
  installed_apk_sha256=$(
    "${adb_command[@]}" exec-out cat "$installed_apk" |
      sha256sum | awk '{print $1}'
  )
  [[ "$installed_apk_sha256" == "$apk_sha256" ]] || {
    echo "installed disposable APK does not match the exact admission" >&2
    return 1
  }

  package_dump=$(
    "${adb_command[@]}" shell dumpsys package "$package" | tr -d '\r'
  )
  installed_version_code=$(
    sed -n 's/^[[:space:]]*versionCode=\([^ ]*\).*/\1/p' \
      <<<"$package_dump" | head -n 1
  )
  installed_version_name=$(
    sed -n 's/^[[:space:]]*versionName=//p' \
      <<<"$package_dump" | head -n 1
  )
  [[ "$installed_version_code" == "${metadata[version_code]}" &&
      "$installed_version_name" == "${metadata[version_name]}" ]] || {
    echo "installed disposable package version does not match the admission" >&2
    return 1
  }
}

if [[ "$operation" == install ]]; then
  install_output=$("${adb_command[@]}" install -r --user 0 "$apk" 2>&1) || {
    echo "ADB rejected the admitted disposable APK install" >&2
    exit 1
  }
  [[ "$(tr -d '\r' <<<"$install_output" | sed '/^$/d' | tail -n 1)" == Success ]] || {
    echo "ADB did not confirm the admitted disposable APK install" >&2
    exit 1
  }
  verify_installed
  printf 'operation=install\npackage=%s\napk_sha256=%s\nversion_code=%s\nversion_name=%s\n' \
    "$package" "$installed_apk_sha256" \
    "$installed_version_code" "$installed_version_name"
  exit 0
fi

verify_installed

debug_app=$(
  "${adb_command[@]}" shell settings get global debug_app | tr -d '\r'
)
wait_for_debugger=$(
  "${adb_command[@]}" shell settings get global wait_for_debugger | tr -d '\r'
)
[[ "$debug_app" == null || -z "$debug_app" ]] || {
  echo "refusing to replace an existing Android debug-app selection" >&2
  exit 1
}
[[ "$wait_for_debugger" == 0 || "$wait_for_debugger" == null ||
    -z "$wait_for_debugger" ]] || {
  echo "refusing an existing wait-for-debugger state" >&2
  exit 1
}

temporary=$(mktemp -d /tmp/helium-disposable-browser.XXXXXX)
command_line_paths=(
  /data/local/tmp/chrome-command-line
  /data/local/chrome-command-line
)
declare -A original_kind=()
declare -A original_mode=()
declare -A original_backup=()
declare -A original_sha256=()
command_lines_snapshotted=false
launch_attempted=false
launch_ready=false

remote_file_kind() {
  local path=$1
  "${adb_command[@]}" shell \
    "if [ -L '$path' ]; then printf unsafe; elif [ -f '$path' ]; then printf file; elif [ -e '$path' ]; then printf unsafe; else printf absent; fi" |
    tr -d '\r'
}

remote_file_sha256() {
  local path=$1
  "${adb_command[@]}" exec-out cat "$path" |
    sha256sum | awk '{print $1}'
}

restore_command_lines() {
  local path backup expected actual
  local restore_result=0
  [[ "$command_lines_snapshotted" == true ]] || return 0
  for path in "${command_line_paths[@]}"; do
    case "${original_kind[$path]}" in
      absent)
        "${adb_command[@]}" shell "rm -f -- '$path'" >/dev/null ||
          restore_result=1
        [[ "$(remote_file_kind "$path")" == absent ]] || restore_result=1
        ;;
      file)
        backup=${original_backup[$path]}
        "${adb_command[@]}" push "$backup" "$path" >/dev/null ||
          restore_result=1
        "${adb_command[@]}" shell \
          "chmod ${original_mode[$path]} -- '$path'" >/dev/null ||
          restore_result=1
        expected=$(sha256sum "$backup" | awk '{print $1}')
        actual=$(remote_file_sha256 "$path") || restore_result=1
        [[ "$actual" == "$expected" ]] || restore_result=1
        ;;
      *) restore_result=1 ;;
    esac
  done
  return "$restore_result"
}

clear_owned_debug_app() {
  local current current_wait
  current=$(
    "${adb_command[@]}" shell settings get global debug_app | tr -d '\r'
  ) || return 1
  case "$current" in
    "$package")
      "${adb_command[@]}" shell am clear-debug-app >/dev/null || return 1
      current=$(
        "${adb_command[@]}" shell settings get global debug_app | tr -d '\r'
      ) || return 1
      [[ "$current" == null || -z "$current" ]] || return 1
      ;;
    null|"") ;;
    *) return 1 ;;
  esac
  current_wait=$(
    "${adb_command[@]}" shell settings get global wait_for_debugger | tr -d '\r'
  ) || return 1
  [[ "$current_wait" == 0 || "$current_wait" == null ||
      -z "$current_wait" ]]
}

cleanup() {
  local result=$?
  local cleanup_failed=false
  trap - EXIT INT TERM
  if ! clear_owned_debug_app; then
    echo "failed to clear the disposable Android debug-app state" >&2
    cleanup_failed=true
  fi
  if ! restore_command_lines; then
    echo "failed to restore Android Chromium command-line files" >&2
    cleanup_failed=true
  fi
  if [[ "$result" -ne 0 || "$cleanup_failed" == true ]]; then
    if [[ "$launch_attempted" == true ]]; then
      "${adb_command[@]}" shell am force-stop "$package" >/dev/null 2>&1 ||
        cleanup_failed=true
    fi
  fi
  find "$temporary" -depth -delete
  if [[ "$cleanup_failed" == true ]]; then
    exit 1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for path in "${command_line_paths[@]}"; do
  kind=$(remote_file_kind "$path")
  [[ "$kind" == file || "$kind" == absent ]] || {
    echo "refusing unsafe Android Chromium command-line path: $path" >&2
    exit 1
  }
  original_kind[$path]=$kind
  if [[ "$kind" == file ]]; then
    backup="$temporary/$(basename "$(dirname "$path")")-chrome-command-line"
    "${adb_command[@]}" exec-out cat "$path" > "$backup"
    original_backup[$path]=$backup
    original_sha256[$path]=$(sha256sum "$backup" | awk '{print $1}')
    mode=$(
      "${adb_command[@]}" shell "stat -c %a -- '$path'" | tr -d '\r'
    )
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || {
      echo "cannot preserve Android Chromium command-line mode" >&2
      exit 1
    }
    original_mode[$path]=$mode
  fi
done
command_lines_snapshotted=true
for path in "${command_line_paths[@]}"; do
  kind=$(remote_file_kind "$path")
  [[ "$kind" == "${original_kind[$path]}" ]] || {
    echo "Android Chromium command-line state changed during admission" >&2
    exit 1
  }
  if [[ "$kind" == file ]]; then
    [[ "$(remote_file_sha256 "$path")" == "${original_sha256[$path]}" ]] || {
      echo "Android Chromium command-line bytes changed during admission" >&2
      exit 1
    }
  fi
done

command_line_file="$temporary/admitted-command-line"
{
  printf 'chrome --enable-automation --remote-debugging-socket-name=%s' \
    "$device_socket"
  [[ -z "$fixture_switch" ]] || printf ' %s' "$fixture_switch"
  printf '\n'
} > "$command_line_file"
command_line_sha256=$(sha256sum "$command_line_file" | awk '{print $1}')
for path in "${command_line_paths[@]}"; do
  "${adb_command[@]}" push "$command_line_file" "$path" >/dev/null
  "${adb_command[@]}" shell "chmod 0644 -- '$path'" >/dev/null
  [[ "$(remote_file_sha256 "$path")" == "$command_line_sha256" ]] || {
    echo "Android rejected the exact disposable command line" >&2
    exit 1
  }
done

"${adb_command[@]}" shell am force-stop "$package" >/dev/null
"${adb_command[@]}" shell am set-debug-app --persistent "$package" >/dev/null
launch_attempted=true
[[ "$("${adb_command[@]}" shell settings get global debug_app | tr -d '\r')" == \
    "$package" &&
    "$("${adb_command[@]}" shell settings get global wait_for_debugger | tr -d '\r')" == 0 ]] || {
  echo "Android did not select only the admitted disposable debug app" >&2
  exit 1
}
"${adb_command[@]}" shell monkey -p "$package" \
  -c android.intent.category.LAUNCHER 1 >/dev/null

for ((attempt = 0; attempt < 100; attempt++)); do
  browser_pid=$(
    "${adb_command[@]}" shell pidof "$package" | tr -d '\r'
  )
  socket_count=$(
    "${adb_command[@]}" shell cat /proc/net/unix | tr -d '\r' |
      grep -Ec "[[:space:]]@${device_socket}$" || true
  )
  if [[ "$browser_pid" =~ ^[1-9][0-9]*$ && "$socket_count" -eq 1 ]]; then
    launch_ready=true
    break
  fi
  sleep 0.1
done
[[ "$launch_ready" == true ]] || {
  echo "disposable browser did not expose its exact DevTools socket" >&2
  exit 1
}

printf 'operation=launch\npackage=%s\napk_sha256=%s\ndevice_socket=%s\ncommand_line_sha256=%s\n' \
  "$package" "$installed_apk_sha256" "$device_socket" "$command_line_sha256"
if [[ -n "$fixture_receipt_sha256" ]]; then
  printf 'fixture_receipt_sha256=%s\nfixture_spki_sha256_base64=%s\n' \
    "$fixture_receipt_sha256" "$fixture_spki"
fi
