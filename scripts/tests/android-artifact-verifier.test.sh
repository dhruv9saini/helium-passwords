#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d /tmp/helium-android-artifact-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

commit=1111111111111111111111111111111111111111
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
{
  printf '%s\n' 'chrome_public_manifest_package = "computer.helium.sync.test"'
  printf 'android_override_version_code = "%s"\n' "$HELIUM_ANDROID_VERSION_CODE"
  printf 'android_override_version_name = "%s"\n' "$HELIUM_ANDROID_VERSION_NAME"
} > "$test_root/input/build-provenance/gn-args-resolved.txt"
: > "$test_root/input/out/HeliumSync.apk"
(
  cd "$test_root/input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)

cat > "$test_root/input/runtime-acceptance/fixture-server.mjs" <<'EOF'
#!/usr/bin/env node
EOF
cat > "$test_root/input/runtime-acceptance/run-cdp-probe.mjs" <<'EOF'
#!/usr/bin/env node
EOF
cat > "$test_root/input/runtime-acceptance/run-device-probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
cat > "$test_root/input/runtime-acceptance/generate-fixtures.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$1"
printf 'synthetic mp4\n' > "$1/h264-aac.mp4"
printf 'synthetic fragmented mp4\n' > "$1/h264-aac-fragmented.mp4"
printf 'synthetic webm\n' > "$1/vp9-opus.webm"
(
  cd "$1"
  sha256sum h264-aac.mp4 h264-aac-fragmented.mp4 vp9-opus.webm > SHA256SUMS
  printf '{}\n' > h264-aac.ffprobe.json
  printf '{}\n' > vp9-opus.ffprobe.json
  printf 'synthetic ffmpeg\n' > FFMPEG_VERSION
)
EOF
chmod +x "$test_root/input/runtime-acceptance/"{fixture-server.mjs,run-cdp-probe.mjs,run-device-probe.sh,generate-fixtures.sh}
cat > "$test_root/input/runtime-acceptance/kit.env" <<EOF
schema_version=3
probe_schema_version=1
helium_sync_commit=$commit
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
    run-device-probe.sh kit.env > SHA256SUMS
)
tar -C "$test_root/input" -caf "$test_root/artifact.tar.xz" .

cat > "$test_root/aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && -f "$3" ]]
case "$2" in
  packagename) printf '%s\n' computer.helium.sync.test ;;
  badging) printf "package: name='computer.helium.sync.test' versionCode='787500005' versionName='150.0.7871.181'\n" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/aapt2"

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  > "$test_root/result"
grep -qx 'package=computer.helium.sync.test' "$test_root/result"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" "$test_root/result"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" "$test_root/result"
grep -qx "helium_sync_commit=$commit" "$test_root/result"
grep -Eq '^apk_sha256=[0-9a-f]{64}$' "$test_root/result"
grep -Eq '^runtime_kit_sha256=[0-9a-f]{64}$' "$test_root/result"

cp -a "$test_root/input" "$test_root/foreign-lock-input"
sed -i 's/HELIUM_ANDROID_VERSION_CODE=787500005/HELIUM_ANDROID_VERSION_CODE=787500006/' \
  "$test_root/foreign-lock-input/build-provenance/android-build.lock"
(
  cd "$test_root/foreign-lock-input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)
tar -C "$test_root/foreign-lock-input" -caf "$test_root/foreign-lock.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/foreign-lock.tar.xz" computer.helium.sync.test "$commit" \
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
(
  cd "$test_root/control-input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    chromium-source-status.txt depot-tools-commit.txt \
    depot-tools-update-policy.txt helium-sync-commit.txt \
    helium-sync-status.txt gn-args-resolved.txt android-composition.txt \
    > provenance.sha256
)
(
  cd "$test_root/control-input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
    run-device-probe.sh kit.env > SHA256SUMS
)
tar -C "$test_root/control-input" -caf "$test_root/control-artifact.tar.xz" .
cat > "$test_root/control-aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && -f "$3" ]]
case "$2" in
  packagename) printf '%s\n' computer.helium.control.test ;;
  badging) printf "package: name='computer.helium.control.test' versionCode='787500005' versionName='150.0.7871.181'\n" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/control-aapt2"
AAPT2="$test_root/control-aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/control-artifact.tar.xz" computer.helium.control.test "$commit" \
  > "$test_root/control-result"
grep -qx 'package=computer.helium.control.test' "$test_root/control-result"
AAPT2="$test_root/control-aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/control-artifact.tar.xz" computer.helium.control.test "$commit" \
  "$test_root/control-prepared" > "$test_root/control-prepared-result"
grep -qx 'package=computer.helium.control.test' \
  "$test_root/control-prepared/acceptance.env"
[[ -f "$test_root/control-prepared/Browser-test.apk" ]]

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  "$test_root/prepared" \
  > "$test_root/prepared-result"
grep -qx 'package=computer.helium.sync.test' "$test_root/prepared/acceptance.env"
grep -qx "helium_sync_commit=$commit" "$test_root/prepared/acceptance.env"
grep -qx "version_code=$HELIUM_ANDROID_VERSION_CODE" "$test_root/prepared/acceptance.env"
grep -qx "version_name=$HELIUM_ANDROID_VERSION_NAME" "$test_root/prepared/acceptance.env"
[[ -f "$test_root/prepared/Browser-test.apk" ]]
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
  > /dev/null 2>&1; then
  echo "stale APK versionCode unexpectedly passed" >&2
  exit 1
fi

if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync "$commit" \
  > /dev/null 2>&1; then
  echo "mismatched package unexpectedly passed" >&2
  exit 1
fi

printf '%s\n' 2222222222222222222222222222222222222222 \
  > "$test_root/input/build-provenance/depot-tools-commit.txt"
(
  cd "$test_root/input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)
tar -C "$test_root/input" -caf "$test_root/mutated-depot.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/mutated-depot.tar.xz" computer.helium.sync.test "$commit" \
  > /dev/null 2>&1; then
  echo "mutated depot_tools provenance unexpectedly passed" >&2
  exit 1
fi
printf '%s\n' "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  > "$test_root/input/build-provenance/depot-tools-commit.txt"
(
  cd "$test_root/input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)

printf 'tampered\n' >> "$test_root/input/runtime-acceptance/fixture-server.mjs"
tar -C "$test_root/input" -caf "$test_root/tampered-runtime.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/tampered-runtime.tar.xz" computer.helium.sync.test "$commit" \
  > /dev/null 2>&1; then
  echo "tampered runtime acceptance kit unexpectedly passed" >&2
  exit 1
fi
cat > "$test_root/input/runtime-acceptance/fixture-server.mjs" <<'EOF'
#!/usr/bin/env node
EOF

printf 'dirty\n' > "$test_root/input/build-provenance/helium-sync-status.txt"
(
  cd "$test_root/input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)
tar -C "$test_root/input" -caf "$test_root/dirty.tar.xz" .
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/dirty.tar.xz" computer.helium.sync.test "$commit" \
  > /dev/null 2>&1; then
  echo "dirty source provenance unexpectedly passed" >&2
  exit 1
fi

echo 'android_artifact_verifier=passed'
