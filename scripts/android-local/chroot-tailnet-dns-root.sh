#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
resolv="$ROOT/etc/resolv.conf"

mkdir -p "$ROOT/etc" 2>/dev/null || true

tailnet_domain=$(
  dumpsys connectivity 2>/dev/null |
    sed -n 's/.*Domains: \([^ ]*\.ts\.net\).*/\1/p' |
    head -n 1
)

if ip route get 100.100.100.100 >/dev/null 2>&1; then
  {
    [ -z "$tailnet_domain" ] || printf 'search %s\n' "$tailnet_domain"
    printf 'nameserver 100.100.100.100\n'
    printf 'nameserver fd7a:115c:a1e0::53\n'
    printf 'options timeout:1 attempts:2\n'
  } >"$resolv"
else
  {
    printf 'nameserver 1.1.1.1\n'
    printf 'nameserver 8.8.8.8\n'
    printf 'options timeout:1 attempts:2\n'
  } >"$resolv"
fi

chmod 0644 "$resolv" 2>/dev/null || true
