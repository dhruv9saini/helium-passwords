#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
patch_file="$repo_root/patches/helium-passwords/disable-android-safe-browsing-bridges.patch"
test_root=$(mktemp -d /tmp/helium-android-safe-browsing.XXXXXX)
cleanup() {
  find "$test_root" -depth -delete
}
trap cleanup EXIT

mkdir -p \
  "$test_root/chrome/browser/notifications/scheduler" \
  "$test_root/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing"

cat > "$test_root/chrome/browser/notifications/scheduler/tips_agent_android.cc" <<'EOF'
#include "components/browsing_data/core/pref_names.h"
#include "components/omnibox/browser/omnibox_prefs.h"
#include "components/prefs/pref_service.h"
#include "components/safe_browsing/core/common/safe_browsing_prefs.h"
#include "components/segmentation_platform/public/constants.h"
#include "components/segmentation_platform/public/features.h"
#include "components/segmentation_platform/public/segmentation_platform_service.h"

  // V1 Tips: ESB, Quick Delete, Google Lens, Bottom Omnibox

  bool is_enhanced_safe_browsing =
      safe_browsing::GetSafeBrowsingState(*pref_service) ==
      safe_browsing::SafeBrowsingState::ENHANCED_PROTECTION;
  input_context->metadata_args.emplace(
      segmentation_platform::kEnhancedSafeBrowsingStatus,
      segmentation_platform::processing::ProcessedValue(
          is_enhanced_safe_browsing));
EOF

cat > "$test_root/chrome/browser/safe_browsing/android/BUILD.gn" <<'EOF'
import("//third_party/jni_zero/jni_zero.gni")

generate_jni("jni_headers") {
  sources = [
    "java/src/org/chromium/chrome/browser/safe_browsing/AdvancedProtectionStatusManagerAndroidBridge.java",
    "java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java",
  ]
}

source_set("android") {
  sources = [ "safe_browsing_bridge.cc" ]
}

android_library("java") {
  sources = [
    "java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java",
  ]
}
EOF

cat > "$test_root/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java" <<'EOF'
// Copyright 2019 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package org.chromium.chrome.browser.safe_browsing;

import android.content.Intent;

import androidx.annotation.VisibleForTesting;

import org.jni_zero.JNINamespace;
import org.jni_zero.JniType;
import org.jni_zero.NativeMethods;

import org.chromium.build.annotations.NullMarked;
import org.chromium.chrome.browser.profiles.Profile;
import org.chromium.content_public.browser.WebContents;

/** Bridge providing access to native-side Safe Browsing data. */
@JNINamespace("safe_browsing")
@NullMarked
public final class SafeBrowsingBridge {
    private final Profile mProfile;

    /** Constructs a {@link SafeBrowsingBridge} associated with the given {@link Profile}. */
    public SafeBrowsingBridge(Profile profile) {
        mProfile = profile;
    }

    /**
     * Reports UMA values based on files' extensions.
     *
     * @param path The file path.
     * @return The UMA value for the file.
     */
    public static int umaValueForFile(String path) {
        return SafeBrowsingBridgeJni.get().umaValueForFile(path);
    }

    /**
     * @return Whether Safe Browsing Extended Reporting is currently enabled.
     */
    public boolean isSafeBrowsingExtendedReportingEnabled() {
        return SafeBrowsingBridgeJni.get().getSafeBrowsingExtendedReportingEnabled(mProfile);
    }

    /**
     * @param enabled Whether Safe Browsing Extended Reporting should be enabled.
     */
    public void setSafeBrowsingExtendedReportingEnabled(boolean enabled) {
        SafeBrowsingBridgeJni.get().setSafeBrowsingExtendedReportingEnabled(mProfile, enabled);
    }

    /** Set the Safe Browsing setting set locally pref as true. */
    public void enableSafeBrowsingSettingSetLocallyPref() {
        SafeBrowsingBridgeJni.get().enableSafeBrowsingSettingSetLocallyPref(mProfile);
    }

