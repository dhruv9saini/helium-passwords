#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d /tmp/helium-android-artifact-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

commit=1111111111111111111111111111111111111111
mkdir -p "$test_root/input/build-provenance" "$test_root/input/out"
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

if AAPT2="$test_root/aapt2" \
  "$repo_root/scripts/chromium/verify-android-artifact.sh" \
  "$test_root/artifact.tar.xz" computer.helium.sync "$commit" \
  > /dev/null 2>&1; then
  echo "mismatched package unexpectedly passed" >&2
  exit 1
fi

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
