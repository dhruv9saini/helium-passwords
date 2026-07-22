#!/usr/bin/env bash
set -euo pipefail

# chromiumer's worker redirects GIT_CACHE_PATH into the bounded job tree, but
# depot_tools' local mirror serves a shallow checkout through a local
# upload-pack/pack-objects pair. Disable that mirror explicitly: current
# gclient defines --cache-dir None as the override for GIT_CACHE_PATH and Git
# cache.cachepath. An older/incompatible gclient will reject the option and
# fail before source preparation instead of silently restoring the mirror.
unset GIT_CACHE_PATH

# Do not leak indexed or legacy command-scope configuration into gclient's Git
# process tree. In particular, GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs become
# inert when Git consumes the matching count before starting a child process.
while IFS= read -r variable; do
  case "$variable" in
    GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS)
      unset "$variable"
      ;;
  esac
done < <(compgen -e)

args=(sync --cache-dir None)
if [[ -n "${GCLIENT_JOBS:-}" ]]; then
  [[ "$GCLIENT_JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "GCLIENT_JOBS must be a positive integer" >&2
    exit 64
  }
  args+=(--jobs "$GCLIENT_JOBS")
fi

exec gclient "${args[@]}" "$@"
