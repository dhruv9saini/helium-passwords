#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-direct-source.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/work" "$test_root/depot-tools"
printf 'cache_dir = None\n' > "$test_root/work/.gclient"

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

cat > "$test_root/depot-tools/gclient.py" <<'EOF'
def CMDconfig(parser, args):
  parser.add_option(
      "--cache-dir",
  )
  if options.cache_dir.lower() == "none":
    options.cache_dir = None

def CMDsync(parser, args):
  pass

class GClient:
    def SetConfig(self, config_dict):
        cache_dir = config_dict.get("cache_dir", UNSET_CACHE_DIR)
        git_cache.Mirror.SetCachePath(cache_dir)

    def NextMethod(self):
        pass
EOF

cat > "$test_root/depot-tools/update_depot_tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
git -C "$(dirname "$0")" checkout --detach "$MUTATED_DEPOT_COMMIT" >/dev/null
EOF
chmod +x "$test_root/depot-tools/update_depot_tools"

cat > "$test_root/depot-tools/ensure_bootstrap" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
chmod +x "$test_root/depot-tools/ensure_bootstrap"

cat > "$test_root/depot-tools/gclient" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
base_dir=$(dirname "$0")
if [[ $DEPOT_TOOLS_UPDATE != 0 ]]; then
  "$base_dir"/update_depot_tools "$@"
fi
[[ "$DEPOT_TOOLS_UPDATE" == 0 ]]
printf '%s\n' "$@" > "$GCLIENT_CAPTURE"
printf 'depot_tools_update=%s\n' "$DEPOT_TOOLS_UPDATE" \
  > "$GCLIENT_ENV_CAPTURE"
while IFS= read -r variable; do
  case "$variable" in
    GIT_CACHE_PATH|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS)
      echo "gclient inherited forbidden variable: $variable" >&2
      exit 1
      ;;
  esac
done < <(compgen -e)
if [[ "${MUTATE_DEPOT_DURING_GCLIENT:-false}" == true ]]; then
  "$base_dir"/update_depot_tools "$@"
fi
exec git-child fetch origin pinned-commit --depth=1
EOF
chmod +x "$test_root/depot-tools/gclient"

git -C "$test_root/depot-tools" init -q
git -C "$test_root/depot-tools" config user.email test@helium.invalid
git -C "$test_root/depot-tools" config user.name 'Helium Test'
git -C "$test_root/depot-tools" add ensure_bootstrap gclient gclient.py update_depot_tools
git -C "$test_root/depot-tools" commit -qm pinned
pinned_depot_commit=$(git -C "$test_root/depot-tools" rev-parse HEAD)
printf 'mutation\n' > "$test_root/depot-tools/mutation-marker"
git -C "$test_root/depot-tools" add mutation-marker
git -C "$test_root/depot-tools" commit -qm mutation
mutated_depot_commit=$(git -C "$test_root/depot-tools" rev-parse HEAD)
git -C "$test_root/depot-tools" checkout -q --detach "$pinned_depot_commit"
pinned_chromium_commit=24b04c927b23c39cf9c5227cc8dc6f64a744c8e9

(
  cd "$test_root/work"
  PATH="$test_root/bin:$PATH" \
    GCLIENT_CAPTURE="$test_root/gclient.argv" \
    GCLIENT_ENV_CAPTURE="$test_root/gclient.env" \
    CHILD_CAPTURE="$test_root/git-child.env" \
    MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
    GCLIENT_JOBS=1 \
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
      "$test_root/depot-tools" "$pinned_depot_commit" \
      --revision "src@$pinned_chromium_commit" --nohooks --no-history
)

cat > "$test_root/expected.argv" <<EOF
sync
--jobs
1
--revision
src@$pinned_chromium_commit
--nohooks
--no-history
EOF
cmp "$test_root/expected.argv" "$test_root/gclient.argv"
grep -qx 'depot_tools_update=0' "$test_root/gclient.env"
[[ "$(git -C "$test_root/depot-tools" rev-parse HEAD)" == \
  "$pinned_depot_commit" ]]
grep -qx 'child_argv=fetch origin pinned-commit --depth=1' \
  "$test_root/git-child.env"
grep -qx 'child_git_cache=disabled' "$test_root/git-child.env"
[[ ! -e "$test_root/forbidden-cache" ]]

