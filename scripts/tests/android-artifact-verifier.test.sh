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
printf '%s\n' "$commit" > "$test_root/input/build-provenance/helium-sync-commit.txt"
: > "$test_root/input/build-provenance/helium-sync-status.txt"
printf '%s\n' 'chrome_public_manifest_package = "computer.helium.sync.test"' \
  > "$test_root/input/build-provenance/gn-args-resolved.txt"
: > "$test_root/input/out/HeliumSync.apk"
(
  cd "$test_root/input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)

cat > "$test_root/input/runtime-acceptance/fixture-server.mjs" <<'EOF'
#!/usr/bin/env node
EOF
cat > "$test_root/input/runtime-acceptance/run-cdp-probe.mjs" <<'EOF'
#!/usr/bin/env node
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
chmod +x "$test_root/input/runtime-acceptance/"{fixture-server.mjs,run-cdp-probe.mjs,generate-fixtures.sh}
cat > "$test_root/input/runtime-acceptance/kit.env" <<EOF
schema_version=1
probe_schema_version=1
helium_sync_commit=$commit
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
manifest_package=computer.helium.sync.test
target_cpu=arm64
artifact_target=chrome_public_apk
EOF
(
  cd "$test_root/input/runtime-acceptance"
  sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs kit.env \
    > SHA256SUMS
)
tar -C "$test_root/input" -caf "$test_root/artifact.tar.xz" .

cat > "$test_root/aapt2" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == dump && "$2" == packagename && -f "$3" ]]
printf '%s\n' computer.helium.sync.test
EOF
chmod +x "$test_root/aapt2"

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync.test "$commit" \
  > "$test_root/result"
grep -qx 'package=computer.helium.sync.test' "$test_root/result"
grep -qx "helium_sync_commit=$commit" "$test_root/result"
grep -Eq '^apk_sha256=[0-9a-f]{64}$' "$test_root/result"
grep -Eq '^runtime_kit_sha256=[0-9a-f]{64}$' "$test_root/result"

AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/artifact.tar.xz" "$commit" "$test_root/prepared" \
  > "$test_root/prepared-result"
grep -qx 'package=computer.helium.sync.test' "$test_root/prepared/acceptance.env"
grep -qx "helium_sync_commit=$commit" "$test_root/prepared/acceptance.env"
[[ -f "$test_root/prepared/HeliumSync-test.apk" ]]
[[ -f "$test_root/prepared/media/h264-aac.mp4" ]]
[[ -f "$test_root/prepared/media/h264-aac-fragmented.mp4" ]]
[[ -f "$test_root/prepared/media/vp9-opus.webm" ]]
(
  cd "$test_root/prepared"
  sha256sum -c PACKAGE_SHA256SUMS
)
if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/android-media/prepare-disposable-acceptance.sh" \
  "$test_root/artifact.tar.xz" "$commit" "$test_root/prepared" \
  > /dev/null 2>&1; then
  echo "existing disposable acceptance directory was unexpectedly overwritten" >&2
  exit 1
fi

if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync "$commit" \
  > /dev/null 2>&1; then
  echo "mismatched package unexpectedly passed" >&2
  exit 1
fi

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
