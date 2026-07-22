#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d /tmp/helium-android-media-config.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/src/out/Test" "$test_root/bin" "$test_root/provenance"
printf 'target_os = "android"\n' > "$test_root/src/out/Test/args.gn"
git -C "$test_root/src" init -q
git -C "$test_root/src" config user.email test@helium.invalid
git -C "$test_root/src" config user.name 'Helium Test'
git -C "$test_root/src" add out/Test/args.gn
git -C "$test_root/src" commit -qm initial

cat > "$test_root/bin/gn" <<'EOF'
#!/usr/bin/env bash
cat <<'ARGS'
ffmpeg_branding = "Chrome"
media_use_ffmpeg = true
proprietary_codecs = true
target_cpu = "arm64"
target_os = "android"
ARGS
EOF
chmod +x "$test_root/bin/gn"
cat > "$test_root/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *helium-chromium*' rev-parse HEAD') printf '%s\\n' '$HELIUM_ANDROID_CORE_COMMIT' ;;
  *"$test_root/src"*' rev-parse HEAD') printf '%s\\n' '$HELIUM_ANDROID_CHROMIUM_COMMIT' ;;
  *' rev-parse HEAD') printf '%040d\\n' 1 ;;
  *' status '*) exit 0 ;;
  *) echo "unexpected fake git invocation: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/git"

PATH="$test_root/bin:$PATH" GN="$test_root/bin/gn" \
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
  "$test_root/src" out/Test "$test_root/provenance" "$repo_root" \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT"

grep -qx 'proprietary_codecs = true' "$test_root/provenance/gn-args-resolved.txt"
grep -Eq '^[0-9a-f]{40}$' "$test_root/provenance/chromium-source-commit.txt"
grep -q 'chromium/patches/0001-helium-sync-overlay-files.patch' \
  "$test_root/provenance/sync-inputs.sha256"

sed -i 's/proprietary_codecs = true/proprietary_codecs = false/' "$test_root/bin/gn"
if PATH="$test_root/bin:$PATH" GN="$test_root/bin/gn" \
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
  "$test_root/src" out/Test "$test_root/rejected" "$repo_root" \
  "$HELIUM_ANDROID_CHROMIUM_COMMIT" 2>/dev/null; then
  echo 'codec-stripped Android configuration unexpectedly passed' >&2
  exit 1
fi

grep -Fq 'find "$PWD" -mindepth 2 -name .git' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'verify-android-media-config.sh' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'cp -a "$artifact_dir/build-provenance" "$staging/"' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'CHROMIUM_ANDROID_PROVENANCE_ONLY:-false' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'github_workspace=$(realpath -m "$GITHUB_WORKSPACE")' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'compile-proof.env' "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'compile-${artifact_target}-${target_cpu}.tar.xz' \
  "$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'status --short --untracked-files=no' \
  "$repo_root/scripts/chromium/verify-android-media-config.sh"
! grep -Fq 'status --short --untracked-files=all' \
  "$repo_root/scripts/chromium/verify-android-media-config.sh"

echo 'Android media build configuration contract passed'
