#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/helium-android-git-series.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

mkdir -p "$test_root/source/components/payments/core" "$test_root/patches/passwords"
cat > "$test_root/source/components/payments/core/payment_prefs.cc" <<'EOF'
// Copyright 2017 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/payments/core/payment_prefs.h"

#include "components/pref_registry/pref_registry_syncable.h"

namespace payments {

void RegisterProfilePrefs(user_prefs::PrefRegistrySyncable* registry) {
  registry->RegisterBooleanPref(kPaymentsFirstTransactionCompleted, false);
  registry->RegisterBooleanPref(
      kCanMakePaymentEnabled, false,
      user_prefs::PrefRegistrySyncable::SYNCABLE_PREF);
}

}  // namespace payments
EOF
cat > "$test_root/patches/passwords/restore-payment-pref.patch" <<'EOF'
--- a/components/payments/core/payment_prefs.cc
+++ b/components/payments/core/payment_prefs.cc
@@ -11,6 +11,6 @@ namespace payments {
 void RegisterProfilePrefs(user_prefs::PrefRegistrySyncable* registry) {
   registry->RegisterBooleanPref(kPaymentsFirstTransactionCompleted, false);
   registry->RegisterBooleanPref(
-      kCanMakePaymentEnabled, false,
+      kCanMakePaymentEnabled, true,
       user_prefs::PrefRegistrySyncable::SYNCABLE_PREF);
 }
EOF
printf '%s\n' 'passwords/restore-payment-pref.patch' > "$test_root/patches/series"

git -C "$test_root/source" init --quiet
git -C "$test_root/source" add .
git -C "$test_root/source" \
  -c user.name='Helium test' -c user.email='test@helium.invalid' \
  commit --quiet --message fixture

"$repo_root/scripts/chromium/apply-git-series.sh" \
  "$test_root/patches/series" "$test_root/patches" "$test_root/source"
grep -q 'kCanMakePaymentEnabled, true' \
  "$test_root/source/components/payments/core/payment_prefs.cc"

if "$repo_root/scripts/chromium/apply-git-series.sh" \
  "$test_root/patches/series" "$test_root/patches" "$test_root/source" \
  > "$test_root/reapply.out" 2>&1; then
  echo 'already-applied password series unexpectedly passed' >&2
  exit 1
fi
grep -q 'patch does not apply' "$test_root/reapply.out"

printf '%s\n' '../escape.patch' > "$test_root/patches/unsafe-series"
if "$repo_root/scripts/chromium/apply-git-series.sh" \
  "$test_root/patches/unsafe-series" "$test_root/patches" "$test_root/source" \
  > "$test_root/unsafe.out" 2>&1; then
  echo 'unsafe password series entry unexpectedly passed' >&2
  exit 1
fi
grep -q 'unsafe patch series entry' "$test_root/unsafe.out"

grep -Fq 'apply-git-series.sh' \
  "$repo_root/scripts/chromium/apply-android-backbone.sh"
echo 'Android Git-series executor contract passed'
