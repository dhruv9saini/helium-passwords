#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
shim="${repo_root}/scripts/chromiumer-bin/ninja"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-ninja-shim.XXXXXX")
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT

fake_ninja="${temporary}/real-ninja"
arguments="${temporary}/arguments"
cat >"${fake_ninja}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${HELIUM_NINJA_TEST_ARGUMENTS}"
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
