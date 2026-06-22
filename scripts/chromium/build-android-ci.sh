#!/usr/bin/env bash
set -euxo pipefail

repo_root=${HELIUM_SYNC_REPO:-"$GITHUB_WORKSPACE/helium-sync"}
workspace=${CHROMIUM_WORKSPACE:-"$GITHUB_WORKSPACE/chromium-android"}
chromium_ref=${CHROMIUM_REF:-main}
chromium_url=${CHROMIUM_URL:-https://chromium.googlesource.com/chromium/src.git}
target_cpu=${TARGET_CPU:-arm64}
target=${CHROMIUM_TARGET:-${TARGET:-chrome_public_apk}}
out_dir=${OUT_DIR:-out/Default}
autoninja_jobs=${AUTONINJA_JOBS:-2}
gclient_jobs=${GCLIENT_JOBS:-}
artifact_dir=${ARTIFACT_DIR:-"$GITHUB_WORKSPACE/android-artifacts"}
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

case "$use_siso" in
  auto|true|false) ;;
  *)
    echo "CHROMIUM_ANDROID_USE_SISO must be auto, true, or false" >&2
    exit 64
    ;;
esac

setup_ccache() {
  if [[ "$use_ccache" != true ]]; then
    return 0
  fi
  command -v ccache >/dev/null
  export CCACHE_DIR=${CCACHE_DIR:-"$GITHUB_WORKSPACE/chromium-ccache/android-$target_cpu"}
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
  if [[ -n "$gclient_jobs" ]]; then
    gclient sync --jobs "$gclient_jobs" "$@"
  else
    gclient sync "$@"
  fi
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

  "$repo_root/scripts/chromium/apply-patches.sh" "$PWD"
  generate_android_build_files
  find "$PWD" -name .git -type d -prune -exec rm -rf {} +
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
  cat > "$out_dir/args.gn" <<EOF
target_os = "android"
target_cpu = "$target_cpu"
is_official_build = $official_build
is_debug = false
dcheck_always_on = false
is_component_build = false
use_siso = $effective_use_siso
chrome_pgo_phase = 0
android_static_analysis = "off"
symbol_level = 0
blink_symbol_level = 0
ffmpeg_branding = "$android_ffmpeg_branding"
proprietary_codecs = $android_proprietary_codecs
root_extra_deps = ["//components/helium_sync", "//chrome/browser/helium_sync"]
EOF
  if [[ "$use_ccache" == true ]]; then
    echo 'cc_wrapper = "ccache"' >> "$out_dir/args.gn"
  fi

  gn gen "$out_dir"
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
