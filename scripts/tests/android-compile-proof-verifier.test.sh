#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-compile-verifier.XXXXXX")
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

commit=1111111111111111111111111111111111111111
target=chrome/browser/helium_sync:helium_sync
input="$test_root/input"
mkdir -p "$input/build-provenance"
cp "$repo_root/chromium/android-build.lock" \
  "$input/build-provenance/android-build.lock"
printf '%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT" \
  > "$input/build-provenance/chromium-source-commit.txt"
printf '%s\n' "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" \
  > "$input/build-provenance/depot-tools-commit.txt"
printf 'DEPOT_TOOLS_UPDATE=0\n' \
  > "$input/build-provenance/depot-tools-update-policy.txt"
printf '%s\n' "$commit" > "$input/build-provenance/helium-sync-commit.txt"
: > "$input/build-provenance/helium-sync-status.txt"
cat > "$input/build-provenance/gn-args-resolved.txt" <<'EOF'
ffmpeg_branding = "Chrome"
proprietary_codecs = true
target_cpu = "arm64"
target_os = "android"
EOF
(
  cd "$input/build-provenance"
  sha256sum android-build.lock chromium-source-commit.txt \
    depot-tools-commit.txt depot-tools-update-policy.txt \
    helium-sync-commit.txt helium-sync-status.txt gn-args-resolved.txt \
    > provenance.sha256
)
cat > "$input/compile-proof.env" <<EOF
schema_version=1
target=$target
target_cpu=arm64
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
completed_at=2026-07-22T00:00:00+00:00
EOF
tar -C "$input" -caf "$test_root/proof.tar.xz" .

"$repo_root/scripts/chromium/verify-android-compile-proof.sh" \
  "$test_root/proof.tar.xz" "$target" "$commit" > "$test_root/result.env"
grep -qx 'compile_proof=verified' "$test_root/result.env"

sed -i 's/proprietary_codecs = true/proprietary_codecs = false/' \
  "$input/build-provenance/gn-args-resolved.txt"
tar -C "$input" -caf "$test_root/tampered.tar.xz" .
if "$repo_root/scripts/chromium/verify-android-compile-proof.sh" \
  "$test_root/tampered.tar.xz" "$target" "$commit" >/dev/null 2>&1; then
  echo 'tampered compile provenance unexpectedly passed' >&2
  exit 1
fi

echo 'Android compile proof verifier passed'
