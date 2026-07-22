#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo "usage: verify-depot-tools-cache-contract.sh <depot-tools-dir> <commit>" >&2
  exit 64
}

depot_tools=$(realpath -e "$1")
expected_commit=$2
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "depot_tools commit must be a full Git hash" >&2
  exit 64
}
[[ "$(git -C "$depot_tools" rev-parse HEAD)" == "$expected_commit" ]] || {
  echo "depot_tools checkout does not match android-build.lock" >&2
  exit 1
}
[[ -z "$(git -C "$depot_tools" status --short --untracked-files=no)" ]] || {
  echo "depot_tools tracked files differ from the pinned commit" >&2
  exit 1
}

for tracked_file in gclient gclient.py update_depot_tools; do
  expected_blob=$(git -C "$depot_tools" rev-parse \
    "$expected_commit:$tracked_file")
  working_blob=$(git -C "$depot_tools" hash-object "$tracked_file")
  [[ "$working_blob" == "$expected_blob" ]] || {
    echo "depot_tools $tracked_file does not match the pinned commit" >&2
    exit 1
  }
done

gclient_launcher=$depot_tools/gclient
[[ -x "$gclient_launcher" ]] || {
  echo "pinned depot_tools checkout has no executable gclient launcher" >&2
  exit 1
}
grep -Fq 'if [[ $DEPOT_TOOLS_UPDATE != 0 ]]' "$gclient_launcher"
grep -Fq '"$base_dir"/update_depot_tools "$@"' "$gclient_launcher"

gclient_source=$depot_tools/gclient.py
[[ -f "$gclient_source" ]] || {
  echo "pinned depot_tools checkout has no gclient.py" >&2
  exit 1
}

config_body=$(awk '
  /^def CMDconfig\(/ { copy = 1 }
  copy && /^def CMDsync\(/ { exit }
  copy { print }
' "$gclient_source")
sync_body=$(awk '
  /^def CMDsync\(/ { copy = 1 }
  copy && /^def CMD[A-Za-z0-9_]+\(/ && $0 !~ /^def CMDsync\(/ { exit }
  copy { print }
' "$gclient_source")
set_config_body=$(awk '
  /^    def SetConfig\(/ { copy = 1 }
  copy && /^    def [A-Za-z0-9_]+\(/ && $0 !~ /^    def SetConfig\(/ { exit }
  copy { print }
' "$gclient_source")

grep -Fq '"--cache-dir",' <<<"$config_body"
grep -Fq 'options.cache_dir.lower() == "none"' <<<"$config_body"
grep -Fq 'options.cache_dir = None' <<<"$config_body"
! grep -Fq '"--cache-dir",' <<<"$sync_body"
grep -Fq 'config_dict.get("cache_dir", UNSET_CACHE_DIR)' \
  <<<"$set_config_body"
grep -Fq 'git_cache.Mirror.SetCachePath(cache_dir)' <<<"$set_config_body"

printf 'depot_tools_cache_contract=passed\ncommit=%s\n' "$expected_commit"
