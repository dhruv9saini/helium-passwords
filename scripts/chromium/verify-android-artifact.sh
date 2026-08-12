#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-runtime-kit.lock
. "$repo_root/chromium/android-runtime-kit.lock"
[[ "$HELIUM_ANDROID_RUNTIME_KIT_SCHEMA" == 1 &&
    "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" =~ ^[0-9a-f]{40}$ &&
    "$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "invalid Android runtime-kit lock" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  echo "usage: $0 ARCHIVE EXPECTED_PACKAGE EXPECTED_HELIUM_SYNC_COMMIT EXPECTED_RUNTIME_KIT_COMMIT" >&2
  exit 64
fi

archive=$(realpath "$1")
expected_package=$2
expected_sync_commit=$3
expected_runtime_kit_commit=$4
aapt2=${AAPT2:-aapt2}

case "$expected_package" in
  computer.helium.passwords|computer.helium.passwords.test)
    expected_apk=HeliumSync.apk
    ;;
  computer.helium.control.test)
    expected_apk=ChromiumControl.apk
    ;;
  *) echo "invalid expected Android package" >&2; exit 64 ;;
esac
[[ "$expected_sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected Helium Sync commit must be a full SHA-1" >&2
  exit 64
}
[[ "$expected_runtime_kit_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected Android runtime-kit commit must be a full SHA-1" >&2
  exit 64
}
[[ "$expected_runtime_kit_commit" == "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" ]] || {
  echo "expected Android runtime-kit commit does not match its lock" >&2
  exit 1
}
git -C "$repo_root" cat-file -e "$expected_runtime_kit_commit^{commit}"
git -C "$repo_root" merge-base --is-ancestor "$expected_runtime_kit_commit" HEAD || {
  echo "expected Android runtime-kit commit is not in current history" >&2
  exit 1
}
command -v "$aapt2" >/dev/null

temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-artifact.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT

while IFS= read -r entry; do
  case "$entry" in
    /*|..|../*|*/../*|*/..) echo "unsafe archive path: $entry" >&2; exit 1 ;;
  esac
done < <(tar -tf "$archive")
tar -xf "$archive" -C "$temporary"

provenance="$temporary/build-provenance"
[[ -d "$provenance" ]] || { echo "missing build provenance" >&2; exit 1; }
(
  cd "$provenance"
  sha256sum -c provenance.sha256
)
expected_provenance_inventory=$(find "$provenance" -maxdepth 1 -type f \
  ! -name provenance.sha256 -printf '%f\n' | sort)
recorded_provenance_inventory=$(sed -n 's/^[0-9a-f]\{64\}  //p' \
  "$provenance/provenance.sha256" | sort)
[[ "$recorded_provenance_inventory" == "$expected_provenance_inventory" ]] || {
  echo "build provenance checksum inventory is incomplete or unexpected" >&2
  exit 1
}
"$repo_root/scripts/chromium/android-build-environment.sh" verify "$provenance"

tooling="$provenance/android-tooling.env"
[[ -f "$tooling" && ! -L "$tooling" ]] || {
  echo "artifact is missing regular Android tooling provenance" >&2
  exit 1
}
metadata() {
  local name=$1 file=$2 value
  value=$(sed -n "s/^${name}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${name}=" "$file")" -eq 1 ]] || {
    echo "$file is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}
tooling_commit=$(metadata tooling_commit "$tooling")
[[ "$tooling_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "artifact Android tooling commit is invalid" >&2
  exit 1
}
git -C "$repo_root" cat-file -e "$tooling_commit^{commit}"
git -C "$repo_root" merge-base --is-ancestor "$tooling_commit" HEAD || {
  echo "artifact Android tooling commit is not in the current source history" >&2
  exit 1
}
verify_tooling_source() {
  local source_key=$1 hash_key=$2 expected_source=$3
  local source recorded_hash expected_hash
  source=$(metadata "$source_key" "$tooling")
  recorded_hash=$(metadata "$hash_key" "$tooling")
  [[ "$source" == "$expected_source" && "$recorded_hash" =~ ^[0-9a-f]{64}$ ]] || {
    echo "artifact Android tooling identity is invalid: $expected_source" >&2
    exit 1
  }
  expected_hash=$(git -C "$repo_root" show "$tooling_commit:$expected_source" | sha256sum | cut -d' ' -f1)
  [[ "$recorded_hash" == "$expected_hash" ]] || {
    echo "artifact Android tooling hash does not match its commit: $expected_source" >&2
    exit 1
  }
}
verify_tooling_source locked_gn_verifier_source locked_gn_verifier_sha256 \
  scripts/chromium/verify-android-locked-gn-args.sh

flags_gn="$provenance/flags.gn"
args_gn="$provenance/args.gn"
locked_gn_args="$provenance/locked-gn-args-resolved.txt"
[[ -f "$flags_gn" && ! -L "$flags_gn" &&
    -f "$args_gn" && ! -L "$args_gn" &&
    -f "$locked_gn_args" && ! -L "$locked_gn_args" ]] || {
  echo "artifact is missing regular locked GN provenance" >&2
  exit 1
}
cmp -s "$flags_gn" "$repo_root/helium-chromium/flags.gn" || {
  echo "artifact flags.gn does not match the locked Helium core flags" >&2
  exit 1
}
locked_check=$(mktemp "$temporary/.locked-gn-args.XXXXXX")
rm -f "$locked_check"
"$repo_root/scripts/chromium/verify-android-locked-gn-args.sh" \
  "$flags_gn" "$args_gn" "$provenance/gn-args-resolved.txt" \
  "$locked_check" >/dev/null
cmp -s "$locked_check" "$locked_gn_args" || {
  echo "artifact effective locked GN values do not match its verified provenance" >&2
  exit 1
}
rm -f "$locked_check"

cmp -s "$provenance/android-build.lock" "$repo_root/chromium/android-build.lock" || {
  echo "artifact Android build lock does not match the repository lock" >&2
  exit 1
}
"$repo_root/scripts/chromium/validate-android-build-lock.sh" >/dev/null
# Source only the repository-owned lock. Artifact metadata is never executable.
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"

if [[ "$expected_package" == computer.helium.control.test ]]; then
  [[ "$(metadata schema_version "$tooling")" == 1 && \
      "$(cut -d= -f1 "$tooling" | sort)" == \
      $'build_driver_sha256\nbuild_driver_source\nlocked_gn_verifier_sha256\nlocked_gn_verifier_source\nruntime_kit_commit\nruntime_kit_source_sha256\nruntime_kit_verifier_sha256\nruntime_kit_verifier_source\nschema_version\ntooling_commit' ]] || {
    echo "control artifact has an unexpected Android tooling inventory" >&2
    exit 1
  }
  verify_tooling_source build_driver_source build_driver_sha256 \
    scripts/chromium/build-android-control-ci.sh
  verify_tooling_source runtime_kit_verifier_source runtime_kit_verifier_sha256 \
    scripts/chromium/verify-android-runtime-kit-source.sh
  grep -Eq '(^|[/[:space:]])build-android-control-ci\.sh([[:space:]]|$)' \
    "$provenance/build-command.txt" || {
    echo "control artifact build command does not name the control builder" >&2
    exit 1
  }
  grep -qx 'upstream-control' "$provenance/android-composition.txt" || {
    echo "control artifact is missing its no-patch composition proof" >&2
    exit 1
  }
  [[ ! -s "$provenance/chromium-source-status.txt" ]] || {
    echo "control Chromium source has tracked modifications" >&2
    exit 1
  }
  for forbidden in helium-core-commit.txt android-composition.tsv \
    android-composition.sha256 sync-inputs.sha256; do
    [[ ! -e "$provenance/$forbidden" ]] || {
      echo "control artifact carries patched Sync composition provenance" >&2
      exit 1
    }
  done
else
  [[ "$(metadata schema_version "$tooling")" == 1 && \
      "$(cut -d= -f1 "$tooling" | sort)" == \
      $'build_driver_sha256\nbuild_driver_source\nlocked_gn_verifier_sha256\nlocked_gn_verifier_source\nmedia_config_verifier_sha256\nmedia_config_verifier_source\nruntime_kit_commit\nruntime_kit_source_sha256\nruntime_kit_verifier_sha256\nruntime_kit_verifier_source\nschema_version\ntooling_commit' ]] || {
    echo "Sync artifact has an unexpected Android tooling inventory" >&2
    exit 1
  }
  verify_tooling_source build_driver_source build_driver_sha256 \
    scripts/chromium/build-android-ci.sh
  verify_tooling_source media_config_verifier_source \
    media_config_verifier_sha256 \
    scripts/chromium/verify-android-media-config.sh
  verify_tooling_source runtime_kit_verifier_source runtime_kit_verifier_sha256 \
    scripts/chromium/verify-android-runtime-kit-source.sh
  grep -Eq '(^|[/[:space:]])build-android-ci\.sh([[:space:]]|$)' \
    "$provenance/build-command.txt" || {
    echo "Sync artifact build command does not name the Sync builder" >&2
    exit 1
  }
  for required in helium-core-commit.txt android-composition.tsv \
    android-composition.sha256 sync-inputs.sha256; do
    [[ -f "$provenance/$required" && ! -L "$provenance/$required" ]] || {
      echo "Sync artifact is missing $required" >&2
      exit 1
    }
  done
  [[ "$(tr -d '\r\n' < "$provenance/helium-core-commit.txt")" == \
    "$HELIUM_ANDROID_CORE_COMMIT" ]] || {
    echo "Sync artifact Helium core does not match the build lock" >&2
    exit 1
  }
  for layer in core passwords sync; do
    grep -q "^${layer}"$'\t' "$provenance/android-composition.tsv" || {
      echo "Sync artifact composition is missing the $layer layer" >&2
      exit 1
    }
  done
fi
[[ "$(metadata runtime_kit_commit "$tooling")" == \
    "$expected_runtime_kit_commit" ]] || {
  echo "artifact Android tooling names the wrong runtime-kit commit" >&2
  exit 1
}
runtime_kit_source_sha256=$(metadata runtime_kit_source_sha256 "$tooling")
[[ "$runtime_kit_source_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "artifact Android tooling has an invalid runtime-kit source hash" >&2
  exit 1
}
[[ "$runtime_kit_source_sha256" == \
    "$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" ]] || {
  echo "artifact Android runtime-kit source hash does not match its lock" >&2
  exit 1
}
[[ "$(tr -d '\r\n' < "$provenance/chromium-source-commit.txt")" == \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]] || {
  echo "artifact Chromium commit does not match its lock" >&2
  exit 1
}
[[ "$(tr -d '\r\n' < "$provenance/depot-tools-commit.txt")" == \
  "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" ]] || {
  echo "artifact depot_tools commit does not match its lock" >&2
  exit 1
}
grep -qx 'DEPOT_TOOLS_UPDATE=0' \
  "$provenance/depot-tools-update-policy.txt" || {
  echo "artifact depot_tools update policy is not pinned" >&2
  exit 1
}
[[ "$(tr -d '\r\n' < "$provenance/helium-sync-commit.txt")" == \
  "$expected_sync_commit" ]] || {
  echo "artifact Helium Sync commit does not match the requested source" >&2
  exit 1
}
[[ ! -s "$provenance/helium-sync-status.txt" ]] || {
  echo "artifact was built from a dirty tracked source tree" >&2
  exit 1
}
grep -qx "chrome_public_manifest_package = \"$expected_package\"" \
  "$provenance/gn-args-resolved.txt" || {
  echo "artifact GN package does not match the expected package" >&2
  exit 1
}
grep -qx "android_override_version_code = \"$HELIUM_ANDROID_VERSION_CODE\"" \
  "$provenance/gn-args-resolved.txt" || {
  echo "artifact GN versionCode does not match the build lock" >&2
  exit 1
}
grep -qx "android_override_version_name = \"$HELIUM_ANDROID_VERSION_NAME\"" \
  "$provenance/gn-args-resolved.txt" || {
  echo "artifact GN versionName does not match the build lock" >&2
  exit 1
}
grep -qx 'is_debug = false' "$provenance/gn-args-resolved.txt" || {
  echo "APK was not built as a non-debug browser" >&2
  exit 1
}
grep -qx 'dcheck_always_on = false' "$provenance/gn-args-resolved.txt" || {
  echo "APK enables always-on DCHECKs" >&2
  exit 1
}
case "$expected_package" in
  computer.helium.passwords)
    expected_debuggable=false
    ;;
  computer.helium.passwords.test|computer.helium.control.test)
    expected_debuggable=true
    ;;
esac
grep -qx "debuggable_apks = $expected_debuggable" \
  "$provenance/gn-args-resolved.txt" || {
  echo "APK debuggability does not match its production or disposable role" >&2
  exit 1
}
for required_arg in \
  'target_os = "android"' \
  'target_cpu = "arm64"' \
  'ffmpeg_branding = "Chrome"' \
  'proprietary_codecs = true' \
  'media_use_ffmpeg = true'; do
  grep -Fqx "$required_arg" "$provenance/gn-args-resolved.txt" || {
    echo "APK is missing required GN provenance: $required_arg" >&2
    exit 1
  }
done

runtime_kit="$temporary/runtime-acceptance"
[[ -d "$runtime_kit" ]] || { echo "missing Android runtime acceptance kit" >&2; exit 1; }
for kit_file in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
  disposable-browser.sh prepare-cookie-acceptance-profile.sh \
  run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh \
  kit.env SHA256SUMS; do
  [[ -f "$runtime_kit/$kit_file" && ! -L "$runtime_kit/$kit_file" ]] || {
    echo "runtime acceptance kit is missing $kit_file" >&2
    exit 1
  }
done
[[ "$(find "$runtime_kit" -mindepth 1 -maxdepth 1 | wc -l)" -eq 10 ]] || {
  echo "runtime acceptance kit contains an unexpected file inventory" >&2
  exit 1
}
[[ "$(wc -l < "$runtime_kit/SHA256SUMS")" -eq 9 ]] || {
  echo "runtime acceptance kit checksum inventory is invalid" >&2
  exit 1
}
for checked_file in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
  disposable-browser.sh prepare-cookie-acceptance-profile.sh \
  run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh kit.env; do
  grep -Eq "^[0-9a-f]{64}  ${checked_file}$" "$runtime_kit/SHA256SUMS" || {
    echo "runtime acceptance kit checksum inventory is missing $checked_file" >&2
    exit 1
  }
done
(
  cd "$runtime_kit"
  sha256sum -c SHA256SUMS
)
[[ "$(wc -l < "$runtime_kit/kit.env")" -eq 11 ]] || {
  echo "runtime acceptance kit metadata inventory is invalid" >&2
  exit 1
}
grep -qx 'schema_version=7' "$runtime_kit/kit.env"
grep -qx 'probe_schema_version=1' "$runtime_kit/kit.env"
grep -qx "helium_sync_commit=$expected_sync_commit" "$runtime_kit/kit.env"
grep -qx "runtime_kit_commit=$expected_runtime_kit_commit" "$runtime_kit/kit.env"
grep -qx "runtime_kit_source_sha256=$runtime_kit_source_sha256" \
  "$runtime_kit/kit.env"
grep -qx "chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT" "$runtime_kit/kit.env"
grep -qx "manifest_package=$expected_package" "$runtime_kit/kit.env"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" "$runtime_kit/kit.env"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" "$runtime_kit/kit.env"
grep -qx 'target_cpu=arm64' "$runtime_kit/kit.env"
grep -qx 'artifact_target=chrome_public_apk' "$runtime_kit/kit.env"

for kit_file in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
  disposable-browser.sh prepare-cookie-acceptance-profile.sh \
  run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh; do
  git -C "$repo_root" show \
    "$expected_runtime_kit_commit:scripts/android-media/$kit_file" \
    | cmp -s - "$runtime_kit/$kit_file" || {
    echo "runtime acceptance kit file does not match its named commit: $kit_file" >&2
    exit 1
  }
done

mapfile -d '' apks < <(find "$temporary" -type f -name "$expected_apk" -print0)
[[ ${#apks[@]} -eq 1 ]] || {
  echo "artifact must contain exactly one $expected_apk" >&2
  exit 1
}
manifest_package=$($aapt2 dump packagename "${apks[0]}")
[[ "$manifest_package" == "$expected_package" ]] || {
  echo "APK manifest package does not match GN provenance" >&2
  exit 1
}
badging=$($aapt2 dump badging "${apks[0]}")
[[ "$(grep -c '^package:' <<<"$badging")" -eq 1 ]] || {
  echo "APK badging does not contain one package record" >&2
  exit 1
}
package_record=$(grep '^package:' <<<"$badging")
apk_version_code=$(sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" <<<"$package_record")
apk_version_name=$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$package_record")
apk_debuggable=false
if grep -qx 'application-debuggable' <<<"$badging"; then
  apk_debuggable=true
fi
[[ "$apk_debuggable" == "$expected_debuggable" ]] || {
  echo "APK manifest debuggability does not match GN provenance" >&2
  exit 1
}
[[ "$apk_version_code" == "$HELIUM_ANDROID_VERSION_CODE" ]] || {
  echo "APK versionCode does not match the build lock" >&2
  exit 1
}
[[ "$apk_version_name" == "$HELIUM_ANDROID_VERSION_NAME" ]] || {
  echo "APK versionName does not match the build lock" >&2
  exit 1
}

printf 'archive_sha256=%s\n' "$(sha256sum "$archive" | cut -d' ' -f1)"
printf 'package=%s\n' "$manifest_package"
printf 'version_code=%s\n' "$apk_version_code"
printf 'version_name=%s\n' "$apk_version_name"
printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
printf 'helium_sync_commit=%s\n' "$expected_sync_commit"
printf 'runtime_kit_commit=%s\n' "$expected_runtime_kit_commit"
printf 'runtime_kit_source_sha256=%s\n' "$runtime_kit_source_sha256"
printf 'apk_path=%s\n' "${apks[0]#$temporary/}"
printf 'apk_sha256=%s\n' "$(sha256sum "${apks[0]}" | cut -d' ' -f1)"
printf 'runtime_kit_sha256=%s\n' "$(sha256sum "$runtime_kit/SHA256SUMS" | cut -d' ' -f1)"
