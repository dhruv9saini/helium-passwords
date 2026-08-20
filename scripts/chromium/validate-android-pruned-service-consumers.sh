#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'usage: validate-android-pruned-service-consumers.sh CHROMIUM_SRC' >&2
  exit 2
fi

chromium_src=$(realpath -e "$1")

relative_files=(
  chrome/browser/notifications/scheduler/tips_agent_android.cc
  chrome/browser/safe_browsing/android/BUILD.gn
  chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java
  chrome/browser/safety_hub/android/java/src/org/chromium/chrome/browser/safety_hub/SafetyHubMagicStackMediator.java
  chrome/browser/signin/services/android/java/src/org/chromium/chrome/browser/signin/services/SigninManagerImpl.java
  chrome/android/java/src/org/chromium/chrome/browser/identity_disc/IdentityDiscController.java
  chrome/android/java/src/org/chromium/chrome/browser/sync/settings/GoogleServicesSettings.java
  chrome/android/java/src/org/chromium/chrome/browser/sync/settings/SignInPreference.java
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/SigninAndHistorySyncCoordinator.java
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/fullscreen_signin/FullscreenSigninMediator.java
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/FullscreenSigninPromoLauncher.java
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/history_sync/HistorySyncHelper.java
  components/enterprise/connectors/core/cloud_content_scanning/cloud_binary_upload_service_base.cc
)

source_files=()
for relative_file in "${relative_files[@]}"; do
  source_file="$chromium_src/$relative_file"
  [ -f "$source_file" ] && [ ! -L "$source_file" ] || {
    echo "missing regular Android mode-0 source: $relative_file" >&2
    exit 1
  }
  source_files+=("$source_file")
done

forbidden_pref='Pref\.(SAFE_BROWSING_ENABLED|SIGNIN_ALLOWED|GOOGLE_SERVICES_LAST_SYNCING_USERNAME|HISTORY_SYNC_LAST_DECLINED_TIMESTAMP|HISTORY_SYNC_SUCCESSIVE_DECLINE_COUNT)'
if rg -n --no-heading "$forbidden_pref" "${source_files[@]}" >&2; then
  echo 'Android mode-0 source reads an unregistered preference' >&2
  exit 1
fi

tips="$chromium_src/chrome/browser/notifications/scheduler/tips_agent_android.cc"
grep -Fqx '  bool is_enhanced_safe_browsing = false;' "$tips"
! rg -q 'safe_browsing_prefs\.h|safe_browsing::GetSafeBrowsingState' "$tips"

bridge_build="$chromium_src/chrome/browser/safe_browsing/android/BUILD.gn"
if sed -n '/generate_jni("jni_headers") {/,/^}/p' "$bridge_build" | \
  grep -Fq 'SafeBrowsingBridge.java'; then
  echo 'SafeBrowsingBridge remains a generated JNI input' >&2
  exit 1
fi

bridge="$chromium_src/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java"
if rg -n 'SafeBrowsingBridgeJni|@NativeMethods|JNINamespace|JniType' "$bridge" >&2; then
  echo 'SafeBrowsingBridge retains a phantom native path' >&2
  exit 1
fi
grep -Fqx '        return SafeBrowsingState.NO_SAFE_BROWSING;' "$bridge"
grep -Fqx '    public static void reportIntent(WebContents webContents, Intent intent) {}' "$bridge"

method_block() {
  local source_file=$1
  local signature=$2
  awk -v signature="$signature" '
    index($0, signature) { active = 1 }
    active { print }
    active && $0 == "    }" { exit }
  ' "$source_file"
}

require_false_method() {
  local source_file=$1
  local signature=$2
  method_block "$source_file" "$signature" | grep -Fqx '        return false;'
}

safety_hub="$chromium_src/chrome/browser/safety_hub/android/java/src/org/chromium/chrome/browser/safety_hub/SafetyHubMagicStackMediator.java"
grep -Fq 'mModuleDelegate.onDataFetchFailed(ModuleType.SAFETY_HUB);' "$safety_hub"
! grep -Fq 'bindSafeBrowsingView(magicStackEntry.getDescription())' "$safety_hub"
! grep -Fq 'onSafeBrowsingChanged' "$safety_hub"

signin_manager="$chromium_src/chrome/browser/signin/services/android/java/src/org/chromium/chrome/browser/signin/services/SigninManagerImpl.java"
require_false_method "$signin_manager" 'public boolean isSigninAllowed()'
require_false_method "$signin_manager" 'public boolean isSwitchAccountAllowed()'
! grep -Fq 'PrefChangeRegistrar mPrefChangeRegistrar' "$signin_manager"

identity_disc="$chromium_src/chrome/android/java/src/org/chromium/chrome/browser/identity_disc/IdentityDiscController.java"
method_block "$identity_disc" 'void onClick()' | \
  grep -Fq 'if (mProfile == null || getSignedInAccountInfo() == null) {'

google_services="$chromium_src/chrome/android/java/src/org/chromium/chrome/browser/sync/settings/GoogleServicesSettings.java"
require_false_method "$google_services" 'private static boolean shouldShowAllowSignIn('
! grep -Fq 'mAllowSignin' "$google_services"

signin_preference="$chromium_src/chrome/android/java/src/org/chromium/chrome/browser/sync/settings/SignInPreference.java"
method_block "$signin_preference" 'private void update()' | \
  grep -Fqx '        setupSigninDisallowed();'
method_block "$signin_preference" 'private void update()' | \
  grep -Fqx '        setVisible(false);'

coordinator="$chromium_src/chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/SigninAndHistorySyncCoordinator.java"
method_block "$coordinator" 'public static boolean canStartSigninAndHistorySyncOrShowError(' | \
  grep -Fq 'Toast.makeText('

fullscreen="$chromium_src/chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/fullscreen_signin/FullscreenSigninMediator.java"
require_false_method "$fullscreen" 'private boolean isSigninSupported('

promo="$chromium_src/chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/FullscreenSigninPromoLauncher.java"
require_false_method "$promo" 'public static boolean launchPromoIfNeeded('
require_false_method "$promo" 'public static boolean launchPromoIfForced('

history="$chromium_src/chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/history_sync/HistorySyncHelper.java"
require_false_method "$history" 'public boolean shouldDisplayHistorySync()'
require_false_method "$history" 'public boolean isDeclinedOften()'
grep -Fqx '    public void recordHistorySyncDeclinedPrefs() {}' "$history"
grep -Fqx '    public void clearHistorySyncDeclinedPrefs() {}' "$history"
if grep -En 'setSelectedType\(UserSelectableType\.TABS, (true|turnTypesOn)\)' \
  "$history" >&2; then
  echo 'Android history helper can enable cross-device tab sync' >&2
  exit 1
fi
grep -Fqx '        mSyncService.setSelectedType(UserSelectableType.TABS, false);' "$history"

cloud_upload="$chromium_src/components/enterprise/connectors/core/cloud_content_scanning/cloud_binary_upload_service_base.cc"
cloud_debug_block=$(sed -n \
  '/^void CloudBinaryUploadServiceBase::LogResponseDebugInfo(/,/^}/p' \
  "$cloud_upload")
grep -Fq 'void CloudBinaryUploadServiceBase::LogResponseDebugInfo(' \
  <<<"$cloud_debug_block"
if grep -En 'WebUIContentInfoSingleton|AddToDeepScan(Requests|Responses)' \
  <<<"$cloud_debug_block" >&2; then
  echo 'disabled Safe Browsing retains an enterprise deep-scan WebUI call' >&2
  exit 1
fi

echo 'android_pruned_service_consumers=verified files=13'
