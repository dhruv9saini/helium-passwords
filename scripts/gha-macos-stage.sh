#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/gha-macos-stage.sh <prepare-resources|build-init|build-resume> <x86_64|arm64>

Run one macOS GitHub Actions build stage from a materialized Helium macOS
platform checkout.
EOF
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

mode="$1"
arch="$2"

case "${mode}" in
    prepare-resources|build-init|build-resume) ;;
    *)
        echo "unknown mode: ${mode}" >&2
        usage
        exit 2
        ;;
esac

case "${arch}" in
    x86_64|arm64) ;;
    *)
        echo "unsupported arch: ${arch}" >&2
        usage
        exit 2
        ;;
esac

prepare_environment() {
    export SCCACHE_DIR="${SCCACHE_DIR:-${RUNNER_TEMP:-${PWD}}/sccache}"
    mkdir -p "${SCCACHE_DIR}"

    cp -va ./.github/scripts/ ./
    date +%s > ./epoch_job_start.txt
    ./github_prepare_xcode.sh
    if [ -n "${ANDROID_HOME:-}" ]; then
        sudo rm -rf "${ANDROID_HOME}"
    fi
    sudo mdutil -a -i off
    ./github_setup_env_toolchain.sh "${arch}" | tee -a github_actions_setup_env_toolchain.log
}

run_build_stage() {
    sccache --show-stats || true
    ./github_build.sh "${arch}" 2>&1 | tee -a "github_actions_build_${arch}.log"
    sccache --show-stats || true
    ./github_prepare_artifacts.sh "${arch}" | tee -a "github_actions_upload_${arch}.log"
}

prepare_environment

case "${mode}" in
    prepare-resources)
        ./github_fetch_resources.sh "${arch}" | tee -a github_actions_retrieve_resources.log
        ls -la
        ./github_pack_resources.sh | tee -a github_actions_retrieve_resources.log
        ;;
    build-init)
        ./github_unpack_resources.sh
        ls -la
        ./github_before_build.sh "${arch}" | tee -a "github_actions_build_${arch}.log"
        run_build_stage
        ;;
    build-resume)
        ./github_unpack_archive.sh
        run_build_stage
        ;;
esac
