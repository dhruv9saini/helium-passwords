#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$repo_root/scripts/chromium/build-android-control-ci.sh"

[[ "$(grep -Fc 'prepare-android-source.sh" "$workspace"' "$builder")" -eq 1 ]]
grep -Fq 'git diff --quiet HEAD --' "$builder"
grep -Fq 'git diff --cached --quiet HEAD --' "$builder"
grep -Fq 'upstream-control' "$builder"
grep -Fq 'manifest_package=computer.helium.control.test' "$builder"
grep -Fq 'AUTONINJA_JOBS must remain 2' "$builder"
grep -Fq 'GCLIENT_JOBS must remain 2' "$builder"
grep -Fq 'ffmpeg_branding = "Chrome"' "$builder"
grep -Fq 'proprietary_codecs = true' "$builder"
grep -Fq 'media_use_ffmpeg = true' "$builder"
grep -Fq 'out_dir/apks/ChromePublic.apk' "$builder"
grep -Fq 'ChromiumControl.apk' "$builder"
grep -Fq 'chromium-control-apk-arm64.tar.xz' "$builder"
grep -Fq 'run-device-probe.sh' "$builder"
grep -Fq 'schema_version=2' "$builder"
! grep -Fq 'apply-android-backbone.sh' "$builder"
! grep -Fq 'prepare_helium_dependencies' "$builder"
! grep -Fq 'git checkout FETCH_HEAD' "$builder"
! grep -Fq -- '--with_branch_heads' "$builder"
! grep -Fq -- '--with_tags' "$builder"

echo 'Android upstream control build contract passed'
