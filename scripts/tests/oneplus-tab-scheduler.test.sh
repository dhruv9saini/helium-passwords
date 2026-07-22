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

fixture_root="${temporary}/fixture-android"
fixture_bin="${fixture_root}/system/bin"
fixture_chroot="${fixture_root}/data/local/chroots/arch"
fixture_state="${temporary}/fixture-state"
mkdir -p "${fixture_bin}" "${fixture_chroot}/dev" \
    "${fixture_chroot}/root/.config/helium-sync" \
    "${fixture_chroot}/root/.local/libexec/helium-tab-ops" "${fixture_state}"
printf 'synthetic-config\n' >"${fixture_chroot}/root/.config/helium-sync/tab-ops.conf"
for target in tab-backup.sh tab-snapshot-scheduler.sh; do
    printf '#!/bin/sh\nexit 0\n' \
        >"${fixture_chroot}/root/.local/libexec/helium-tab-ops/${target}"
    chmod 700 "${fixture_chroot}/root/.local/libexec/helium-tab-ops/${target}"
done

cat >"${fixture_bin}/stat" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -c ] && [ "$2" = '%F %t:%T' ]
case "$3" in
    */dev/null)
        case "$3" in
            */data/local/chroots/arch/dev/null)
                if [ -f "${TAB_TEST_STATE}/dev-bound" ]; then
                    printf 'character device 1:3\n'
                else
                    printf 'regular file 0:0\n'
                fi
                ;;
            *)
                if [ "${TAB_TEST_INVALID_SOURCE_DEV:-false}" = true ]; then
                    printf 'regular file 0:0\n'
                else
                    printf 'character device 1:3\n'
                fi
                ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
cat >"${fixture_bin}/mount" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -o ] && [ "$2" = bind ]
[ "$3" = "${HELIUM_TAB_ANDROID_ROOT}/dev" ]
[ "$4" = "${HELIUM_TAB_ANDROID_ROOT}/data/local/chroots/arch/dev" ]
printf 'mount-called\n' >"${TAB_TEST_STATE}/mount-called"
[ "${TAB_TEST_MOUNT_FAIL:-false}" != true ] || exit 1
[ "${TAB_TEST_MOUNT_INVALID:-false}" = true ] || \
    printf 'bound\n' >"${TAB_TEST_STATE}/dev-bound"
EOF
cat >"${fixture_bin}/unshare" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -u ]
shift
exec "$@"
EOF
cat >"${fixture_bin}/sh" <<'EOF'
#!/bin/sh
exec /bin/sh "$@"
EOF
cat >"${fixture_bin}/hostname" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = oneplus ]
printf 'oneplus\n' >"${TAB_TEST_STATE}/hostname"
EOF
cat >"${fixture_bin}/uname" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -n ]
cat "${TAB_TEST_STATE}/hostname"
EOF
cat >"${fixture_bin}/chroot" <<'EOF'
#!/bin/sh
set -eu
[ -f "${TAB_TEST_STATE}/dev-bound" ]
printf 'chroot-called\n' >"${TAB_TEST_STATE}/chroot-called"
EOF
cat >"${fixture_bin}/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && printf '0\n'
EOF
for target in sleep cat; do
    cat >"${fixture_bin}/${target}" <<EOF
#!/bin/sh
exec /bin/${target} "\$@"
EOF
done
chmod 700 "${fixture_bin}"/*
mkdir -p "${fixture_root}/dev"
: >"${fixture_root}/dev/null"
export TAB_TEST_STATE="${fixture_state}"

fixture_output=$(HELIUM_TAB_ANDROID_ROOT="${fixture_root}" sh "${runner}" preflight)
grep -q '^scheduler=magisk-service.d$' <<<"${fixture_output}"
test -f "${fixture_state}/mount-called"
test -f "${fixture_state}/dev-bound"
test -f "${fixture_state}/chroot-called"

find "${fixture_state}" -mindepth 1 -maxdepth 1 -type f -delete
printf 'bound\n' >"${fixture_state}/dev-bound"
HELIUM_TAB_ANDROID_ROOT="${fixture_root}" sh "${runner}" preflight >/dev/null
test ! -e "${fixture_state}/mount-called"
test -f "${fixture_state}/chroot-called"

find "${fixture_state}" -mindepth 1 -maxdepth 1 -type f -delete
if TAB_TEST_MOUNT_FAIL=true HELIUM_TAB_ANDROID_ROOT="${fixture_root}" \
    sh "${runner}" preflight >/dev/null 2>&1; then
    echo 'oneplus preflight entered the chroot after a failed /dev bind' >&2
    exit 1
fi
test -f "${fixture_state}/mount-called"
test ! -e "${fixture_state}/chroot-called"

find "${fixture_state}" -mindepth 1 -maxdepth 1 -type f -delete
if TAB_TEST_MOUNT_INVALID=true HELIUM_TAB_ANDROID_ROOT="${fixture_root}" \
    sh "${runner}" preflight >/dev/null 2>&1; then
    echo 'oneplus preflight accepted a malformed /dev/null after bind' >&2
    exit 1
fi
test -f "${fixture_state}/mount-called"
test ! -e "${fixture_state}/chroot-called"

find "${fixture_state}" -mindepth 1 -maxdepth 1 -type f -delete
if TAB_TEST_INVALID_SOURCE_DEV=true HELIUM_TAB_ANDROID_ROOT="${fixture_root}" \
    sh "${runner}" preflight >/dev/null 2>&1; then
    echo 'oneplus preflight accepted a malformed Android /dev/null source' >&2
    exit 1
fi
test ! -e "${fixture_state}/mount-called"
test ! -e "${fixture_state}/chroot-called"

grep -q 'unshare" -u' "${runner}"
grep -q 'hostname" oneplus' "${runner}"
grep -q 'uname" -n).*oneplus' "${runner}"
grep -q 'mount" -o bind.*android_dev.*chroot_dev' "${runner}"
grep -q 'character device 1:3' "${runner}"
[ "$(grep -c 'system_bin}/mount"' "${runner}")" -eq 1 ]
grep -q 'scheduler=magisk-service.d' "${runner}"
grep -q 'systemd=not-used' "${runner}"
grep -q 'proc=not-required' "${runner}"
grep -q 'enabled-v1' "${runner}"
if grep -Eq '(^|[[:space:]"])systemctl[[:space:]]|adb (push|shell)|age-keygen|android-bind-mounts' "${runner}"; then
    echo 'oneplus runner gained a forbidden systemd, broad mount, deployment, or key path' >&2
    exit 1
fi
if grep -Eq '/data/adb/service\.d|enabled-v1|age-keygen|ssh-keygen|adb (push|shell)' "${installer}"; then
    echo 'oneplus source installer gained provisioning or enablement behavior' >&2
    exit 1
fi

printf 'oneplus_tab_scheduler=passed\n'
