#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$repo_root/scripts/chromium/build-android-control-ci.sh"

[[ "$(grep -Fc 'prepare-android-source.sh" "$workspace"' "$builder")" -eq 1 ]]
grep -Fq 'ensure_bootstrap' \
  "$repo_root/scripts/chromium/prepare-android-source.sh"
grep -Fq 'git diff --quiet HEAD --' "$builder"
grep -Fq 'git diff --cached --quiet HEAD --' "$builder"
grep -Fq 'upstream-control' "$builder"
grep -Fq 'manifest_package=computer.helium.control.test' "$builder"
grep -Fq 'autoninja_jobs=${AUTONINJA_JOBS:-1}' "$builder"
grep -Fq 'gclient_jobs=${GCLIENT_JOBS:-1}' "$builder"
grep -Fq 'AUTONINJA_JOBS must remain 1' "$builder"
grep -Fq 'GCLIENT_JOBS must remain 1' "$builder"
grep -Fq 'cat "$repo_root/helium-chromium/flags.gn" > "$out_dir/args.gn"' "$builder"
grep -Fq 'cp "$repo_root/helium-chromium/flags.gn" "$provenance/flags.gn"' "$builder"
grep -Fq 'ffmpeg_branding = "Chrome"' "$builder"
grep -Fq 'proprietary_codecs = true' "$builder"
grep -Fq 'media_use_ffmpeg = true' "$builder"
grep -Fq 'is_debug = false' "$builder"
grep -Fq 'dcheck_always_on = false' "$builder"
grep -Fq 'debuggable_apks = true' "$builder"
grep -Fq 'out_dir/apks/ChromePublic.apk' "$builder"
grep -Fq 'ChromiumControl.apk' "$builder"
grep -Fq 'chromium-control-apk-arm64.tar.xz' "$builder"
grep -Fq 'run-device-probe.sh' "$builder"
grep -Fq 'verify-probe-pair.sh' "$builder"
grep -Fq 'disposable-browser.sh' "$builder"
grep -Fq 'schema_version=7' "$builder"
grep -Fq 'HELIUM_ANDROID_RUNTIME_KIT_ROOT' "$builder"
grep -Fq 'runtime_kit_commit' "$builder"
! grep -Fq 'show "$sync_commit:scripts/android-media/' "$builder"
grep -Fq 'prepare-cookie-acceptance-profile.sh' "$builder"
grep -Fq 'android_override_version_code' "$builder"
grep -Fq 'android_override_version_name' "$builder"
grep -Fq 'android-build-environment.sh" record' "$builder"
! grep -Fq 'apply-android-backbone.sh' "$builder"
! grep -Fq 'prepare_helium_dependencies' "$builder"
! grep -Fq 'git checkout FETCH_HEAD' "$builder"
! grep -Fq -- '--with_branch_heads' "$builder"
! grep -Fq -- '--with_tags' "$builder"

echo 'Android upstream control build contract passed'
