#!/system/bin/sh
set -eu

# Source template for Magisk service.d. The source installer keeps this file
# outside service.d and never creates the enable marker.
android_root=${HELIUM_TAB_ANDROID_ROOT:-}
system_bin=${android_root}/system/bin
chroot_root=${android_root}/data/local/chroots/arch
android_dev=${android_root}/dev
chroot_dev=${chroot_root}/dev
state_root=${android_root}/data/adb/helium-tab-ops
enabled_marker=${state_root}/enabled-v1
config=/root/.config/helium-sync/tab-ops.conf
backup=/root/.local/libexec/helium-tab-ops/tab-backup.sh
scheduler=/root/.local/libexec/helium-tab-ops/tab-snapshot-scheduler.sh
interval_seconds=900

log_failure() {
    if [ -x "${system_bin}/log" ]; then
        "${system_bin}/log" -t helium-tab-cycle "$1"
    fi
    printf '%s\n' "$1" >&2
}

require_android_boundary() {
    for binary in unshare sh hostname uname chroot sleep id stat cat mount; do
        [ -x "${system_bin}/${binary}" ] || {
            log_failure "missing Android boundary tool: ${binary}"
            return 1
        }
    done
    [ "$("${system_bin}/id" -u)" -eq 0 ] || { log_failure 'Helium tabs require Magisk root'; return 1; }
    [ -d "${chroot_root}" ] || { log_failure 'Arch chroot is missing'; return 1; }
}

null_device_is_valid() {
    null_path=$1
    [ ! -L "${null_path}" ] || return 1
    null_identity=$("${system_bin}/stat" -c '%F %t:%T' "${null_path}") || return 1
    [ "${null_identity}" = 'character device 1:3' ]
}

ensure_chroot_dev() {
    [ -d "${android_dev}" ] && [ ! -L "${android_dev}" ] && \
        null_device_is_valid "${android_dev}/null" || {
        log_failure 'Android /dev/null is not character device 1:3'
        return 1
    }
    [ -d "${chroot_dev}" ] && [ ! -L "${chroot_dev}" ] || {
        log_failure 'Arch chroot /dev is missing or unsafe'
        return 1
    }
    null_device_is_valid "${chroot_dev}/null" && return 0

    "${system_bin}/mount" -o bind "${android_dev}" "${chroot_dev}" || {
        log_failure 'failed to bind Android /dev into the Arch chroot'
        return 1
    }
    null_device_is_valid "${chroot_dev}/null" || {
        log_failure 'Arch chroot /dev/null is not character device 1:3 after bind'
        return 1
    }
}

run_in_oneplus_uts() {
    operation=$1
    target=$2
    ensure_chroot_dev
    "${system_bin}/unshare" -u "${system_bin}/sh" -c '
        system_bin=$1
        chroot_root=$2
        target=$3
        operation=$4
        config=$5
        "$system_bin/hostname" oneplus
        [ "$("$system_bin/uname" -n)" = oneplus ] || exit 1
        exec "$system_bin/chroot" "$chroot_root" /usr/bin/env -i \
            HOME=/root USER=root \
            PATH=/root/.local/bin:/root/.local/libexec:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
            "$target" "$operation" "$config"
    ' helium-tab-uts "${system_bin}" "${chroot_root}" "${target}" \
        "${operation}" "${config}"
}

preflight() {
    require_android_boundary
    [ -f "${chroot_root}${config}" ] || {
        log_failure 'active oneplus tab config is missing'
        return 1
    }
    [ -x "${chroot_root}${backup}" ] && [ -x "${chroot_root}${scheduler}" ] || {
        log_failure 'oneplus tab operation scripts are missing'
        return 1
    }

    # This path is deliberately independent of systemd and /proc. The chroot
    # may report systemctl=offline and /proc may be absent; neither is invoked
    # by this Magisk runner. The actual backup preflight checks age, jq,
    # helium-tabs, the fresh native export, and both outbound SSH destinations.
    if [ -r "${chroot_root}/proc/self/mountinfo" ]; then
        printf 'proc=mounted\n'
    else
        printf 'proc=not-required\n'
    fi
    printf 'scheduler=magisk-service.d\nsystemd=not-used\n'
    run_in_oneplus_uts preflight "${backup}"
}

marker_enabled() {
    [ -f "${enabled_marker}" ] && [ ! -L "${enabled_marker}" ] && \
        [ "$("${system_bin}/stat" -c %u "${enabled_marker}")" -eq 0 ] && \
        [ "$("${system_bin}/stat" -c %a "${enabled_marker}")" = 600 ] && \
        [ "$("${system_bin}/cat" "${enabled_marker}")" = 'enabled-v1' ]
}

command_name=${1:-service}
case "${command_name}" in
    preflight)
        [ "$#" -eq 1 ] || exit 2
        preflight
        ;;
    service)
        [ "$#" -eq 0 ] || exit 2
        marker_enabled || exit 0
        preflight || exit 1
        while marker_enabled; do
            run_in_oneplus_uts cycle "${scheduler}" || \
                log_failure 'Helium tab cycle failed; previous copies were preserved'
            "${system_bin}/sleep" "${interval_seconds}"
        done
        ;;
    *)
        echo 'usage: oneplus-tab-cycle-service.sh [preflight]' >&2
        exit 2
        ;;
esac
