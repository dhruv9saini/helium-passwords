#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-pruned-inputs.XXXXXX")
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

source_root="$test_root/chromium"
mkdir -p \
  "$source_root/chrome/browser/preferences" \
  "$source_root/chrome/common" \
  "$source_root/components/privacy_sandbox/privacy_sandbox_attestations/preload" \
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
printf 'synthetic pinned Privacy Sandbox attestations\n' \
  > "$source_root/components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat"
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
components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat
components/safe_browsing/core/common/safe_browsing_prefs.cc
components/safe_browsing/core/common/safe_browsing_prefs.h
components/signin/public/base/signin_pref_names.cc
components/signin/public/base/signin_pref_names.h
third_party/r8/custom_d8.jar
third_party/r8/custom_r8.jar
EOF

for relative_path in \
  components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat \
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
    restore "$source_root" "$pinned_commit" "$pruning_list"
)
[[ "$(grep -c '^restore_android_build_input=' <<< "$restore_output")" -eq 7 ]]
attestations_blob=$(git -C "$source_root" rev-parse \
  "$pinned_commit:components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat")
d8_blob=$(git -C "$source_root" rev-parse \
  "$pinned_commit:third_party/r8/custom_d8.jar")
r8_blob=$(git -C "$source_root" rev-parse \
  "$pinned_commit:third_party/r8/custom_r8.jar")
grep -qx "restore_android_build_input=components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat blob=$attestations_blob" \
  <<< "$restore_output"
grep -qx "restore_android_build_input=third_party/r8/custom_d8.jar blob=$d8_blob" \
  <<< "$restore_output"
grep -qx "restore_android_build_input=third_party/r8/custom_r8.jar blob=$r8_blob" \
  <<< "$restore_output"
find "$source_root" -type f -name '*BUILD.gn' -print0 | sort -z | \
  xargs -0 sha256sum > "$test_root/build-files.after"
cmp "$test_root/build-files.before" "$test_root/build-files.after"
git -C "$source_root" diff --quiet -- \
  components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat \
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
  restore "$source_root" "$pinned_commit" "$pruning_list" \
  > "$test_root/repeated.out" 2>&1; then
  echo 'repeated Android build-input restoration unexpectedly passed' >&2
  exit 1
fi
grep -q 'was not pruned before restoration' "$test_root/repeated.out"

wrong_commit=0000000000000000000000000000000000000000
if "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
  validate "$source_root" "$wrong_commit" "$pruning_list" \
  > "$test_root/wrong-revision.out" 2>&1; then
  echo 'wrong Chromium revision unexpectedly passed build-input validation' >&2
  exit 1
fi
grep -qx 'Chromium source does not match the expected commit' \
  "$test_root/wrong-revision.out"

printf 'tampered R8\n' >> "$source_root/third_party/r8/custom_d8.jar"
if "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
  validate "$source_root" "$pinned_commit" "$pruning_list" \
  > "$test_root/tampered-r8.out" 2>&1; then
  echo 'tampered restored R8 input unexpectedly passed validation' >&2
  exit 1
fi
grep -qx \
  'restored Android build input does not match its pinned blob: third_party/r8/custom_d8.jar' \
  "$test_root/tampered-r8.out"
git -C "$source_root" show "$pinned_commit:third_party/r8/custom_d8.jar" \
  > "$source_root/third_party/r8/custom_d8.jar"

validate_output=$(
  "$repo_root/scripts/chromium/restore-android-pruned-build-inputs.sh" \
    validate "$source_root" "$pinned_commit" "$pruning_list"
)
[[ "$(grep -c '^validate_android_build_input=' <<< "$validate_output")" -eq 7 ]]
grep -qx "validate_android_build_input=components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat blob=$attestations_blob" \
  <<< "$validate_output"
grep -qx "validate_android_build_input=third_party/r8/custom_d8.jar blob=$d8_blob" \
  <<< "$validate_output"
grep -qx "validate_android_build_input=third_party/r8/custom_r8.jar blob=$r8_blob" \
  <<< "$validate_output"

out_dir="$source_root/out/Default"
mkdir -p "$out_dir"
cat > "$out_dir/build.ninja" <<'EOF'
rule package
  command = touch $out
build chrome_public_apk: package ../../components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat ../../components/safe_browsing/core/common/safe_browsing_prefs.h ../../components/signin/public/base/signin_pref_names.cc ../../third_party/r8/custom_d8.jar ../../third_party/r8/custom_r8.jar ../../chrome/common/pref_names.h
EOF
graph_validator="$repo_root/scripts/chromium/validate-android-pruned-build-graph.sh"
"$graph_validator" "$source_root" "$out_dir" "$pinned_commit" \
  "$pruning_list" chrome_public_apk | \
  grep -qx 'android_pruned_build_graph=verified target=chrome_public_apk count=5'

mkdir -p "$source_root/third_party/angle/third_party/r8"
printf 'synthetic ANGLE D8\n' \
  > "$source_root/third_party/angle/third_party/r8/custom_d8.jar"
printf '%s\n' 'third_party/angle/third_party/r8/custom_d8.jar' >> "$pruning_list"
cat > "$out_dir/build.ninja" <<'EOF'
rule package
  command = touch $out
build chrome_public_apk: package ../../components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat ../../components/safe_browsing/core/common/safe_browsing_prefs.h ../../components/signin/public/base/signin_pref_names.cc ../../third_party/r8/custom_d8.jar ../../third_party/r8/custom_r8.jar ../../third_party/angle/third_party/r8/custom_d8.jar
EOF
if "$graph_validator" "$source_root" "$out_dir" "$pinned_commit" \
  "$pruning_list" chrome_public_apk > "$test_root/unexpected-graph.out" 2>&1; then
  echo 'unexpected pruned Android graph input passed validation' >&2
  exit 1
fi
grep -q 'unexpected pruned Android target input:' \
  "$test_root/unexpected-graph.out"
grep -qx 'third_party/angle/third_party/r8/custom_d8.jar' \
  "$test_root/unexpected-graph.out"

sed -i '/third_party\/angle\/third_party\/r8\/custom_d8.jar/d' "$pruning_list"
cat > "$out_dir/build.ninja" <<'EOF'
rule package
  command = touch $out
build chrome_public_apk: package ../../components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat ../../components/safe_browsing/core/common/safe_browsing_prefs.h ../../components/signin/public/base/signin_pref_names.cc ../../third_party/r8/custom_d8.jar
EOF
if "$graph_validator" "$source_root" "$out_dir" "$pinned_commit" \
  "$pruning_list" chrome_public_apk > "$test_root/missing-graph.out" 2>&1; then
  echo 'incomplete pruned Android graph inventory passed validation' >&2
  exit 1
fi
grep -q 'expected pruned Android target input is unreachable:' \
  "$test_root/missing-graph.out"
grep -qx 'third_party/r8/custom_r8.jar' "$test_root/missing-graph.out"

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
