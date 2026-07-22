#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
# shellcheck source=../../chromium/android-build.lock
. "${repo_root}/chromium/android-build.lock"

usage() {
    cat >&2 <<'EOF'
usage: prepare-android-source.sh WORKSPACE

Create one shallow Android Chromium checkout at the immutable commit in
chromium/android-build.lock. WORKSPACE is generated build state, not a profile.
EOF
}

[ "$#" -eq 1 ] || {
    usage
    exit 64
}

workspace=$(realpath -m "$1")
chromium_url=${CHROMIUM_URL:-https://chromium.googlesource.com/chromium/src.git}
requested_chromium_ref=${CHROMIUM_REF:-${HELIUM_ANDROID_CHROMIUM_COMMIT}}
[[ "${requested_chromium_ref}" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'CHROMIUM_REF must be a full immutable Git commit' >&2
    exit 64
}
[ "${requested_chromium_ref}" = "${HELIUM_ANDROID_CHROMIUM_COMMIT}" ] || {
    echo 'CHROMIUM_REF does not match chromium/android-build.lock' >&2
    exit 64
}
chromium_ref=${HELIUM_ANDROID_CHROMIUM_COMMIT}

depot_tools_url=https://chromium.googlesource.com/chromium/tools/depot_tools.git
depot_tools="${workspace}/depot_tools"
config="${workspace}/.gclient"
config_expected="${workspace}/.gclient.expected.$$"
cleanup() {
    find "${config_expected}" -delete 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${workspace}"
if [ ! -d "${depot_tools}/.git" ]; then
    mkdir -p "${depot_tools}"
    git -C "${depot_tools}" init
    git -C "${depot_tools}" remote add origin "${depot_tools_url}"
fi
[ "$(git -C "${depot_tools}" remote get-url origin)" = \
    "${depot_tools_url}" ] || {
    echo 'depot_tools origin does not match the locked source workflow' >&2
    exit 1
}
git -C "${depot_tools}" fetch --depth=1 origin \
    "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}"
git -C "${depot_tools}" checkout --detach \
    "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}"
"${repo_root}/scripts/chromium/verify-depot-tools-cache-contract.sh" \
    "${depot_tools}" "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}" >/dev/null
DEPOT_TOOLS_UPDATE=0 "${depot_tools}/ensure_bootstrap"
"${repo_root}/scripts/chromium/verify-depot-tools-cache-contract.sh" \
    "${depot_tools}" "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}" >/dev/null
python3_reldir=$(<"${depot_tools}/python3_bin_reldir.txt")
case "${python3_reldir}" in
    ""|/*|../*|*/../*|*/..)
        echo 'depot_tools produced an unsafe Python bootstrap path' >&2
        exit 1
        ;;
esac
[ -x "${depot_tools}/${python3_reldir}/python3" ] || {
    echo 'depot_tools Python bootstrap is incomplete' >&2
    exit 1
}
"${depot_tools}/python-bin/python3" --version >/dev/null

cat >"${config_expected}" <<EOF
solutions = [
  {
    "name": "src",
    "url": "${chromium_url}",
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
cache_dir = None
target_os = ["android"]
EOF
if [ -e "${config}" ]; then
    cmp --silent "${config_expected}" "${config}" || {
        echo 'existing .gclient differs from the locked Android source configuration' >&2
        exit 1
    }
    find "${config_expected}" -delete
else
    mv "${config_expected}" "${config}"
fi

(
    cd "${workspace}"
    GCLIENT_JOBS="${GCLIENT_JOBS:-}" \
        "${repo_root}/scripts/chromium/gclient-sync-direct.sh" \
            "${depot_tools}" "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}" \
            --revision "src@${chromium_ref}" --nohooks --no-history
)

actual_chromium_ref=$(git -C "${workspace}/src" rev-parse HEAD)
[ "${actual_chromium_ref}" = "${chromium_ref}" ] || {
    echo "Chromium checkout mismatch: ${actual_chromium_ref}" >&2
    exit 1
}
"${repo_root}/scripts/chromium/verify-depot-tools-cache-contract.sh" \
    "${depot_tools}" "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}" >/dev/null

printf 'android_source=ready\nchromium_commit=%s\ndepot_tools_commit=%s\n' \
    "${actual_chromium_ref}" "${HELIUM_ANDROID_DEPOT_TOOLS_COMMIT}"
