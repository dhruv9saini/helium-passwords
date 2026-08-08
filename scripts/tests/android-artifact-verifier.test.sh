#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
# shellcheck source=../../chromium/android-runtime-kit.lock
. "$repo_root/chromium/android-runtime-kit.lock"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-artifact-test.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT
nix_source_sha256=$(sha256sum "$repo_root/chromium/nix/chromiumer-shell.nix" | awk '{ print $1 }')

commit=1111111111111111111111111111111111111111
tooling_commit=$(git -C "$repo_root" rev-parse HEAD)
checksum_provenance() {
  local directory=$1
  (
    cd "$directory"
    find . -maxdepth 1 -type f ! -name provenance.sha256 -printf '%P\0' \
      | sort -z | xargs -0 sha256sum > provenance.sha256
  )
}
mkdir -p "$test_root/input/build-provenance" "$test_root/input/out" \
  "$test_root/input/runtime-acceptance"
cp "$repo_root/chromium/android-build.lock" \
  "$test_root/input/build-provenance/android-build.lock"
printf '%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT" \
  > "$test_root/input/build-provenance/chromium-source-commit.txt"
printf '%s\n' "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  > "$test_root/input/build-provenance/depot-tools-commit.txt"
printf '%s\n' 'DEPOT_TOOLS_UPDATE=0' \
  > "$test_root/input/build-provenance/depot-tools-update-policy.txt"
printf '%s\n' "$commit" > "$test_root/input/build-provenance/helium-sync-commit.txt"
: > "$test_root/input/build-provenance/helium-sync-status.txt"
printf '%s\n' "$HELIUM_ANDROID_CORE_COMMIT" \
  > "$test_root/input/build-provenance/helium-core-commit.txt"
printf 'core\tcore.patch\npasswords\tpasswords.patch\nsync\tsync.patch\n' \
  > "$test_root/input/build-provenance/android-composition.tsv"
printf 'synthetic composition hashes\n' \
  > "$test_root/input/build-provenance/android-composition.sha256"
printf 'synthetic Sync input hashes\n' \
  > "$test_root/input/build-provenance/sync-inputs.sha256"
cat > "$test_root/input/build-provenance/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/00000000000000000000000000000000-helium-chromium-150-env
closure_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
closure_bytes=10737418240
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
nixpkgs_commit=$HELIUM_ANDROID_NIXPKGS_COMMIT
nix_version=nix (Nix) 2.33.0
environment_source_sha256=$nix_source_sha256
nix_derivation=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-helium-chromium-150-env.drv
grit_disable_multiprocessing=1
root_start_available_bytes=139586437120
root_end_available_bytes=118111600640
realise_consumed_bytes=21474836480
realise_budget_bytes=21474836480
post_realise_floor_bytes=107374182400
realise_start_gate_bytes=128849018880
EOF
printf 'bash scripts/chromium/build-android-ci.sh \n' \
  > "$test_root/input/build-provenance/build-command.txt"
cp "$repo_root/helium-chromium/flags.gn" \
  "$test_root/input/build-provenance/flags.gn"
{
  cat "$repo_root/helium-chromium/flags.gn"
  printf '%s\n' 'target_os = "android"' 'target_cpu = "arm64"'
} > "$test_root/input/build-provenance/args.gn"
{
  sed 's/=/ = /' "$repo_root/helium-chromium/flags.gn"
  printf '%s\n' 'chrome_public_manifest_package = "computer.helium.sync.test"'
  printf 'android_override_version_code = "%s"\n' "$HELIUM_ANDROID_VERSION_CODE"
  printf 'android_override_version_name = "%s"\n' "$HELIUM_ANDROID_VERSION_NAME"
  printf '%s\n' 'is_debug = false' 'dcheck_always_on = false' \
    'debuggable_apks = true'
  printf '%s\n' 'target_os = "android"' 'target_cpu = "arm64"' \
    'ffmpeg_branding = "Chrome"' 'proprietary_codecs = true' \
    'media_use_ffmpeg = true'
} > "$test_root/input/build-provenance/gn-args-resolved.txt"
"$repo_root/scripts/chromium/verify-android-locked-gn-args.sh" \
  "$test_root/input/build-provenance/flags.gn" \
  "$test_root/input/build-provenance/args.gn" \
  "$test_root/input/build-provenance/gn-args-resolved.txt" \
  "$test_root/input/build-provenance/locked-gn-args-resolved.txt" >/dev/null