if (cd "$test_root/work" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/rejected.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/rejected.env" \
  CHILD_CAPTURE="$test_root/rejected-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  GCLIENT_JOBS=2 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/rejected.out" 2>&1); then
  echo 'non-policy gclient job count unexpectedly passed' >&2
  exit 1
fi
grep -qx 'GCLIENT_JOBS must remain 1 for the isolated Chromiumer policy' \
  "$test_root/rejected.out"
[[ ! -e "$test_root/rejected.argv" ]]
[[ ! -e "$test_root/rejected-child.env" ]]

if (cd "$test_root/work" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/missing-jobs.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/missing-jobs.env" \
  CHILD_CAPTURE="$test_root/missing-jobs-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/missing-jobs.out" 2>&1); then
  echo 'missing gclient job policy unexpectedly passed' >&2
  exit 1
fi
grep -qx 'GCLIENT_JOBS must remain 1 for the isolated Chromiumer policy' \
  "$test_root/missing-jobs.out"
[[ ! -e "$test_root/missing-jobs.argv" ]]
[[ ! -e "$test_root/missing-jobs-child.env" ]]

mkdir "$test_root/unsafe"
printf 'cache_dir = "/tmp/not-disabled"\n' > "$test_root/unsafe/.gclient"
if (cd "$test_root/unsafe" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/unsafe.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/unsafe.env" \
  CHILD_CAPTURE="$test_root/unsafe-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  GCLIENT_JOBS=1 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/unsafe.out" 2>&1); then
  echo 'cache-enabled gclient configuration unexpectedly passed' >&2
  exit 1
fi
grep -qx 'gclient configuration must contain exactly one cache_dir = None assignment' \
  "$test_root/unsafe.out"
[[ ! -e "$test_root/unsafe.argv" ]]
[[ ! -e "$test_root/unsafe-child.env" ]]

git -C "$test_root/depot-tools" checkout -q --detach "$mutated_depot_commit"
if (cd "$test_root/work" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/mutated.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/mutated.env" \
  CHILD_CAPTURE="$test_root/mutated-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  GCLIENT_JOBS=1 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/mutated.out" 2>&1); then
  echo 'mutated depot_tools HEAD unexpectedly executed gclient' >&2
  exit 1
fi
grep -qx 'depot_tools checkout does not match android-build.lock' \
  "$test_root/mutated.out"
[[ ! -e "$test_root/mutated.argv" ]]
[[ ! -e "$test_root/mutated-child.env" ]]

git -C "$test_root/depot-tools" checkout -q --detach "$pinned_depot_commit"
printf '# dirty\n' >> "$test_root/depot-tools/gclient.py"
if (cd "$test_root/work" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/dirty.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/dirty.env" \
  CHILD_CAPTURE="$test_root/dirty-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  GCLIENT_JOBS=1 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/dirty.out" 2>&1); then
  echo 'dirty depot_tools checkout unexpectedly executed gclient' >&2
  exit 1
fi
grep -qx 'depot_tools tracked files differ from the pinned commit' \
  "$test_root/dirty.out"
[[ ! -e "$test_root/dirty.argv" ]]
[[ ! -e "$test_root/dirty-child.env" ]]
git -C "$test_root/depot-tools" checkout -q -- gclient.py

if (cd "$test_root/work" && PATH="$test_root/bin:$PATH" \
  GCLIENT_CAPTURE="$test_root/post-mutation.argv" \
  GCLIENT_ENV_CAPTURE="$test_root/post-mutation.env" \
  CHILD_CAPTURE="$test_root/post-mutation-child.env" \
  MUTATED_DEPOT_COMMIT="$mutated_depot_commit" \
  MUTATE_DEPOT_DURING_GCLIENT=true \
  GCLIENT_JOBS=1 \
  "$repo_root/scripts/chromium/gclient-sync-direct.sh" \
    "$test_root/depot-tools" "$pinned_depot_commit" \
  >"$test_root/post-mutation.out" 2>&1); then
  echo 'gclient checkout movement escaped the postcondition' >&2
  exit 1
fi
grep -qx 'depot_tools checkout does not match android-build.lock' \
  "$test_root/post-mutation.out"
[[ -e "$test_root/post-mutation-child.env" ]]

# Preserve the private depot pin proof and its measured two-GiB admission
# contract in addition to the shared one-sync source assertions below.
grep -Fq 'export DEPOT_TOOLS_UPDATE=0' \
  "$repo_root/scripts/chromium/prove-depot-tools-pin.sh"
grep -Fq '"$depot_tools/gclient" --version' \
  "$repo_root/scripts/chromium/prove-depot-tools-pin.sh"
grep -Fq '[[ "$head_after" == "$head_before" ]]' \
  "$repo_root/scripts/chromium/prove-depot-tools-pin.sh"

runbook="$repo_root/docs/chromiumer-builds.md"
grep -Fxq 'scripts/chromiumer-job.sh preflight 2' "$runbook"
grep -Fxq 'scripts/chromiumer-job.sh stage "$job" 2' "$runbook"
! grep -Fxq 'scripts/chromiumer-job.sh preflight 1' "$runbook"
! grep -Fxq 'scripts/chromiumer-job.sh stage "$job" 1' "$runbook"
grep -Fq '`workspace_bytes=1,293,221,888`' "$runbook"

gib_bytes=$((1024 * 1024 * 1024))
failed_sample_bytes=1293221888
retained_tree_bytes=1483829248
proof_budget_bytes=$((2 * gib_bytes))
[[ "$failed_sample_bytes" -gt "$gib_bytes" ]]
[[ "$retained_tree_bytes" -lt "$proof_budget_bytes" ]]
[[ "$((proof_budget_bytes - retained_tree_bytes))" -eq 663654400 ]]

source_helper="$repo_root/scripts/chromium/prepare-android-source.sh"
grep -Fq 'PATH="${depot_tools}/.cipd_bin:${depot_tools}:${PATH}" \' \
  "$source_helper"
grep -Fq '    DEPOT_TOOLS_UPDATE=0 "${depot_tools}/ensure_bootstrap"' \
  "$source_helper"
grep -Fq 'python3_reldir=$(<"${depot_tools}/python3_bin_reldir.txt")' \
  "$source_helper"
grep -Fq '"${depot_tools}/python-bin/python3" --version' \
  "$source_helper"
grep -Fq -- '--revision "src@${chromium_ref}" --nohooks --no-history' \
  "$source_helper"
grep -Fq 'actual_chromium_ref=$(git -C "${workspace}/src" rev-parse HEAD)' \
  "$source_helper"
grep -Fq '[ "${actual_chromium_ref}" = "${chromium_ref}" ]' \
  "$source_helper"
! grep -Fq 'git fetch origin "${chromium_ref}"' "$source_helper"
! grep -Fq 'git checkout FETCH_HEAD' "$source_helper"
! grep -Fq -- '--with_branch_heads' "$source_helper"
! grep -Fq '"revision":' "$source_helper"

source_calls=$(grep -Fc 'gclient-sync-direct.sh"' "$source_helper")
[[ "$source_calls" -eq 1 ]]

build_script="$repo_root/scripts/chromium/build-android-ci.sh"
grep -Fq 'CHROMIUM_REF="$chromium_ref"' "$build_script"
grep -Fq '"$repo_root/scripts/chromium/prepare-android-source.sh" "$workspace"' \
  "$build_script"
build_source_calls=$(grep -Fc 'prepare-android-source.sh" "$workspace"' \
  "$build_script")
[[ "$build_source_calls" -eq 1 ]]
phase_source_calls=$(grep -Ec '^    prepare_android_source$' "$build_script")
[[ "$phase_source_calls" -eq 2 ]]
! grep -Fq 'gclient-sync-direct.sh' "$build_script"
! grep -Fq 'gclient_sync' "$build_script"
! grep -Fq 'git fetch origin "$chromium_ref"' "$build_script"
! grep -Fq 'git checkout FETCH_HEAD' "$build_script"
! grep -Fq -- '--with_branch_heads' "$build_script"
! grep -Fq -- '--with_tags' "$build_script"
! grep -Fq 'cache_dir = None' "$build_script"

# The shared lock is one source of truth and all three tool/source pins are
# immutable full hashes.
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
[[ "$HELIUM_ANDROID_CHROMIUM_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$HELIUM_ANDROID_CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$HELIUM_ANDROID_DEPOT_TOOLS_COMMIT" =~ ^[0-9a-f]{40}$ ]]

echo 'Android direct source acquisition contract passed'
