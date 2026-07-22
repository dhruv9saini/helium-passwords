#!/system/bin/sh
set -eu

# Source template for /data/adb/service.d. Merely checking this file into the
# repository does not deploy or start it.
chroot_root=/data/local/chroots/arch
config=/root/.config/helium-sync/tab-ops.conf
scheduler=/root/.local/libexec/helium-tab-ops/tab-snapshot-scheduler.sh
interval_seconds=900

[ -x "${chroot_root}${scheduler}" ] || exit 0
[ -f "${chroot_root}${config}" ] || exit 0
chroot "${chroot_root}" /bin/sh -c \
    'command -v age >/dev/null && command -v jq >/dev/null && test -x /root/.local/bin/helium-tabs && test -x /root/.local/libexec/helium-tab-exporter' \
    || exit 0

while true; do
    chroot "${chroot_root}" "${scheduler}" cycle "${config}" >/dev/null 2>&1 || true
    sleep "${interval_seconds}"
done
