#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
shim="${repo_root}/scripts/chromiumer-bin/ninja"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-ninja-shim.XXXXXX")
boundary_state=
cleanup() {
    find "${temporary}" -depth -delete
    if [ -n "${boundary_state}" ] && [ -d "${boundary_state}" ]; then
        find "${boundary_state}" -depth -delete
    fi
}
trap cleanup EXIT

fake_ninja="${temporary}/real-ninja"
arguments="${temporary}/arguments"
cat >"${fake_ninja}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${HELIUM_NINJA_TEST_ARGUMENTS}"
if [[ " $* " = *" -t query "* ]]; then
    printf '%s\n' \
        'gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json' \
        'gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json' \
        '  outputs:' \
        '    phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files'
fi
EOF
chmod 700 "${fake_ninja}"

HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -C out/Default chrome chromedriver
[ "$(cat "${arguments}")" = "$(cat <<'EOF'
-j
1
-C
out/Default
chrome
chromedriver
EOF
)" ]

for spelling in '-j 1' '-j1' '--jobs 1' '--jobs=1'; do
    read -r -a job_arguments <<<"${spelling}"
    HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
        HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
        "${shim}" "${job_arguments[@]}" -C out/Default chrome chromedriver
    [ "$(cat "${arguments}")" = "$(cat <<'EOF'
-j
1
-C
out/Default
chrome
chromedriver
EOF
)" ]
done

HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -C out/Default -- -j1 --jobs=8 chrome
[ "$(cat "${arguments}")" = "$(cat <<'EOF'
-j
1
-C
out/Default
--
-j1
--jobs=8
chrome
EOF
)" ]

if HELIUM_BUILD_JOBS=2 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -C out/Default chrome >/dev/null 2>&1; then
    echo "Ninja shim accepted a non-policy job count" >&2
    exit 1
fi
if HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -j8 -C out/Default chrome >/dev/null 2>&1; then
    echo "Ninja shim accepted a caller job override" >&2
    exit 1
fi
if HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -j1 --jobs=1 -C out/Default chrome >/dev/null 2>&1; then
    echo "Ninja shim accepted duplicate caller job overrides" >&2
    exit 1
fi
if HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${shim}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    "${shim}" -C out/Default chrome >/dev/null 2>&1; then
    echo "Ninja shim accepted a recursive real-Ninja path" >&2
    exit 1
fi

# A fresh full-target invocation writes one immutable graph receipt before the
# real Ninja build is allowed to start.
job="ninja-boundary-test-$$"
boundary_state="/home/d/.local/state/helium-builds/${job}"
mkdir -p "${boundary_state}" "${temporary}/bin"
real_node=$(command -v node)
source_root="${temporary}/source"
out="${source_root}/out/Default"
ui_prefix=gen/third_party/devtools-frontend/src/front_end/ui/kit
mkdir -p "${out}" \
    "${source_root}/third_party/devtools-frontend/src/scripts/build/ninja" \
    "${source_root}/third_party/devtools-frontend/src/scripts/build"
printf 'build chrome: phony\nbuild chromedriver: phony\n' >"${out}/build.ninja"
cat >"${out}/toolchain.ninja" <<EOF
build ${ui_prefix}/css_files-tsconfig.json ${ui_prefix}/cards/card.css.js ${ui_prefix}/icons/icon.css.js ${ui_prefix}/link/link.css.js: fixture_css_files___build_toolchain_linux_clang_x64__rule input
build phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files: phony ${ui_prefix}/css_files-tsconfig.json ${ui_prefix}/cards/card.css.js ${ui_prefix}/icons/icon.css.js ${ui_prefix}/link/link.css.js
build ${ui_prefix}/devtools_entrypoint-bundle-tsconfig-tsconfig.json : fixture || phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files
build gen/third_party/devtools-frontend/src/front_end/models/ai_assistance/skills/styling.skill.js: fixture input
EOF
printf 'fixture gni\n' >"${source_root}/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni"
printf 'fixture generator\n' >"${source_root}/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js"
printf 'fixture ai skills\n' >"${source_root}/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs"
cat >"${temporary}/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
    printf 'v22.14.0\n'
else
    exec "${HELIUM_NINJA_TEST_REAL_NODE}" "$@"
fi
EOF
chmod 700 "${temporary}/bin/node"
boundary="${boundary_state}/full-graph-boundary.env"
(
    cd "${source_root}"
    PATH="${temporary}/bin:${PATH}" \
    HELIUM_BUILD_JOBS=1 HELIUM_REAL_NINJA="${fake_ninja}" \
    HELIUM_NINJA_TEST_ARGUMENTS="${arguments}" \
    HELIUM_NINJA_TEST_REAL_NODE="${real_node}" \
    HELIUM_FULL_GRAPH_JOB="${job}" \
    HELIUM_FULL_GRAPH_BOUNDARY_EPOCH="$(date +%s)" \
    HELIUM_FULL_GRAPH_SOURCE_ROOT="${source_root}" \
    HELIUM_FULL_GRAPH_RECEIPT="${boundary}" \
    HELIUM_FULL_GRAPH_AUDIT_TOOL="${repo_root}/scripts/linux-full-graph-audit.mjs" \
        "${shim}" -C out/Default chrome chromedriver
)
[ "$(stat -c %a "${boundary}")" = 400 ]
grep -Fqx 'schema=helium-fresh-full-graph-boundary-v1' "${boundary}"
grep -Fqx "job=${job}" "${boundary}"
grep -Fqx 'node_version=v22.14.0' "${boundary}"
grep -Fqx 'full_targets=chrome,chromedriver' "${boundary}"
grep -Fqx 'ui_css_outputs_materialized_before_full_build=false' "${boundary}"
grep -Fqx 'graph_validation=passed' "${boundary}"

grep -q 'HELIUM_REAL_NINJA=' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'PATH="${ninja_shim_dir}:${PATH}"' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -Fqx \
    'for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -Fqx '    [ "${!variable:-}" = 1 ] || {' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -Fq 'HELIUM_BUILD_JOBS=1' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
printf 'chromiumer_ninja_shim=passed\n'
