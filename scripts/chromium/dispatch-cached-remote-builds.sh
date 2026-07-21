#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: dispatch-cached-remote-builds.sh [desktop|linux|android|both]

Dispatch Helium Sync builds on GitHub Actions. This does not build Chromium
locally.

Environment overrides:
  HELIUM_SYNC_GITHUB_REPO             GitHub repo to dispatch in (default: dhruv9saini/helium-sync)
  HELIUM_SYNC_REF                     helium-sync workflow ref (default: main)
  CHROMIUM_RUNNER                     Actions runner label (default: ubuntu-24.04)
  BUILD_TIMEOUT_MINUTES               soft build timeout (default: 300)
  CCACHE_MAX_SIZE                     ccache max size (default: 5G)
  BUILD_STATE_CACHE                   restore/save out/Default cache (default: true)

Desktop inputs:
  HELIUM_PLATFORM                     Desktop platform (default: linux)
  HELIUM_ARCH                         Desktop arch (default: x86_64)
  HELIUM_PLATFORM_REF                 Helium platform repo ref (default: main)

Android inputs:
  CHROMIUM_URL                        Chromium source URL
  CHROMIUM_REF                        Chromium ref. Default pins the current saved Android build-state cache.
  CHROMIUM_TARGET                     Android GN target (default: chrome_public_apk)
  TARGET_CPU                          Android target CPU (default: arm64)
  ALLOW_LEGACY_ANDROID_BUILD_STATE_CACHE
                                       one-time restore from pre-source-SHA Android state cache (default: true)
USAGE
}

target=${1:-both}
case "$target" in
  desktop|linux|android|both) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 64
    ;;
esac

repo=${HELIUM_SYNC_GITHUB_REPO:-dhruv9saini/helium-sync}
workflow_ref=${HELIUM_SYNC_REF:-main}
runner=${CHROMIUM_RUNNER:-ubuntu-24.04}
timeout_minutes=${BUILD_TIMEOUT_MINUTES:-300}
ccache_max_size=${CCACHE_MAX_SIZE:-5G}
build_state_cache=${BUILD_STATE_CACHE:-true}

dispatch_desktop() {
  local platform="${HELIUM_PLATFORM:-linux}"
  if [ "$target" = "linux" ]; then
    platform=linux
  fi

  gh workflow run build.yml \
    --repo "$repo" \
    --ref "$workflow_ref" \
    -f platform="$platform" \
    -f arch="${HELIUM_ARCH:-x86_64}" \
    -f platform-ref="${HELIUM_PLATFORM_REF:-main}" \
    -f run-build=true \
    -f create-release=false
}

dispatch_android() {
  gh workflow run chromium-android.yml \
    --repo "$repo" \
    --ref "$workflow_ref" \
    -f runner="$runner" \
    -f build_timeout_minutes="$timeout_minutes" \
    -f ccache_max_size="$ccache_max_size" \
    -f build_state_cache="$build_state_cache" \
    -f allow_legacy_build_state_cache="${ALLOW_LEGACY_ANDROID_BUILD_STATE_CACHE:-true}" \
    -f chromium_url="${CHROMIUM_URL:-https://chromium.googlesource.com/chromium/src.git}" \
    -f chromium_ref="${CHROMIUM_REF:-3fdd848305cc4c7a7cf1775e295b2d31054d19d3}" \
    -f target="${CHROMIUM_TARGET:-chrome_public_apk}" \
    -f target_cpu="${TARGET_CPU:-arm64}"
}

case "$target" in
  desktop|linux)
    dispatch_desktop
    ;;
  android)
    dispatch_android
    ;;
  both)
    dispatch_desktop
    dispatch_android
    ;;
esac