cat > "$test_root/input/build-provenance/android-tooling.env" <<EOF
schema_version=1
tooling_commit=$tooling_commit
build_driver_source=scripts/chromium/build-android-ci.sh
build_driver_sha256=$(sha256sum "$repo_root/scripts/chromium/build-android-ci.sh" | cut -d' ' -f1)
media_config_verifier_source=scripts/chromium/verify-android-media-config.sh
media_config_verifier_sha256=$(sha256sum "$repo_root/scripts/chromium/verify-android-media-config.sh" | cut -d' ' -f1)
locked_gn_verifier_source=scripts/chromium/verify-android-locked-gn-args.sh
locked_gn_verifier_sha256=$(sha256sum "$repo_root/scripts/chromium/verify-android-locked-gn-args.sh" | cut -d' ' -f1)
runtime_kit_commit=$HELIUM_ANDROID_RUNTIME_KIT_COMMIT
runtime_kit_source_sha256=$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256
runtime_kit_verifier_source=scripts/chromium/verify-android-runtime-kit-source.sh
runtime_kit_verifier_sha256=$(sha256sum "$repo_root/scripts/chromium/verify-android-runtime-kit-source.sh" | cut -d' ' -f1)
EOF
: > "$test_root/input/out/HeliumSync.apk"
checksum_provenance "$test_root/input/build-provenance"

for source in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
  disposable-browser.sh prepare-cookie-acceptance-profile.sh \
  run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh; do
  git -C "$repo_root" show \
    "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT:scripts/android-media/$source" \
    > "$test_root/input/runtime-acceptance/$source"
done
chmod +x "$test_root/input/runtime-acceptance/"{fixture-server.mjs,run-cdp-probe.mjs,disposable-browser.sh,prepare-cookie-acceptance-profile.sh,run-device-probe.sh,verify-probe-pair.sh,generate-fixtures.sh}
cat > "$test_root/input/runtime-acceptance/kit.env" <<EOF
schema_version=7
probe_schema_version=1
helium_sync_commit=$commit
runtime_kit_commit=$HELIUM_ANDROID_RUNTIME_KIT_COMMIT
runtime_kit_source_sha256=$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
manifest_package=computer.helium.sync.test
version_code=$HELIUM_ANDROID_VERSION_CODE
version_name=$HELIUM_ANDROID_VERSION_NAME
target_cpu=arm64
artifact_target=chrome_public_apk
EOF
(
  cd "$test_root/input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh \
    kit.env > SHA256SUMS
)
tar -C "$test_root/input" -caf "$test_root/artifact.tar.xz" .

cat > "$test_root/aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && -f "$3" ]]
case "$2" in
  packagename) printf '%s\n' computer.helium.sync.test ;;
  badging) printf "package: name='computer.helium.sync.test' versionCode='787500005' versionName='150.0.7871.181'\napplication-debuggable\n" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/aapt2"

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > "$test_root/result"
grep -qx 'package=computer.helium.sync.test' "$test_root/result"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" "$test_root/result"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" "$test_root/result"
grep -qx "helium_sync_commit=$commit" "$test_root/result"
grep -qx "runtime_kit_commit=$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" "$test_root/result"
grep -qx "runtime_kit_source_sha256=$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256" \
  "$test_root/result"
grep -Eq '^apk_sha256=[0-9a-f]{64}$' "$test_root/result"
grep -Eq '^runtime_kit_sha256=[0-9a-f]{64}$' "$test_root/result"

cp -a "$test_root/input" "$test_root/missing-boundary-input"
find "$test_root/missing-boundary-input/runtime-acceptance/disposable-browser.sh" \
  -delete
(
  cd "$test_root/missing-boundary-input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    prepare-cookie-acceptance-profile.sh run-device-probe.sh \
    audit-probe-pair.mjs verify-probe-pair.sh kit.env > SHA256SUMS
)
tar -C "$test_root/missing-boundary-input" \
  -caf "$test_root/missing-boundary-artifact.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/missing-boundary-artifact.tar.xz" \
  computer.helium.sync.test "$commit" "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "Android artifact without its disposable boundary unexpectedly passed" >&2
  exit 1
fi

cp -a "$test_root/input" "$test_root/production-input"
sed -i \
  -e 's/computer\.helium\.sync\.test/computer.helium.sync/' \
  -e 's/debuggable_apks = true/debuggable_apks = false/' \
  "$test_root/production-input/build-provenance/gn-args-resolved.txt"
sed -i 's/computer\.helium\.sync\.test/computer.helium.sync/' \
  "$test_root/production-input/runtime-acceptance/kit.env"
