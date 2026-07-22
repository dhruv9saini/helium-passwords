#!/usr/bin/env bash
set -euxo pipefail

repo_root=${HELIUM_SYNC_REPO:-"$GITHUB_WORKSPACE/helium-sync"}
repo_root=$(cd "$repo_root" && pwd)
github_workspace=$(realpath -m "$GITHUB_WORKSPACE")
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
workspace=${CHROMIUM_WORKSPACE:-"$github_workspace/chromium-android"}
workspace=$(realpath -m "$workspace")
requested_chromium_ref=${CHROMIUM_REF:-$HELIUM_ANDROID_CHROMIUM_COMMIT}
if [[ ! "$requested_chromium_ref" =~ ^[0-9a-f]{40}$ ]]; then
  echo "CHROMIUM_REF must be the immutable commit from chromium/android-build.lock" >&2
  exit 64
fi
if [[ "$requested_chromium_ref" != "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]]; then
  echo "CHROMIUM_REF does not match the shared Android backbone lock" >&2
  exit 64
fi
chromium_ref=$HELIUM_ANDROID_CHROMIUM_COMMIT
chromium_url=${CHROMIUM_URL:-https://chromium.googlesource.com/chromium/src.git}
target_cpu=${TARGET_CPU:-arm64}
target=${CHROMIUM_TARGET:-${TARGET:-chrome_public_apk}}
out_dir=${OUT_DIR:-out/Default}
autoninja_jobs=${AUTONINJA_JOBS:-2}
gclient_jobs=${GCLIENT_JOBS:-}
artifact_dir=${ARTIFACT_DIR:-"$github_workspace/android-artifacts"}
artifact_dir=$(realpath -m "$artifact_dir")
provenance_only=${CHROMIUM_ANDROID_PROVENANCE_ONLY:-false}
use_ccache=${USE_CCACHE:-true}
ccache_max_size=${CCACHE_MAXSIZE:-5G}
phase=${CHROMIUM_ANDROID_PHASE:-all}
touch_restored_out=${HELIUM_SYNC_TOUCH_RESTORED_OUT:-false}
skip_system_deps=${CHROMIUM_ANDROID_SKIP_SYSTEM_DEPS:-false}
android_ffmpeg_branding=${CHROMIUM_ANDROID_FFMPEG_BRANDING:-Chrome}
android_proprietary_codecs=${CHROMIUM_ANDROID_PROPRIETARY_CODECS:-true}
enable_desktop_extensions=${CHROMIUM_ANDROID_DESKTOP_EXTENSIONS:-false}
official_build=${CHROMIUM_ANDROID_OFFICIAL_BUILD:-false}
use_siso=${CHROMIUM_ANDROID_USE_SISO:-auto}
siso_gomemlimit=${CHROMIUM_ANDROID_SISO_GOMEMLIMIT:-1536MiB}
siso_flags=${CHROMIUM_ANDROID_SISO_FLAGS:-}
manifest_package=${CHROMIUM_ANDROID_MANIFEST_PACKAGE:-computer.helium.sync}

# Chromium bindgen treats TARGET as a Rust target triple env var and fails if the
# workflow-level target-name variable leaks into the build environment.
unset TARGET

if [[ "$enable_desktop_extensions" == true ]]; then
  echo "CHROMIUM_ANDROID_DESKTOP_EXTENSIONS is disabled for phone APK builds." >&2
  echo "Chromium marks desktop-Android extensions as experimental and unstable; use the chroot browser for extensions." >&2
  exit 64
fi

case "$official_build" in
  true|false) ;;
  *)
    echo "CHROMIUM_ANDROID_OFFICIAL_BUILD must be true or false" >&2
    exit 64
    ;;
esac

case "$provenance_only" in
  true|false) ;;
  *)
    echo "CHROMIUM_ANDROID_PROVENANCE_ONLY must be true or false" >&2
    exit 64
    ;;
esac

case "$use_siso" in
  auto|true|false) ;;
  *)
    echo "CHROMIUM_ANDROID_USE_SISO must be auto, true, or false" >&2
    exit 64
    ;;
esac

case "$manifest_package" in
  computer.helium.sync|computer.helium.sync.test) ;;
  *)
    echo "CHROMIUM_ANDROID_MANIFEST_PACKAGE must be computer.helium.sync or computer.helium.sync.test" >&2
    exit 64
    ;;
esac