    /**
     * @return Whether Safe Browsing Extended Reporting is managed
     */
    public boolean isSafeBrowsingExtendedReportingManaged() {
        return SafeBrowsingBridgeJni.get().getSafeBrowsingExtendedReportingManaged(mProfile);
    }

    /**
     * @return The Safe Browsing state. It can be Enhanced Protection, Standard Protection, or No
     *     Protection.
     */
    public @SafeBrowsingState int getSafeBrowsingState() {
        return SafeBrowsingBridgeJni.get().getSafeBrowsingState(mProfile);
    }

    /**
     * @param state Set the Safe Browsing state. It can be Enhanced Protection, Standard Protection,
     *     or No Protection.
     */
    public void setSafeBrowsingState(@SafeBrowsingState int state) {
        SafeBrowsingBridgeJni.get().setSafeBrowsingState(mProfile, state);
    }

    /**
     * @return Whether the Safe Browsing preference is managed. It can be managed by either the
     *     SafeBrowsingEnabled policy(legacy) or the SafeBrowsingProtectionLevel policy(new).
     */
    public boolean isSafeBrowsingManaged() {
        return SafeBrowsingBridgeJni.get().isSafeBrowsingManaged(mProfile);
    }

    /**
     * @return Whether hash real-time lookup is enabled.
     */
    public static boolean isHashRealTimeLookupEligibleInSession() {
        return SafeBrowsingBridgeJni.get().isHashRealTimeLookupEligibleInSession();
    }

    /**
     * Report an intent sent to open an external app. This may be summarized and sent to Safe
     * Browsing.
     *
     * @param webContents The WebContents that triggered the intent
     * @param intent The intent Chrome generated
     */
    public static void reportIntent(WebContents webContents, Intent intent) {
        String packageName;
        if (intent.getComponent() != null) {
            packageName = intent.getComponent().getPackageName();
        } else if (intent.getPackage() != null) {
            packageName = intent.getPackage();
        } else {
            packageName = "";
        }

        String uri = "";
        if (intent.getData() != null) {
            uri = intent.getData().toString();
        }

        SafeBrowsingBridgeJni.get().reportIntent(webContents, packageName, uri);
    }

    @NativeMethods
    @VisibleForTesting(otherwise = VisibleForTesting.PACKAGE_PRIVATE)
    public interface Natives {
        int umaValueForFile(String path);

        boolean getSafeBrowsingExtendedReportingEnabled(Profile profile);

        void setSafeBrowsingExtendedReportingEnabled(Profile profile, boolean enabled);

        boolean getSafeBrowsingExtendedReportingManaged(Profile profile);

        @SafeBrowsingState
        int getSafeBrowsingState(Profile profile);

        void setSafeBrowsingState(Profile profile, @SafeBrowsingState int state);

        void enableSafeBrowsingSettingSetLocallyPref(Profile profile);

        boolean isSafeBrowsingManaged(Profile profile);

        boolean isHashRealTimeLookupEligibleInSession();

        void reportIntent(
                @JniType("content::WebContents*") WebContents webContents,
                @JniType("std::string") String packageName,
                @JniType("std::string") String uri);
    }
}
EOF

filtered_patch="$test_root/safe-browsing.patch"
awk '
  /^diff --git / {
    keep = ($3 == "a/chrome/browser/notifications/scheduler/tips_agent_android.cc" ||
            $3 == "a/chrome/browser/safe_browsing/android/BUILD.gn" ||
            $3 == "a/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java")
  }
  keep { print }
' "$patch_file" > "$filtered_patch"
patch --batch --fuzz=0 -d "$test_root" -p1 < "$filtered_patch"

