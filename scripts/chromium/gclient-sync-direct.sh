#!/usr/bin/env bash
set -euo pipefail

# chromiumer's worker redirects GIT_CACHE_PATH into the bounded job tree, but
# depot_tools' local mirror serves a shallow checkout through a local
# upload-pack/pack-objects pair. The pinned gclient accepts --cache-dir only in
# `gclient config`; sync consumes the equivalent `cache_dir = None` assignment
# from .gclient. Require that assignment before removing the environment path.
config_file=.gclient
[[ -f "$config_file" ]] || {
  echo "missing gclient configuration: $config_file" >&2
  exit 64
}
cache_assignments=$(grep -Ec \
  '^[[:space:]]*cache_dir[[:space:]]*=' "$config_file" || true)
disabled_assignments=$(grep -Ec \
  '^[[:space:]]*cache_dir[[:space:]]*=[[:space:]]*None[[:space:]]*$' \
  "$config_file" || true)
[[ "$cache_assignments" -eq 1 && "$disabled_assignments" -eq 1 ]] || {
  echo "gclient configuration must contain exactly one cache_dir = None assignment" >&2
  exit 64
}
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

args=(sync)
if [[ -n "${GCLIENT_JOBS:-}" ]]; then
  [[ "$GCLIENT_JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "GCLIENT_JOBS must be a positive integer" >&2
    exit 64
  }
  args+=(--jobs "$GCLIENT_JOBS")
fi

exec gclient "${args[@]}" "$@"
