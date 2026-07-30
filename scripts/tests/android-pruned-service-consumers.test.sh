#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-mode0-validator.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

declare -A fixtures=(
  [chrome/browser/notifications/scheduler/tips_agent_android.cc]=$'  bool is_enhanced_safe_browsing = false;\n'
  [chrome/browser/safe_browsing/android/BUILD.gn]=$'generate_jni("jni_headers") {\n  sources = [ "AdvancedProtectionStatusManagerAndroidBridge.java" ]\n}\n'
  [chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java]=$'public final class SafeBrowsingBridge {\n    public @SafeBrowsingState int getSafeBrowsingState() {\n        return SafeBrowsingState.NO_SAFE_BROWSING;\n    }\n    public static void reportIntent(WebContents webContents, Intent intent) {}\n}\n'
  [chrome/browser/safety_hub/android/java/src/org/chromium/chrome/browser/safety_hub/SafetyHubMagicStackMediator.java]=$'class SafetyHubMagicStackMediator {\n    void showModule() {\n        mModuleDelegate.onDataFetchFailed(ModuleType.SAFETY_HUB);\n    }\n}\n'
  [chrome/browser/signin/services/android/java/src/org/chromium/chrome/browser/signin/services/SigninManagerImpl.java]=$'class SigninManagerImpl {\n    public boolean isSigninAllowed() {\n        return false;\n    }\n    public boolean isSwitchAccountAllowed() {\n        return false;\n    }\n}\n'
  [chrome/android/java/src/org/chromium/chrome/browser/identity_disc/IdentityDiscController.java]=$'class IdentityDiscController {\n    void onClick() {\n        if (mProfile == null || getSignedInAccountInfo() == null) {\n            return;\n        }\n    }\n}\n'
  [chrome/android/java/src/org/chromium/chrome/browser/sync/settings/GoogleServicesSettings.java]=$'class GoogleServicesSettings {\n    private static boolean shouldShowAllowSignIn(Profile profile) {\n        return false;\n    }\n}\n'
  [chrome/android/java/src/org/chromium/chrome/browser/sync/settings/SignInPreference.java]=$'class SignInPreference {\n    private void update() {\n        setupSigninDisallowed();\n        setVisible(false);\n    }\n}\n'
  [chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/SigninAndHistorySyncCoordinator.java]=$'class SigninAndHistorySyncCoordinator {\n    public static boolean canStartSigninAndHistorySyncOrShowError(\n            Context context) {\n        Toast.makeText(context, "unavailable", Toast.LENGTH_LONG).show();\n        return false;\n    }\n}\n'
  [chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/fullscreen_signin/FullscreenSigninMediator.java]=$'class FullscreenSigninMediator {\n    private boolean isSigninSupported(Profile profile) {\n        return false;\n    }\n}\n'
  [chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/FullscreenSigninPromoLauncher.java]=$'class FullscreenSigninPromoLauncher {\n    public static boolean launchPromoIfNeeded(Context context) {\n        return false;\n    }\n    public static boolean launchPromoIfForced(Context context) {\n        return false;\n    }\n}\n'
  [chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/history_sync/HistorySyncHelper.java]=$'class HistorySyncHelper {\n    public boolean shouldDisplayHistorySync() {\n        return false;\n    }\n    public boolean isDeclinedOften() {\n        return false;\n    }\n    public void recordHistorySyncDeclinedPrefs() {}\n    public void clearHistorySyncDeclinedPrefs() {}\n    public void setHistoryAndTabsSync(boolean turnTypesOn) {\n        mSyncService.setSelectedType(UserSelectableType.HISTORY, false);\n        mSyncService.setSelectedType(UserSelectableType.TABS, false);\n    }\n}\n'
  [components/enterprise/connectors/core/cloud_content_scanning/cloud_binary_upload_service_base.cc]=$'void CloudBinaryUploadServiceBase::LogResponseDebugInfo(\n    const std::string& upload_info,\n    ScanRequestUploadResult result,\n    BinaryUploadRequest* request,\n    const ContentAnalysisResponse& response) {\n}\n'
)

for relative_file in "${!fixtures[@]}"; do
  mkdir -p "$test_root/$(dirname "$relative_file")"
  printf '%s' "${fixtures[$relative_file]}" > "$test_root/$relative_file"
done

validator="$repo_root/scripts/chromium/validate-android-pruned-service-consumers.sh"
"$validator" "$test_root" | \
  grep -qx 'android_pruned_service_consumers=verified files=13'

history="$test_root/chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/history_sync/HistorySyncHelper.java"
sed -i 's/UserSelectableType.TABS, false/UserSelectableType.TABS, true/' "$history"
if "$validator" "$test_root" > "$test_root/tab.out" 2>&1; then
  echo 'tab-sync enable path unexpectedly passed' >&2
  exit 1
fi
grep -q 'can enable cross-device tab sync' "$test_root/tab.out"
sed -i 's/UserSelectableType.TABS, true/UserSelectableType.TABS, false/' "$history"

bridge="$test_root/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java"
sed -i '/public final class/a\    private SafeBrowsingBridgeJni phantom;' "$bridge"
if "$validator" "$test_root" > "$test_root/jni.out" 2>&1; then
  echo 'phantom Safe Browsing JNI unexpectedly passed' >&2
  exit 1
fi
grep -q 'retains a phantom native path' "$test_root/jni.out"
sed -i '/SafeBrowsingBridgeJni phantom/d' "$bridge"

signin="$test_root/chrome/browser/signin/services/android/java/src/org/chromium/chrome/browser/signin/services/SigninManagerImpl.java"
sed -i '/class SigninManagerImpl/a\    private String stale = Pref.SIGNIN_ALLOWED;' "$signin"
if "$validator" "$test_root" > "$test_root/pref.out" 2>&1; then
  echo 'unregistered preference consumer unexpectedly passed' >&2
  exit 1
fi
grep -q 'reads an unregistered preference' "$test_root/pref.out"
sed -i '/private String stale = Pref.SIGNIN_ALLOWED;/d' "$signin"

cloud_upload="$test_root/components/enterprise/connectors/core/cloud_content_scanning/cloud_binary_upload_service_base.cc"
sed -i '/^}/i\\  safe_browsing::WebUIContentInfoSingleton::GetInstance()->AddToDeepScanRequests();' \
  "$cloud_upload"
if "$validator" "$test_root" > "$test_root/deep-scan.out" 2>&1; then
  echo 'enterprise deep-scan WebUI call unexpectedly passed' >&2
  exit 1
fi
grep -q 'retains an enterprise deep-scan WebUI call' \
  "$test_root/deep-scan.out"

echo 'Android pruned-service source validator passed'