tips="$test_root/chrome/browser/notifications/scheduler/tips_agent_android.cc"
bridge_build="$test_root/chrome/browser/safe_browsing/android/BUILD.gn"
bridge_java="$test_root/chrome/browser/safe_browsing/android/java/src/org/chromium/chrome/browser/safe_browsing/SafeBrowsingBridge.java"

grep -Fqx '  bool is_enhanced_safe_browsing = false;' "$tips"
! grep -Fq 'safe_browsing_prefs.h' "$tips"
! grep -Fq 'safe_browsing::' "$tips"

[[ "$(grep -Fc 'SafeBrowsingBridge.java' "$bridge_build")" -eq 1 ]]
grep -Fq 'source_set("android") {' "$bridge_build"
grep -Fq 'sources = [ "safe_browsing_bridge.cc" ]' "$bridge_build"
! sed -n '/generate_jni("jni_headers") {/,/^}/p' "$bridge_build" | \
  grep -Fq 'SafeBrowsingBridge.java'

grep -Fqx '        return SafeBrowsingState.NO_SAFE_BROWSING;' "$bridge_java"
[[ "$(grep -Fc '        return false;' "$bridge_java")" -eq 4 ]]
grep -Fqx '        return 0;' "$bridge_java"
grep -Fqx '    public static void reportIntent(WebContents webContents, Intent intent) {}' \
  "$bridge_java"
! grep -Eq 'SafeBrowsingBridgeJni|NativeMethods|JNINamespace|JniType|mProfile' \
  "$bridge_java"

grep -qx 'helium-passwords/disable-android-safe-browsing-bridges.patch' \
  <(tail -1 "$repo_root/patches/series")
[[ "$(grep -c '^diff --git ' "$filtered_patch")" -eq 3 ]]
! grep -Fq 'SafeBrowsingBridge_jni.h' "$patch_file"

git apply --stat "$patch_file" >/dev/null
[[ "$(grep -c '^diff --git ' "$patch_file")" -eq 12 ]]
for source_path in \
  chrome/browser/safety_hub/android/java/src/org/chromium/chrome/browser/safety_hub/SafetyHubMagicStackMediator.java \
  chrome/browser/signin/services/android/java/src/org/chromium/chrome/browser/signin/services/SigninManagerImpl.java \
  chrome/android/java/src/org/chromium/chrome/browser/identity_disc/IdentityDiscController.java \
  chrome/android/java/src/org/chromium/chrome/browser/sync/settings/GoogleServicesSettings.java \
  chrome/android/java/src/org/chromium/chrome/browser/sync/settings/SignInPreference.java \
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/SigninAndHistorySyncCoordinator.java \
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/fullscreen_signin/FullscreenSigninMediator.java \
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/FullscreenSigninPromoLauncher.java \
  chrome/browser/ui/android/signin/java/src/org/chromium/chrome/browser/ui/signin/history_sync/HistorySyncHelper.java; do
  grep -Fq "diff --git a/$source_path b/$source_path" "$patch_file"
done

for pref_name in \
  SAFE_BROWSING_ENABLED \
  SIGNIN_ALLOWED \
  GOOGLE_SERVICES_LAST_SYNCING_USERNAME \
  HISTORY_SYNC_LAST_DECLINED_TIMESTAMP \
  HISTORY_SYNC_SUCCESSIVE_DECLINE_COUNT; do
  grep -Fq "Pref.$pref_name" "$patch_file"
  ! grep '^+' "$patch_file" | grep -Fq "Pref.$pref_name"
done

grep '^+' "$patch_file" | grep -Fq \
  'mSyncService.setSelectedType(UserSelectableType.TABS, false);'
! grep '^+' "$patch_file" | grep -Eq \
  'setSelectedType\(UserSelectableType\.TABS, (true|turnTypesOn)\)'
! grep '^+' "$patch_file" | grep -Eq \
  'SafeBrowsingBridgeJni|@NativeMethods|SafeBrowsingBridge_jni\.h'

echo 'Android pruned-service consumers are explicit disabled no-ops'