setup_ccache() {
  if [[ "$use_ccache" != true ]]; then
    return 0
  fi
  command -v ccache >/dev/null
  export CCACHE_DIR=${CCACHE_DIR:-"$github_workspace/chromium-ccache/android-$target_cpu"}
  export CCACHE_COMPILERCHECK=${CCACHE_COMPILERCHECK:-content}
  export CCACHE_CPP2=${CCACHE_CPP2:-yes}
  export CCACHE_SLOPPINESS=${CCACHE_SLOPPINESS:-time_macros}
  mkdir -p "$CCACHE_DIR"
  ccache -M "$ccache_max_size"
  ccache -z || true
  ccache -s || true
}

setup_depot_tools() {
  mkdir -p "$workspace" "$artifact_dir"
  if [[ ! -d "$workspace/depot_tools/.git" ]]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$workspace/depot_tools"
  fi
  export PATH="$workspace/depot_tools:$PATH"
}

gclient_sync() {
  GCLIENT_JOBS="$gclient_jobs" \
    "$repo_root/scripts/chromium/gclient-sync-direct.sh" "$@"
}

prepare_helium_dependencies() {
  local download_cache="$workspace/helium-download-cache"
  mkdir -p "$download_cache"
  "$repo_root/helium-chromium/utils/downloads.py" retrieve \
    -i "$repo_root/helium-chromium/deps.ini" -c "$download_cache"
  "$repo_root/helium-chromium/utils/downloads.py" unpack \
    -i "$repo_root/helium-chromium/deps.ini" -c "$download_cache" "$workspace/src"
}

prepare_android_source() {
  df -h
  setup_depot_tools
  setup_ccache

  cd "$workspace"
  if [[ ! -f .gclient ]]; then
    cat > .gclient <<EOF
solutions = [
  {
    "name": "src",
    "url": "$chromium_url",
    "managed": False,
    "custom_deps": {
      "src/android_webview/tools/cts_archive/cipd": None,
      "src/third_party/robolectric/cipd": None,
    },
    "custom_vars": {
      "checkout_android": True,
      "checkout_configuration": "small",
      "checkout_js_coverage_modules": False,
      "checkout_openxr": False,
      "skip_wpr_archives_download": True,
    },
  },
]
target_os = ["android"]
EOF
  fi

  gclient_sync --nohooks --no-history

  cd src
  git fetch origin "$chromium_ref" --depth=1
  git checkout FETCH_HEAD
  [[ "$(git rev-parse HEAD)" == "$HELIUM_ANDROID_CHROMIUM_COMMIT" ]]
  cd "$workspace"
  gclient_sync --nohooks --no-history --with_branch_heads --with_tags
  df -h

  cd src
  if [[ "$skip_system_deps" == true ]]; then
    echo "Skipping Chromium system dependency installer"
  else
    build/install-build-deps.sh --android
  fi
  df -h
  gclient runhooks
  df -h

  prepare_helium_dependencies
  "$repo_root/scripts/chromium/apply-android-backbone.sh" apply "$PWD"
  generate_android_build_files
  # The workflow resolves and records the checked-out Chromium SHA after this
  # phase. Keep the root repository metadata while dropping nested DEPS repos.
  find "$PWD" -mindepth 2 -name .git -type d -prune -exec rm -rf {} +
  df -h
}

generate_android_build_files() {
  cd "$workspace/src"
  mkdir -p "$out_dir"
  local effective_use_siso=$use_siso
  if [[ "$effective_use_siso" == auto ]]; then
    if [[ -f "$out_dir/.siso_deps" ]]; then
      effective_use_siso=true
    elif [[ -f "$out_dir/.ninja_deps" ]]; then
      effective_use_siso=false
    else
      effective_use_siso=false
    fi
  fi
  cat "$repo_root/helium-chromium/flags.gn" > "$out_dir/args.gn"
  cat >> "$out_dir/args.gn" <<EOF
target_os = "android"
target_cpu = "$target_cpu"
is_official_build = $official_build
is_debug = false
dcheck_always_on = false
is_component_build = false
use_siso = $effective_use_siso
android_static_analysis = "off"
symbol_level = 0
blink_symbol_level = 0
ffmpeg_branding = "$android_ffmpeg_branding"
proprietary_codecs = $android_proprietary_codecs
chrome_public_manifest_package = "$manifest_package"
root_extra_deps = ["//components/helium_sync", "//chrome/browser/helium_sync"]
EOF
  if [[ "$use_ccache" == true ]]; then
    echo 'cc_wrapper = "ccache"' >> "$out_dir/args.gn"
  fi

  gn gen "$out_dir" --fail-on-unused-args
  "$repo_root/scripts/chromium/verify-android-media-config.sh" \
    "$workspace/src" "$out_dir" "$artifact_dir/build-provenance" \
    "$repo_root" "$chromium_ref"
}

