#!/usr/bin/env bash
set -euxo pipefail

linux_repo=${HELIUM_LINUX_REPO:-"$GITHUB_WORKSPACE/helium-linux"}
sync_repo_root=${HELIUM_SYNC_REPO:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"}
phase=${HELIUM_LINUX_PHASE:-all}
clone_sources=${HELIUM_LINUX_CLONE:-true}
with_pgo=${HELIUM_LINUX_PGO:-false}
touch_restored_out=${HELIUM_SYNC_TOUCH_RESTORED_OUT:-false}

cd "$linux_repo"

# shellcheck disable=SC1091
. "$linux_repo/scripts/shared.sh"

enable_helium_sync_gn_target() {
  local deps='root_extra_deps = ["//components/helium_sync", "//chrome/browser/helium_sync"]'
  if grep -q '^root_extra_deps =' "$_out_dir/args.gn"; then
    sed -i "s|^root_extra_deps = .*|$deps|" "$_out_dir/args.gn"
  else
    printf '\n%s\n' "$deps" >>"$_out_dir/args.gn"
  fi
}

prepare_linux_source() {
  setup_environment
  fetch_sources "$clone_sources" "$with_pgo"
  apply_patches
  "$sync_repo_root/scripts/chromium/copy-overlay.sh" --desktop "$_src_dir"
  apply_domsub
  helium_substitution
  helium_apply_translations
  helium_version
  helium_resources
  write_gn_args
  enable_helium_sync_gn_target
  fix_tool_downloading
  setup_toolchain
  gn_gen
  df -h
}

touch_out_dir() {
  if [[ "$touch_restored_out" != true ]]; then
    return 0
  fi
  setup_environment
  if [[ -d "$_out_dir" ]]; then
    find "$_out_dir" -type f -exec touch {} +
  fi
}

build_linux_targets() {
  setup_environment
  write_gn_args
  enable_helium_sync_gn_target
  gn_gen
  touch_out_dir
  if [[ -n "${NINJA_JOBS:-}" ]]; then
    cd "$_src_dir"
    ninja -j "$NINJA_JOBS" -C out/Default chrome chromedriver
  else
    build
  fi
}

case "$phase" in
  prepare)
    prepare_linux_source
    ;;
  build)
    build_linux_targets
    ;;
  all)
    prepare_linux_source
    build_linux_targets
    ;;
  *)
    echo "unknown HELIUM_LINUX_PHASE: $phase" >&2
    exit 64
    ;;
esac
