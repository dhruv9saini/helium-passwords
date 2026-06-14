#!/system/bin/sh
set -eu

SYSTEM_GUARD=/data/local/helium-phone-thermal-guard-root.sh

if [ -x "$SYSTEM_GUARD" ]; then
  exec "$SYSTEM_GUARD" "$@"
fi

printf '%s\n' "missing system thermal guard: $SYSTEM_GUARD" >&2
exit 127