checksum_provenance "$test_root/production-input/build-provenance"
(
  cd "$test_root/production-input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh \
    kit.env > SHA256SUMS
)
tar -C "$test_root/production-input" -caf "$test_root/production-artifact.tar.xz" .
cat > "$test_root/production-aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && -f "$3" ]]
case "$2" in
  packagename) printf '%s\n' computer.helium.sync ;;
  badging) printf "package: name='computer.helium.sync' versionCode='787500005' versionName='150.0.7871.181'\n" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/production-aapt2"
AAPT2="$test_root/production-aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/production-artifact.tar.xz" computer.helium.sync "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > "$test_root/production-result"
grep -qx 'package=computer.helium.sync' "$test_root/production-result"
sed '/badging)/s/\\n"/\\napplication-debuggable\\n"/' \
  "$test_root/production-aapt2" > "$test_root/debuggable-production-aapt2"
chmod +x "$test_root/debuggable-production-aapt2"
if AAPT2="$test_root/debuggable-production-aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/production-artifact.tar.xz" computer.helium.sync "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "debuggable production Android manifest unexpectedly passed" >&2
  exit 1
fi

cp -a "$test_root/input" "$test_root/foreign-lock-input"
sed -i 's/HELIUM_ANDROID_VERSION_CODE=787500005/HELIUM_ANDROID_VERSION_CODE=787500006/' \
  "$test_root/foreign-lock-input/build-provenance/android-build.lock"
checksum_provenance "$test_root/foreign-lock-input/build-provenance"
tar -C "$test_root/foreign-lock-input" -caf "$test_root/foreign-lock.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/foreign-lock.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "self-consistent foreign Android build lock unexpectedly passed" >&2
  exit 1
fi

cp -a "$test_root/input" "$test_root/control-input"
find "$test_root/control-input/out/HeliumSync.apk" -delete
: > "$test_root/control-input/out/ChromiumControl.apk"
sed -i 's/computer\.helium\.sync\.test/computer.helium.control.test/' \
  "$test_root/control-input/build-provenance/gn-args-resolved.txt" \
  "$test_root/control-input/runtime-acceptance/kit.env"
: > "$test_root/control-input/build-provenance/chromium-source-status.txt"
printf 'upstream-control\n' \
  > "$test_root/control-input/build-provenance/android-composition.txt"
find "$test_root/control-input/build-provenance" -maxdepth 1 -type f \
  \( -name helium-core-commit.txt -o -name android-composition.tsv \
     -o -name android-composition.sha256 -o -name sync-inputs.sha256 \) -delete
printf 'bash scripts/chromium/build-android-control-ci.sh \n' \
  > "$test_root/control-input/build-provenance/build-command.txt"
cat > "$test_root/control-input/build-provenance/android-tooling.env" <<EOF
schema_version=1
tooling_commit=$tooling_commit
build_driver_source=scripts/chromium/build-android-control-ci.sh
build_driver_sha256=$(sha256sum "$repo_root/scripts/chromium/build-android-control-ci.sh" | cut -d' ' -f1)
locked_gn_verifier_source=scripts/chromium/verify-android-locked-gn-args.sh
locked_gn_verifier_sha256=$(sha256sum "$repo_root/scripts/chromium/verify-android-locked-gn-args.sh" | cut -d' ' -f1)
runtime_kit_commit=$HELIUM_ANDROID_RUNTIME_KIT_COMMIT
runtime_kit_source_sha256=$HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256
runtime_kit_verifier_source=scripts/chromium/verify-android-runtime-kit-source.sh
runtime_kit_verifier_sha256=$(sha256sum "$repo_root/scripts/chromium/verify-android-runtime-kit-source.sh" | cut -d' ' -f1)
EOF
checksum_provenance "$test_root/control-input/build-provenance"
(
  cd "$test_root/control-input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    disposable-browser.sh prepare-cookie-acceptance-profile.sh \
    run-device-probe.sh audit-probe-pair.mjs verify-probe-pair.sh \
    kit.env > SHA256SUMS
)
tar -C "$test_root/control-input" -caf "$test_root/control-artifact.tar.xz" .
cat > "$test_root/control-aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && -f "$3" ]]
case "$2" in
  packagename) printf '%s\n' computer.helium.control.test ;;
  badging) printf "package: name='computer.helium.control.test' versionCode='787500005' versionName='150.0.7871.181'\napplication-debuggable\n" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/control-aapt2"
