#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-direct-source.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/bin"

cat > "$test_root/bin/git-child" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r variable; do
  case "$variable" in
    GIT_CACHE_PATH|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS)
      echo "Git child inherited forbidden variable: $variable" >&2
      exit 1
      ;;
  esac
done < <(compgen -e)
printf 'child_argv=%s\n' "$*" > "$CHILD_CAPTURE"
printf 'child_git_cache=disabled\n' >> "$CHILD_CAPTURE"
EOF
chmod +x "$test_root/bin/git-child"

cat > "$test_root/bin/gclient" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$GCLIENT_CAPTURE"
while IFS= read -r variable; do
  case "$variable" in
    GIT_CACHE_PATH|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS)
      echo "gclient inherited forbidden variable: $variable" >&2
      exit 1
      ;;
  esac
done < <(compgen -e)
exec git-child fetch origin pinned-commit --depth=1
EOF
chmod +x "$test_root/bin/gclient"

PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/gclient.argv" \
  CHILD_CAPTURE="$test_root/git-child.env" \
  GCLIENT_JOBS=2 \
  GIT_CACHE_PATH="$test_root/forbidden-cache" \
  GIT_CONFIG_COUNT=4 \
  GIT_CONFIG_KEY_0=pack.threads \
  GIT_CONFIG_VALUE_0=8 \
  GIT_CONFIG_KEY_1=pack.windowMemory \
  GIT_CONFIG_VALUE_1=2g \
  GIT_CONFIG_KEY_2=core.deltaBaseCacheLimit \
  GIT_CONFIG_VALUE_2=2g \
  GIT_CONFIG_KEY_3=pack.deltaCacheSize \
  GIT_CONFIG_VALUE_3=2g \
  GIT_CONFIG_PARAMETERS="'pack.threads'='8'" \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    --nohooks --no-history

cat > "$test_root/expected.argv" <<'EOF'
sync
--cache-dir
None
--jobs
2
--nohooks
--no-history
EOF
cmp "$test_root/expected.argv" "$test_root/gclient.argv"
grep -qx 'child_argv=fetch origin pinned-commit --depth=1' \
  "$test_root/git-child.env"
grep -qx 'child_git_cache=disabled' "$test_root/git-child.env"
[[ ! -e "$test_root/forbidden-cache" ]]

if PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/rejected.argv" \
  CHILD_CAPTURE="$test_root/rejected-child.env" \
  GCLIENT_JOBS=0 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
  >"$test_root/rejected.out" 2>&1; then
  echo 'zero gclient job count unexpectedly passed' >&2
  exit 1
fi
grep -qx 'GCLIENT_JOBS must be a positive integer' "$test_root/rejected.out"
[[ ! -e "$test_root/rejected.argv" ]]
[[ ! -e "$test_root/rejected-child.env" ]]

echo 'Android direct source acquisition contract passed'
