#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
chromium_version="$(tr -d '\r\n' <"${root_dir}/helium-chromium/chromium_version.txt")"
fixture="$(mktemp -d /tmp/helium-password-source.XXXXXX)"
case "${fixture}" in
    /tmp/helium-password-source.*) ;;
    *) echo "unexpected fixture path: ${fixture}" >&2; exit 1 ;;
esac
cleanup() {
    find "${fixture}" -depth -delete
}
trap cleanup EXIT

files=(
    components/autofill/core/common/autofill_prefs.cc
    components/password_manager/core/browser/password_manager.cc
    components/payments/core/payment_prefs.cc
    chrome/browser/resources/settings/settings_menu/settings_menu.html
    chrome/browser/resources/settings/route.ts
    chrome/browser/resources/settings/settings_ui/settings_ui.ts
    chrome/browser/resources/settings/settings_main/settings_main.html
    chrome/browser/importer/importer_list.cc
    components/password_manager/core/browser/password_suggestion_generator.cc
    chrome/browser/ui/omnibox/omnibox_pedal_implementations.cc
    chrome/browser/ui/views/location_bar/location_bar_view.cc
    chrome/browser/ui/browser_actions.cc
    chrome/browser/ui/web_applications/app_browser_controller.cc
    chrome/browser/ui/webui/side_panel/customize_chrome/customize_toolbar/customize_toolbar_handler.cc
    chrome/browser/ui/toolbar/app_menu_model.cc
)

for file in "${files[@]}"; do
    mkdir -p "${fixture}/$(dirname "${file}")"
    curl --retry 4 --retry-delay 1 --fail --silent --show-error --location \
        "https://chromium.googlesource.com/chromium/src/+/refs/tags/${chromium_version}/${file}?format=TEXT" \
        | base64 --decode >"${fixture}/${file}"
done

git -C "${fixture}" init --quiet
git -C "${fixture}" config user.name "Helium Passwords source check"
git -C "${fixture}" config user.email "source-check@helium-passwords.invalid"
git -C "${fixture}" add .
git -C "${fixture}" commit --quiet --message chromium

include_args=(
    --include=components/policy/core/common/helium_opinionated_policy_provider.cc
)
for file in "${files[@]}"; do
    include_args+=("--include=${file}")
done

while IFS= read -r patch_path; do
    patch_path="${patch_path%$'\r'}"
    case "${patch_path}" in
        ""|\#*) continue ;;
        helium/hop/disable-password-manager.patch) continue ;;
    esac

    patch_file="${root_dir}/helium-chromium/patches/${patch_path}"
    [ -f "${patch_file}" ] || continue
    if git -C "${fixture}" apply "${include_args[@]}" --numstat "${patch_file}" \
        | grep -q .; then
        git -C "${fixture}" apply "${include_args[@]}" "${patch_file}"
    fi
done <"${root_dir}/helium-chromium/patches/series"

for patch_path in \
    helium-passwords/restore-password-autofill.patch \
    helium-passwords/restore-password-ui.patch; do
    git -C "${fixture}" apply --check "${root_dir}/patches/${patch_path}"
    git -C "${fixture}" apply "${root_dir}/patches/${patch_path}"
done

grep -q 'kCredentialsEnableService, true' \
    "${fixture}/components/password_manager/core/browser/password_manager.cc"
grep -q 'PageActionIconType::kSaveCard' \
    "${fixture}/chrome/browser/ui/views/location_bar/location_bar_view.cc"
grep -q 'kActionShowPasswordsBubbleOrPage' \
    "${fixture}/chrome/browser/ui/browser_actions.cc"
grep -q 'PageActionIconType::kManagePasswords' \
    "${fixture}/chrome/browser/ui/web_applications/app_browser_controller.cc"
grep -q 'PasswordsAndAutofillSubMenuModel' \
    "${fixture}/chrome/browser/ui/toolbar/app_menu_model.cc"
grep -q 'maybeRedirectLegacyPasswordSettingsUrl' \
    "${fixture}/chrome/browser/resources/settings/settings_ui/settings_ui.ts"
if grep -q 'kPasswordManagerEnabled' \
    "${fixture}/components/policy/core/common/helium_opinionated_policy_provider.cc"; then
    echo "password-manager policy disable survived focused patch replay" >&2
    exit 1
fi

printf 'password patch stack applies to Chromium %s\n' "${chromium_version}"
