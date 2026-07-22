#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -ge 2 ]] || {
  echo "usage: gclient-sync-direct.sh DEPOT_TOOLS_DIR DEPOT_TOOLS_COMMIT [sync arguments]" >&2
  exit 64
}
depot_tools=$(realpath -e "$1")
expected_depot_tools_commit=$2
shift 2
[[ "$expected_depot_tools_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "depot_tools commit must be a full Git hash" >&2
  exit 64
}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

"$script_dir/verify-depot-tools-cache-contract.sh" \
  "$depot_tools" "$expected_depot_tools_commit" >/dev/null

# depot_tools documents DEPOT_TOOLS_UPDATE=0 as the supported way to disable
# gclient's automatic checkout update. Invoke the verified launcher by absolute
# path so PATH cannot select a different depot_tools checkout.
export DEPOT_TOOLS_UPDATE=0
set +e
"$depot_tools/gclient" "${args[@]}" "$@"
gclient_status=$?
set -e

# A successful or failed child must not have moved or modified the launcher
# checkout. This postcondition also catches a future launcher that ignores the
# documented no-update setting.
"$script_dir/verify-depot-tools-cache-contract.sh" \
  "$depot_tools" "$expected_depot_tools_commit" >/dev/null
exit "$gclient_status"
