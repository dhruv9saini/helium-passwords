#!/usr/bin/env bash
set -euo pipefail

[[ "${HELIUM_MEDIA_BACKEND_PORT:-}" =~ ^[0-9]+$ ]]
for attempt in {1..100}; do
  if curl --fail --silent --show-error --max-time 1 --noproxy '*' \
    --output /dev/null \
    "http://127.0.0.1:$HELIUM_MEDIA_BACKEND_PORT/manifest.json" 2>/dev/null; then
    exit 0
  fi
  sleep 0.1
done

echo "fixture backend did not become ready on loopback" >&2
exit 1