touch_out_dir() {
  if [[ "$touch_restored_out" != true ]]; then
    return 0
  fi
  cd "$workspace/src"
  if [[ -d "$out_dir" ]]; then
    find "$out_dir" -type f -exec touch {} +
  fi
}

package_runtime_acceptance() {
  local destination=$1
  local sync_commit
  local source
  sync_commit=$(git -C "$repo_root" rev-parse HEAD)
  mkdir -p "$destination"
  for source in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs; do
    git -C "$repo_root" show "$sync_commit:scripts/android-media/$source" \
      > "$destination/$source"
    chmod 755 "$destination/$source"
  done
  {
    printf 'schema_version=1\n'
    printf 'probe_schema_version=1\n'
    printf 'helium_sync_commit=%s\n' "$sync_commit"
    printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
    printf 'manifest_package=%s\n' "$manifest_package"
    printf 'target_cpu=%s\n' "$target_cpu"
    printf 'artifact_target=%s\n' "$target"
  } > "$destination/kit.env"
  (
    cd "$destination"
    sha256sum fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs kit.env \
      > SHA256SUMS
  )
}

build_android_target() {
  df -h
  setup_depot_tools
  setup_ccache
  generate_android_build_files
  touch_out_dir
  if [[ "$use_siso" != false && -n "$siso_gomemlimit" && -z "${GOMEMLIMIT:-}" ]]; then
    export GOMEMLIMIT="$siso_gomemlimit"
  fi

  build_args=(-j "$autoninja_jobs" -C "$out_dir")
  if [[ -f "$out_dir/.siso_deps" && -n "$siso_flags" ]]; then
    # Space-delimited Siso-only flags, for simple switches like --batch=false.
    read -r -a extra_siso_args <<< "$siso_flags"
    build_args+=("${extra_siso_args[@]}")
  fi
  build_args+=("$target")

  set +e
  autoninja "${build_args[@]}"
  build_status="$?"
  set -e
  if [[ "$build_status" -ne 0 ]]; then
    df -h
    for log in "$out_dir/siso_failed_commands.sh" "$out_dir/siso_output" "$out_dir/siso.INFO"; do
      if [[ -f "$log" ]]; then
        echo "===== $log ====="
        tail -400 "$log"
      fi
    done
    exit "$build_status"
  fi

  staging="$artifact_dir/staging"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -a "$artifact_dir/build-provenance" "$staging/"
  package_runtime_acceptance "$staging/runtime-acceptance"

  if [[ "$provenance_only" == true ]]; then
    artifact_target=$(printf '%s' "$target" | tr '/:#' '___')
    {
      printf 'schema_version=1\n'
      printf 'target=%s\n' "$target"
      printf 'target_cpu=%s\n' "$target_cpu"
      printf 'chromium_commit=%s\n' "$HELIUM_ANDROID_CHROMIUM_COMMIT"
      printf 'completed_at=%s\n' "$(date --iso-8601=seconds)"
    } > "$staging/compile-proof.env"
    tar -C "$staging" -caf \
      "$artifact_dir/compile-${artifact_target}-${target_cpu}.tar.xz" .
    return
  fi

  cd "$out_dir"
  mapfile -d '' outputs < <(find . -type f \( -name '*.apk' -o -name '*.apks' -o -name '*.idsig' \) -print0)
  if [[ ${#outputs[@]} -eq 0 ]]; then
    echo "no APK-like outputs found under $out_dir" >&2
    exit 1
  fi
  for output in "${outputs[@]}"; do
    mkdir -p "$staging/$(dirname "$output")"
    cp "$output" "$staging/$output"
  done

  tar -C "$staging" -caf "$artifact_dir/${target}-${target_cpu}.tar.xz" .
}

case "$phase" in
  prepare)
    prepare_android_source
    ;;
  build)
    build_android_target
    ;;
  all)
    prepare_android_source
    build_android_target
    ;;
  *)
    echo "unknown CHROMIUM_ANDROID_PHASE: $phase" >&2
    exit 64
    ;;
esac
