#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
temporary=$(mktemp -d /tmp/helium-oneplus-tab-test.XXXXXX)
cleanup() {
    local result=$?
    find "${temporary}" -depth -delete 2>/dev/null || true
    return "${result}"
}
trap cleanup EXIT

installer="${repo_root}/scripts/tabs/install-oneplus-tab-scheduler.sh"
runner="${repo_root}/scripts/tabs/oneplus-tab-cycle-service.sh"
config="${repo_root}/scripts/tabs/tab-ops.oneplus.conf.example"

install_output=$(HOME="${temporary}/home" "${installer}" install "${config}")
grep -q '^installed_source=true$' <<<"${install_output}"
grep -q '^active_config=false$' <<<"${install_output}"
grep -q '^magisk_service_installed=false$' <<<"${install_output}"
grep -q '^enabled=false$' <<<"${install_output}"

operation_root="${temporary}/home/.local/libexec/helium-tab-ops"
test -x "${operation_root}/tab-ops-lib.sh"
test -x "${operation_root}/tab-backup.sh"
test -x "${operation_root}/tab-snapshot-scheduler.sh"
test -x "${temporary}/home/.local/libexec/helium-tab-exporter"
test "$(stat -c %a "${temporary}/home/.config/helium-sync/tab-ops.conf.template")" = 600
test "$(stat -c %a "${temporary}/home/.local/share/helium-tab-ops/oneplus-tab-cycle-service.disabled")" = 600
test ! -e "${temporary}/home/.config/helium-sync/tab-ops.conf"
test ! -e "${temporary}/home/.local/share/helium-tab-ops/enabled-v1"

if HOME="${temporary}/home" "${installer}" install "${config}" >/dev/null 2>&1; then
    echo 'oneplus source installer overwrote an existing installation' >&2
    exit 1
fi

android_root="${temporary}/android"
mkdir -p "${android_root}/system/bin" "${android_root}/data/adb/helium-tab-ops"
HELIUM_TAB_ANDROID_ROOT="${android_root}" sh "${runner}"
test ! -e "${android_root}/data/adb/helium-tab-ops/enabled-v1"
if HELIUM_TAB_ANDROID_ROOT="${android_root}" sh "${runner}" preflight >/dev/null 2>&1; then
    echo 'oneplus preflight passed without its Android/chroot boundary' >&2
    exit 1
fi

grep -q 'unshare" -u' "${runner}"
grep -q 'hostname" oneplus' "${runner}"
grep -q 'uname" -n).*oneplus' "${runner}"
grep -q 'scheduler=magisk-service.d' "${runner}"
grep -q 'systemd=not-used' "${runner}"
grep -q 'proc=not-required' "${runner}"
grep -q 'enabled-v1' "${runner}"
if grep -Eq '(^|[[:space:]"])(systemctl|mount)[[:space:]]|adb (push|shell)|age-keygen' "${runner}"; then
    echo 'oneplus runner gained a forbidden systemd, mount, deployment, or key path' >&2
    exit 1
fi
if grep -Eq '/data/adb/service\.d|enabled-v1|age-keygen|ssh-keygen|adb (push|shell)' "${installer}"; then
    echo 'oneplus source installer gained provisioning or enablement behavior' >&2
    exit 1
fi

printf 'oneplus_tab_scheduler=passed\n'