AAPT2="$test_root/control-aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/control-artifact.tar.xz" computer.helium.control.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > "$test_root/control-result"
grep -qx 'package=computer.helium.control.test' "$test_root/control-result"
AAPT2="$test_root/control-aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/control-artifact.tar.xz" computer.helium.control.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  "$test_root/control-prepared" > "$test_root/control-prepared-result"
grep -qx 'package=computer.helium.control.test' \
  "$test_root/control-prepared/acceptance.env"
[[ -f "$test_root/control-prepared/Browser-test.apk" ]]
[[ -x "$test_root/control-prepared/runtime-acceptance/disposable-browser.sh" ]]

cp -a "$test_root/input" "$test_root/foreign-flags-input"
printf 'enable_mdns=true\n' \
  >> "$test_root/foreign-flags-input/build-provenance/flags.gn"
checksum_provenance "$test_root/foreign-flags-input/build-provenance"
tar -C "$test_root/foreign-flags-input" -caf "$test_root/foreign-flags.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/foreign-flags.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "Android artifact with foreign flags.gn unexpectedly passed" >&2
  exit 1
fi

cp -a "$test_root/input" "$test_root/reassigned-flags-input"
printf 'enable_mdns = true\n' \
  >> "$test_root/reassigned-flags-input/build-provenance/args.gn"
checksum_provenance "$test_root/reassigned-flags-input/build-provenance"
tar -C "$test_root/reassigned-flags-input" \
  -caf "$test_root/reassigned-flags.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/reassigned-flags.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "Android artifact with a locked-key args.gn reassignment unexpectedly passed" >&2
  exit 1
fi

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  "$test_root/prepared" \
  > "$test_root/prepared-result"
grep -qx 'package=computer.helium.sync.test' "$test_root/prepared/acceptance.env"
grep -qx "helium_sync_commit=$commit" "$test_root/prepared/acceptance.env"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" "$test_root/prepared/acceptance.env"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" "$test_root/prepared/acceptance.env"
[[ -f "$test_root/prepared/Browser-test.apk" ]]
[[ -x "$test_root/prepared/runtime-acceptance/disposable-browser.sh" ]]
[[ -f "$test_root/prepared/media/h264-aac.mp4" ]]
[[ -f "$test_root/prepared/media/h264-aac-fragmented.mp4" ]]
[[ -f "$test_root/prepared/media/vp9-opus.webm" ]]
(
  cd "$test_root/prepared"
  sha256sum -c PACKAGE_SHA256SUMS
)
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  "$test_root/prepared" \
  > /dev/null 2>&1; then
  echo "existing disposable acceptance directory was unexpectedly overwritten" >&2
  exit 1
fi

sed 's/versionCode=\x27787500005\x27/versionCode=\x27787500004\x27/' \
  "$test_root/aapt2" > "$test_root/stale-version-aapt2"
chmod +x "$test_root/stale-version-aapt2"
if AAPT2="$test_root/stale-version-aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "stale APK versionCode unexpectedly passed" >&2
  exit 1
fi

if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "mismatched package unexpectedly passed" >&2
  exit 1
fi

printf '%s\n' 2222222222222222222222222222222222222222 \
  > "$test_root/input/build-provenance/depot-tools-commit.txt"
checksum_provenance "$test_root/input/build-provenance"
tar -C "$test_root/input" -caf "$test_root/mutated-depot.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/mutated-depot.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "mutated depot_tools provenance unexpectedly passed" >&2
  exit 1
fi
printf '%s\n' "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  > "$test_root/input/build-provenance/depot-tools-commit.txt"
checksum_provenance "$test_root/input/build-provenance"

printf 'tampered\n' >> "$test_root/input/runtime-acceptance/fixture-server.mjs"
tar -C "$test_root/input" -caf "$test_root/tampered-runtime.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/tampered-runtime.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "tampered runtime acceptance kit unexpectedly passed" >&2
  exit 1
fi
git -C "$repo_root" show \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT:scripts/android-media/fixture-server.mjs" \
  > "$test_root/input/runtime-acceptance/fixture-server.mjs"

printf 'dirty\n' > "$test_root/input/build-provenance/helium-sync-status.txt"
checksum_provenance "$test_root/input/build-provenance"
tar -C "$test_root/input" -caf "$test_root/dirty.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/dirty.tar.xz" computer.helium.sync.test "$commit" \
  "$HELIUM_ANDROID_RUNTIME_KIT_COMMIT" \
  > /dev/null 2>&1; then
  echo "dirty source provenance unexpectedly passed" >&2
  exit 1
fi

echo 'android_artifact_verifier=passed'
