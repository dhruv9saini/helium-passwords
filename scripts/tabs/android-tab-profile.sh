#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  android-tab-profile.sh stage ACCEPTANCE_DIRECTORY ADB_SERIAL \
    native|neutral|full-profile LOCAL_DRILL_PROFILE
  android-tab-profile.sh fetch-neutral ACCEPTANCE_DIRECTORY ADB_SERIAL \
    neutral LOCAL_DRILL_PROFILE
  android-tab-profile.sh remove ACCEPTANCE_DIRECTORY ADB_SERIAL \
    native|neutral|full-profile LOCAL_DRILL_PROFILE

Operate only on an exact checksum-admitted computer.helium.sync.test package.
The native profile is the fresh package's app_chrome tree so the existing
stopped Android full-profile producer can back it up. Neutral and full-profile
drills use new fixed package-private user-data roots. No package is cleared or
uninstalled.
EOF
}

[[ $# -eq 5 ]] || { usage; exit 64; }
operation=$1
acceptance_input=$2
serial=$3
mode=$4
profile_input=$5
package=computer.helium.sync.test

case "$operation" in stage|fetch-neutral|remove) ;; *) usage; exit 64 ;; esac
case "$mode" in native|neutral|full-profile) ;; *) usage; exit 64 ;; esac
[[ "$operation" != fetch-neutral || "$mode" == neutral ]] || {
  echo "fetch-neutral requires neutral mode" >&2
  exit 64
}
[[ "$serial" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "ADB serial contains unsupported characters" >&2
  exit 64
}
for tool in adb diff find grep head install jq mv readlink realpath rm sed \
  sha256sum sync tar tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

[[ -d "$acceptance_input" && ! -L "$acceptance_input" ]] || {
  echo "acceptance directory must be a real directory" >&2
  exit 1
}
acceptance=$(realpath -e -- "$acceptance_input")
[[ "$profile_input" == /* &&
    "$(realpath -ms -- "$profile_input")" == "$profile_input" ]] || {
  echo "local tab profile path must be absolute and lexically normalized" >&2
  exit 1
}
parent=$(dirname -- "$profile_input")
[[ -d "$parent" && ! -L "$parent" &&
    "$(realpath -e -- "$parent")" == "$parent" ]] || {
  echo "local tab profile parent must be a real resolved directory" >&2
  exit 1
}
[[ -d "$profile_input" && ! -L "$profile_input" &&
    "$(realpath -e -- "$profile_input")" == "$profile_input" ]] || {
  echo "local tab profile must be a real resolved directory" >&2
  exit 1
}
profile=$profile_input
[[ -f "$acceptance/acceptance.env" &&
    ! -L "$acceptance/acceptance.env" &&
    -f "$acceptance/PACKAGE_SHA256SUMS" &&
    ! -L "$acceptance/PACKAGE_SHA256SUMS" ]] || {
  echo "acceptance directory is incomplete or unsafe" >&2
  exit 1
}
(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS >/dev/null)
[[ "$(sed -n 's/^package=//p' "$acceptance/acceptance.env")" == "$package" &&
    "$(grep -c '^package=' "$acceptance/acceptance.env")" -eq 1 ]] || {
  echo "tab profile adapter admits only computer.helium.sync.test" >&2
  exit 1
}
[[ -d "$profile" && ! -L "$profile" &&
    "$(basename "$profile")" =~ ^drill-[a-z0-9][a-z0-9._-]{0,57}$ ]] || {
  echo "local tab profile must be a real drill-* directory" >&2
  exit 1
}
[[ -z "$(find "$profile" ! -type d ! -type f ! -type l -print -quit)" ]] || {
  echo "local tab profile contains a special filesystem entry" >&2
  exit 1
}
while IFS= read -r -d '' link; do
  target=$(readlink "$link")
  [[ "$target" != /* && "/$target/" != *"/../"* ]] || {
    echo "local tab profile contains an escaping symlink" >&2
    exit 1
  }
done < <(find "$profile" -type l -print0)

case "$mode" in
  native)
    expected_parent_marker=.helium-tab-runtime-proof-root-v1
    expected_parent_content=helium-tab-runtime-proof-root-v1
    binding_file=.helium-tab-runtime-native-profile-v1
    [[ -f "$profile/$binding_file" && ! -L "$profile/$binding_file" &&
        "$(<"$profile/$binding_file")" == \
        helium-tab-runtime-native-profile-v1 ]] || {
      echo "native tab profile marker is invalid" >&2
      exit 1
    }
    ;;
  neutral)
    expected_parent_marker=.helium-tabs-disposable-root-v1
    expected_parent_content=helium-tabs-disposable-root-v1
    binding_file=.helium-tabs-disposable-browser-profile-v2
    [[ -f "$profile/$binding_file" && ! -L "$profile/$binding_file" &&
        "$(<"$profile/$binding_file")" == \
        helium-tabs-disposable-browser-profile-v2 ]] || {
      echo "neutral tab profile marker is invalid" >&2
      exit 1
    }
    ;;
  full-profile)
    expected_parent_marker=.helium-disposable-profile-restore-root
    expected_parent_content=
    binding_file=.helium-profile-restore-receipt.env
    [[ -f "$profile/$binding_file" && ! -L "$profile/$binding_file" ]] || {
      echo "full-profile restore receipt is missing or unsafe" >&2
      exit 1
    }
    ;;
esac
[[ -f "$parent/$expected_parent_marker" &&
    ! -L "$parent/$expected_parent_marker" &&
    "$(<"$parent/$expected_parent_marker")" == "$expected_parent_content" ]] || {
  echo "local tab profile parent marker is invalid" >&2
  exit 1
}
local_binding_sha256=$(sha256sum "$profile/$binding_file" | cut -d' ' -f1)

profile_fingerprint() {
  local directory=$1
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --format=posix --pax-option=delete=atime,delete=ctime \
    -C "$directory" -cf - . | sha256sum | cut -d' ' -f1
}
local_profile_sha256=$(profile_fingerprint "$profile")

adb_command=(adb -s "$serial")
[[ "$("${adb_command[@]}" get-state | tr -d '\r')" == device ]] || {
  echo "ADB target is not in device state" >&2
  exit 1
}
mapfile -t package_paths < <(
  "${adb_command[@]}" shell pm path "$package" | tr -d '\r'
)
[[ ${#package_paths[@]} -eq 1 &&
    "${package_paths[0]}" == package:/data/app/*/base.apk ]] || {
  echo "disposable Sync package is not one monolithic installed APK" >&2
  exit 1
}
installed_apk=${package_paths[0]#package:}
expected_apk_sha=$(sed -n 's/^apk_sha256=//p' "$acceptance/acceptance.env")
[[ "$expected_apk_sha" =~ ^[0-9a-f]{64}$ &&
    "$("${adb_command[@]}" exec-out cat "$installed_apk" |
      sha256sum | cut -d' ' -f1)" == "$expected_apk_sha" ]] || {
  echo "installed disposable APK does not match the acceptance generation" >&2
  exit 1
}
package_dump=$("${adb_command[@]}" shell dumpsys package "$package" | tr -d '\r')
data_dir=$(sed -n 's/^[[:space:]]*dataDir=//p' <<<"$package_dump" | head -n 1)
[[ "$data_dir" == "/data/user/0/$package" ||
    "$data_dir" == "/data/data/$package" ]] || {
  echo "installed disposable package has an unexpected dataDir" >&2
  exit 1
}
resolved_data_dir=$(
  "${adb_command[@]}" exec-out run-as "$package" /system/bin/readlink -f \
    "$data_dir" | tr -d '\r'
)
[[ "$resolved_data_dir" == "/data/user/0/$package" ]] || {
  echo "disposable package dataDir does not resolve to its exact sandbox" >&2
  exit 1
}
data_dir=$resolved_data_dir

slug=$(basename "$profile")
if [[ "$mode" == native ]]; then
  device_parent=$data_dir
  device_profile=$data_dir/app_chrome
else
  device_parent=$data_dir/helium-tab-runtime-$mode
  device_profile=$device_parent/$slug
fi

"${adb_command[@]}" shell am force-stop "$package" >/dev/null
[[ -z "$("${adb_command[@]}" shell pidof "$package" | tr -d '\r')" ]] || {
  echo "disposable package did not stop before profile operation" >&2
  exit 1
}

case "$operation" in
  stage)
    device_created=false
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-tab-profile.XXXXXX")
    cleanup_stage() {
      local result=$?
      if [[ "$result" -ne 0 && "$device_created" == true ]]; then
        "${adb_command[@]}" exec-out run-as "$package" sh -c \
          "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test -d '$device_profile' && test ! -L '$device_profile' && test \"\$(readlink -f '$device_profile')\" = '$device_profile' && rm -rf -- '$device_profile'" \
          >/dev/null 2>&1 || true
      fi
      find "$temporary" -depth -delete
      return "$result"
    }
    trap cleanup_stage EXIT
    if [[ "$mode" == native ]]; then
      "${adb_command[@]}" exec-out run-as "$package" sh -c \
        "umask 077; test -d '$device_parent'; test ! -L '$device_parent'; test \"\$(readlink -f '$device_parent')\" = '$device_parent'; test ! -e '$device_profile'; test ! -L '$device_profile'; mkdir '$device_profile'; chmod 700 '$device_profile'" \
        >/dev/null || {
        echo "fresh disposable package already has an app_chrome profile" >&2
        exit 1
      }
    else
      parent_state=$("${adb_command[@]}" exec-out run-as "$package" sh -c \
        "umask 077; if test -e '$device_parent' || test -L '$device_parent'; then test -d '$device_parent'; test ! -L '$device_parent'; test \"\$(readlink -f '$device_parent')\" = '$device_parent'; printf existing; else mkdir '$device_parent'; chmod 700 '$device_parent'; printf created; fi" | tr -d '\r') || {
        echo "device tab profile parent is unsafe" >&2
        exit 1
      }
      [[ "$parent_state" == existing || "$parent_state" == created ]] || {
        echo "device tab profile parent state is invalid" >&2
        exit 1
      }
      if [[ "$mode" == neutral && "$parent_state" == existing ]]; then
        "${adb_command[@]}" exec-out run-as "$package" sh -c \
          "test -f '$device_parent/.helium-tabs-disposable-root-v1'; test ! -L '$device_parent/.helium-tabs-disposable-root-v1'; test \"\$(cat '$device_parent/.helium-tabs-disposable-root-v1')\" = helium-tabs-disposable-root-v1" \
          >/dev/null || {
          echo "existing neutral device parent marker is invalid" >&2
          exit 1
        }
      fi
      if [[ "$mode" == neutral && "$parent_state" == created ]]; then
        "${adb_command[@]}" exec-out run-as "$package" sh -c \
          "umask 077; printf 'helium-tabs-disposable-root-v1\n' > '$device_parent/.helium-tabs-disposable-root-v1'" \
          >/dev/null
      fi
      "${adb_command[@]}" exec-out run-as "$package" sh -c \
        "umask 077; test -d '$device_parent'; test ! -L '$device_parent'; test \"\$(readlink -f '$device_parent')\" = '$device_parent'; test ! -e '$device_profile'; test ! -L '$device_profile'; mkdir '$device_profile'; chmod 700 '$device_profile'" \
        >/dev/null || {
        echo "device tab profile target already exists or is unsafe" >&2
        exit 1
      }
    fi
    device_created=true
    tar -C "$profile" -cf - . |
      "${adb_command[@]}" exec-out run-as "$package" sh -c \
        "cd '$device_profile' && /system/bin/tar -xf -"
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test -d '$device_profile' && test ! -L '$device_profile' && test \"\$(readlink -f '$device_profile')\" = '$device_profile' && test -d '$device_profile/Default' && test ! -L '$device_profile/Default'" \
      >/dev/null || {
      echo "staged Android tab profile is incomplete or unsafe" >&2
      exit 1
    }
    device_binding_sha256=$(
      "${adb_command[@]}" exec-out run-as "$package" cat \
        "$device_profile/$binding_file" | sha256sum | cut -d' ' -f1
    )
    [[ "$device_binding_sha256" == "$local_binding_sha256" ]] || {
      echo "staged Android marker or receipt does not match its local source" >&2
      exit 1
    }
    mkdir -m 700 "$temporary/$slug"
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "cd '$device_profile' && /system/bin/tar -cf - ." |
      tar -xf - -C "$temporary/$slug"
    diff -qr --no-dereference "$profile" "$temporary/$slug" >/dev/null || {
      echo "staged Android tab profile does not match its local source" >&2
      exit 1
    }
    [[ "$(profile_fingerprint "$temporary/$slug")" == "$local_profile_sha256" ]] || {
      echo "staged Android tab profile fingerprint does not match" >&2
      exit 1
    }
    printf 'operation=stage\npackage=%s\nmode=%s\nlocal_profile=%s\n' \
      "$package" "$mode" "$profile"
    printf 'device_profile=%s\napk_sha256=%s\nprofile_tree_sha256=%s\n' \
      "$device_profile" "$expected_apk_sha" "$local_profile_sha256"
    printf 'binding_sha256=%s\n' "$local_binding_sha256"
    ;;
  fetch-neutral)
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-tab-fetch.XXXXXX")
    local_receipt_temporary=
    cleanup_fetch() {
      local result=$?
      [[ -z "$local_receipt_temporary" ]] ||
        rm -f -- "$local_receipt_temporary"
      find "$temporary" -depth -delete
      return "$result"
    }
    trap cleanup_fetch EXIT
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test -d '$device_profile' && test ! -L '$device_profile' && test \"\$(readlink -f '$device_profile')\" = '$device_profile' && test -f '$device_profile/.helium-tabs-restore-consumed-v2' && test ! -L '$device_profile/.helium-tabs-restore-consumed-v2' && test -f '$device_profile/.helium-tabs-restore-receipt-v2.json' && test ! -L '$device_profile/.helium-tabs-restore-receipt-v2.json'" \
      >/dev/null || {
      echo "Android neutral profile has no safe consumed state" >&2
      exit 1
    }
    "${adb_command[@]}" exec-out run-as "$package" cat \
      "$device_profile/.helium-tabs-restore-consumed-v2" \
      >"$temporary/consumed"
    "${adb_command[@]}" exec-out run-as "$package" cat \
      "$device_profile/.helium-tabs-restore-receipt-v2.json" \
      >"$temporary/receipt.json"
    [[ "$(<"$temporary/consumed")" == helium-tabs-restore-state-v2 ]] || {
      echo "Android neutral consumed marker is invalid" >&2
      exit 1
    }
    jq -e '
      (keys | sort) == ([
        "completed_at_unix_millis", "error", "group_count",
        "readback_validation", "schema_version", "source_device",
        "source_generation", "source_profile", "source_session_sha256",
        "state", "tab_count", "window_count"
      ] | sort) and
      .schema_version == 2 and .state == "applied" and
      .source_device == "oneplus" and
      (.source_generation | type == "string" and length > 0) and
      (.source_profile | type == "string" and length > 0) and
      (.source_session_sha256 | test("^[0-9a-f]{64}$")) and
      (.window_count | type == "number") and
      (.tab_count | type == "number") and
      (.group_count | type == "number") and
      .readback_validation == "exact-supported-live-topology" and
      (.completed_at_unix_millis | test("^[0-9]+$")) and .error == ""
    ' "$temporary/receipt.json" >/dev/null || {
      echo "Android neutral native receipt is invalid" >&2
      exit 1
    }
    prepared=$profile/.helium-tabs-restore-prepared-v2
    consumed=$profile/.helium-tabs-restore-consumed-v2
    local_receipt=$profile/.helium-tabs-restore-receipt-v2.json
    [[ -f "$prepared" && ! -L "$prepared" &&
        "$(<"$prepared")" == helium-tabs-restore-state-v2 &&
        ! -e "$consumed" && ! -L "$consumed" &&
        ! -e "$local_receipt" && ! -L "$local_receipt" ]] || {
      echo "local neutral profile is not in its exact prepared state" >&2
      exit 1
    }
    local_receipt_temporary=$profile/.android-neutral-receipt.$$.tmp
    install -m 0600 "$temporary/receipt.json" "$local_receipt_temporary"
    mv -T "$local_receipt_temporary" "$local_receipt"
    local_receipt_temporary=
    if ! mv -T "$prepared" "$consumed"; then
      rm -f -- "$local_receipt"
      exit 1
    fi
    sync -f "$profile"
    printf 'operation=fetch-neutral\npackage=%s\nmode=neutral\n' "$package"
    printf 'local_profile=%s\ndevice_profile=%s\n' "$profile" "$device_profile"
    printf 'native_receipt_sha256=%s\n' \
      "$(sha256sum "$local_receipt" | cut -d' ' -f1)"
    ;;
  remove)
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test -d '$device_profile' && test ! -L '$device_profile' && test \"\$(readlink -f '$device_profile')\" = '$device_profile' && test -f '$device_profile/$binding_file' && test ! -L '$device_profile/$binding_file'" \
      >/dev/null || {
      echo "refusing to remove an unmarked Android tab profile" >&2
      exit 1
    }
    device_binding_sha256=$(
      "${adb_command[@]}" exec-out run-as "$package" cat \
        "$device_profile/$binding_file" | sha256sum | cut -d' ' -f1
    )
    [[ "$device_binding_sha256" == "$local_binding_sha256" ]] || {
      echo "refusing to remove an Android profile with a different binding" >&2
      exit 1
    }
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test -d '$device_profile' && test ! -L '$device_profile' && test \"\$(readlink -f '$device_profile')\" = '$device_profile' && rm -rf -- '$device_profile'" \
      >/dev/null
    "${adb_command[@]}" exec-out run-as "$package" sh -c \
      "test -d '$device_parent' && test ! -L '$device_parent' && test \"\$(readlink -f '$device_parent')\" = '$device_parent' && test ! -e '$device_profile' && test ! -L '$device_profile'" \
      >/dev/null || {
      echo "Android tab profile removal did not complete" >&2
      exit 1
    }
    printf 'operation=remove\npackage=%s\nmode=%s\ndevice_profile=%s\n' \
      "$package" "$mode" "$device_profile"
    printf 'binding_sha256=%s\n' "$local_binding_sha256"
    ;;
esac
