#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-pruned-inputs.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

source_root="$test_root/chromium"
mkdir -p \
  "$source_root/chrome/browser/preferences" \
  "$source_root/chrome/common" \
  "$source_root/components/safe_browsing/core/common" \
  "$source_root/components/signin/public/base" \
  "$source_root/third_party/r8"
: > "$source_root/OWNERS"
cat > "$source_root/chrome/browser/preferences/BUILD.gn" <<'EOF'
java_cpp_strings("java_pref_names_srcjar") {
  sources = [
    "//chrome/common/pref_names.h",
    "//components/safe_browsing/core/common/safe_browsing_prefs.h",
    "//components/signin/public/base/signin_pref_names.cc",
  ]

  class_name = "org.chromium.chrome.browser.preferences.Pref"
}
EOF
cat > "$source_root/chrome/browser/preferences/service-BUILD.gn" <<'EOF'
source_set("browser_preferences") {
  sources = [ "unrelated.cc" ]
}
EOF
printf 'inline constexpr char kHome[] = "home";\n' \
  > "$source_root/chrome/common/pref_names.h"
printf 'const char kSafeBrowsing[] = "safe";\n' \
  > "$source_root/components/safe_browsing/core/common/safe_browsing_prefs.cc"
printf 'inline constexpr char kSafeBrowsingEnabled[] = "safe.enabled";\n' \
  > "$source_root/components/safe_browsing/core/common/safe_browsing_prefs.h"
printf 'const char kSigninAllowed[] = "signin.allowed";\n' \
  > "$source_root/components/signin/public/base/signin_pref_names.cc"
printf 'extern const char kSigninAllowed[];\n' \
  > "$source_root/components/signin/public/base/signin_pref_names.h"
printf 'synthetic pinned custom D8\n' \
  > "$source_root/third_party/r8/custom_d8.jar"
printf 'synthetic pinned custom R8\n' \
  > "$source_root/third_party/r8/custom_r8.jar"

git -C "$source_root" init -q
git -C "$source_root" config user.name 'Helium Test'
git -C "$source_root" config user.email helium-test@invalid
git -C "$source_root" add .
git -C "$source_root" commit -qm 'synthetic Chromium'
pinned_commit=$(git -C "$source_root" rev-parse HEAD)

pruning_list="$test_root/pruning.list"
cat > "$pruning_list" <<'EOF'
components/safe_browsing/core/common/safe_browsing_prefs.cc
components/safe_browsing/core/common/safe_browsing_prefs.h
components/signin/public/base/signin_pref_names.cc
components/signin/public/base/signin_pref_names.h
third_party/r8/custom_d8.jar
third_party/r8/custom_r8.jar
EOF

for relative_path in \
  components/safe_browsing/core/common/safe_browsing_prefs.cc \
  components/safe_browsing/core/common/safe_browsing_prefs.h \
  components/signin/public/base/signin_pref_names.cc \
  components/signin/public/base/signin_pref_names.h \
  third_party/r8/custom_d8.jar \
  third_party/r8/custom_r8.jar; do
  find "$source_root/$relative_path" -maxdepth 0 -type f -delete
done

find "$source_root" -type f -name '*BUILD.gn' -print0 | sort -z | \
  xargs -0 sha256sum > "$test_root/build-files.before"
restore_output=$(
  "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
    "$source_root" "$pinned_commit" "$pruning_list"
)
[[ "$(grep -c '^restored_android_build_input=' <<< "$restore_output")" -eq 6 ]]
find "$source_root" -type f -name '*BUILD.gn' -print0 | sort -z | \
  xargs -0 sha256sum > "$test_root/build-files.after"
cmp "$test_root/build-files.before" "$test_root/build-files.after"
git -C "$source_root" diff --quiet -- \
  components/safe_browsing/core/common/safe_browsing_prefs.cc \
  components/safe_browsing/core/common/safe_browsing_prefs.h \
  components/signin/public/base/signin_pref_names.cc \
  components/signin/public/base/signin_pref_names.h \
  third_party/r8/custom_d8.jar \
  third_party/r8/custom_r8.jar

validator="$repo_root/scripts/chromium/validate-android-java-pref-inputs.sh"
"$validator" "$source_root" "$pinned_commit" | \
  grep -qx 'android_java_pref_inputs=verified count=3'

if "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
  "$source_root" "$pinned_commit" "$pruning_list" \
  > "$test_root/repeated.out" 2>&1; then
  echo 'repeated Android build-input restoration unexpectedly passed' >&2
  exit 1
fi
grep -q 'was not pruned before restoration' "$test_root/repeated.out"

sed -i '/signin_pref_names.cc/a\    "//missing/generated_pref_source.h",' \
  "$source_root/chrome/browser/preferences/BUILD.gn"
if "$validator" "$source_root" "$pinned_commit" \
  > "$test_root/missing.out" 2>&1; then
  echo 'missing Java pref generator source unexpectedly passed' >&2
  exit 1
fi
grep -qx 'missing java_pref_names_srcjar source: missing/generated_pref_source.h' \
  "$test_root/missing.out"
git -C "$source_root" show \
  "$pinned_commit:chrome/browser/preferences/BUILD.gn" \
  > "$source_root/chrome/browser/preferences/BUILD.gn"

printf 'tampered\n' \
  >> "$source_root/components/safe_browsing/core/common/safe_browsing_prefs.h"
if "$validator" "$source_root" "$pinned_commit" \
  > "$test_root/tampered.out" 2>&1; then
  echo 'tampered restored pref input unexpectedly passed' >&2
  exit 1
fi
grep -qx \
  'restored Android pref input does not match pinned Chromium: components/safe_browsing/core/common/safe_browsing_prefs.h' \
  "$test_root/tampered.out"

echo 'Android pruned build-input restoration and generator inventory passed'
