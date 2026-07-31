#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
patch_file="$repo_root/patches/helium-passwords/android-search-engine-api-compat.patch"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/helium-android-search-api.XXXXXX")
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p "$test_root/components/search_engines/android"
source_file="$test_root/components/search_engines/android/template_url_service_android.cc"

for ((line = 1; line < 449; line++)); do
  printf '\n'
done > "$source_file"
cat >> "$source_file" <<'EOF'
    if (regulatory_api_turl->safe_for_autoreplace()) {
      template_url_service_->ResetTemplateURL(
          regulatory_api_turl, regulatory_api_turl->short_name(),
          regulatory_api_turl->keyword(), regulatory_api_turl->url());
    }
  }

EOF
for ((line = 456; line < 503; line++)); do
  printf '\n'
done >> "$source_file"
cat >> "$source_file" <<'EOF'
    }
  }

  template_url_service_->ResetTemplateURL(template_url, short_name, new_keyword,
                                          search_url);
  return true;
}

EOF
for ((line = 511; line < 565; line++)); do
  printf '\n'
done >> "$source_file"
cat >> "$source_file" <<'EOF'
bool TemplateUrlServiceAndroid::IsSearchEngineUrlValidToAdd(
    JNIEnv* env,
    const std::string& new_url) {
  return IsSearchEngineURLValidToUse(new_url, template_url_service_,
                                     /*existing_url=*/nullptr);
}

bool TemplateUrlServiceAndroid::IsSearchEngineUrlValidToEdit(
    JNIEnv* env,
    const std::string& new_url,
    const std::u16string& current_keyword) {
  const TemplateURL* existing_url =
      template_url_service_->GetTemplateURLForKeyword(current_keyword);
  return IsSearchEngineURLValidToUse(new_url, template_url_service_,
                                     existing_url);
}

base::android::ScopedJavaLocalRef<jstring>
EOF

patch --batch --fuzz=0 -d "$test_root" -p1 < "$patch_file"

grep -Fq 'regulatory_api_turl->suggestions_url());' "$source_file"
grep -Fq 'template_url->suggestions_url());' "$source_file"
[[ "$(grep -Fc '/*is_new_primary=*/false);' "$source_file")" -eq 2 ]]
[[ "$(grep -Fc 'suggestions_url());' "$source_file")" -eq 2 ]]
! grep -Fq 'regulatory_api_turl->url());' "$source_file"
! grep -Fq '                                          search_url);' "$source_file"

[[ "$(grep -Fxc 'helium-passwords/android-search-engine-api-compat.patch' \
  "$repo_root/patches/series")" -eq 1 ]]
[[ "$(grep -c '^diff --git ' "$patch_file")" -eq 1 ]]

echo 'Android search-engine API compatibility patch passed'
