#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = relative => fs.readFileSync(path.join(root, relative), "utf8");

const source = read(
  "chromium/overlay/chrome/browser/helium_sync/helium_native_recovery_bridge.cc",
);
const header = read(
  "chromium/overlay/chrome/browser/helium_sync/helium_native_recovery_bridge.h",
);
const build = read("chromium/overlay/chrome/browser/helium_sync/BUILD.gn");
const service = read(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc",
);
const desktop = read("scripts/laptop/start-helium-sync-local.sh");
const android = read(
  "scripts/android-local/configure-android-chromium-sync.sh",
);
const androidBackup = read(
  "scripts/android-local/backup-android-native-recovery.sh",
);
const scheduler = read("scripts/native-recovery/install-scheduler.sh");
const fleetFinalizer = read("scripts/android-acceptance/full-e2e.mjs");
const runtimeDrill = read("scripts/native-recovery/runtime-drill.sh");
const androidBoundary = read("scripts/android-media/disposable-browser.sh");

assert.match(header, /browser-native, neutral password and cookie snapshots/);
assert.match(build, /helium_native_recovery_bridge\.cc/);
assert.match(build, /\/\/components\/password_manager\/core\/browser\/sync/);
assert.match(build, /\/\/components\/sync\/protocol/);

for (const required of [
  "PasswordStoreInterface", "GetAllLogins", "AddLogins",
  "SpecificsDataFromStoredCredential", "StoredCredentialFromSpecifics",
  "network::mojom::CookieManager", "GetAllCookies", "SetCanonicalCookie",
  "CookiePartitionKey::Serialize", "FromUntrustedInput",
  "helium-restore-disposable-native-passwords",
  "helium-restore-disposable-native-cookies",
  ".helium-native-recovery-disposable-profile-v1",
  ".helium-native-recovery-root-v1",
  "passwords.current.json", "cookies.current.json",
  "chromium-password-specifics-neutral-v1",
  "chromium-cookie-manager-neutral-v1",
  "records_sha256", "state_sha256",
]) {
  assert.match(source, new RegExp(required.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
}

assert.doesNotMatch(source, /Login Data|Cookies-journal|sqlite|sql::/i);
assert.doesNotMatch(source, /bitwarden|passwordsPrivate|devtools|CDP|extension/i);
assert.match(source, /PrivateRegularFile/);
assert.match(source, /permissions != 0600/);
assert.match(source, /permissions != 0700/);
assert.match(source, /restore_kind_ == RestoreKind::kPasswords/);
assert.match(source, /restore_kind_ == RestoreKind::kCookies/);
assert.match(source, /requires an empty disposable store/);
assert.match(source, /native password recovery readback mismatch/);
assert.match(source, /native cookie recovery readback mismatch/);
assert.match(source,
  /restored->records_sha256 != expected_cookies_->records_sha256/);

const dedicated = service.indexOf(
  "HeliumNativeRecoveryBridge::IsRestoreRequested()",
);
const enrollment = service.indexOf("const base::FilePath config_dir");
assert.ok(dedicated >= 0 && enrollment > dedicated);
assert.match(service.slice(dedicated, enrollment), /return;/);
assert.match(service, /kNativeRecoveryRootFile\[\] = "native_recovery_root"/);
assert.match(service, /recovery_bridge_->Start\(\)/);
assert.match(service, /recovery_bridge_->Stop\(\)/);

assert.match(desktop, /\.local\/share\/helium-native-recovery\/\$device_id\/default/);
assert.match(desktop, /native_recovery_root/);
assert.match(android, /files\/helium-native-recovery\/oneplus\/default/);
assert.match(android, /native_recovery_root/);
assert.match(androidBackup,
  /CHROMIUM_ANDROID_PACKAGE:-computer\.helium\.sync\.test/);
assert.match(androidBackup,
  /\[\[ "\$package" == computer\.helium\.sync\.test \]\]/);
assert.match(androidBackup, /verify-snapshot-stream/);
assert.match(androidBackup, /--max-age-seconds 600/);
assert.doesNotMatch(scheduler,
  /\/data\/user\/0\/computer\.helium\.sync\/\*/);

assert.match(fleetFinalizer,
  /auditDeviceFinal as auditNativeRecoveryDevice/);
assert.match(fleetFinalizer, /--d-native-recovery-receipt/);
assert.match(fleetFinalizer, /--da-native-recovery-receipt/);
assert.match(fleetFinalizer, /--oneplus-native-recovery-receipt/);
assert.match(fleetFinalizer,
  /native recovery .* does not converge across the fleet/);
assert.match(fleetFinalizer, /helium-sync-fleet-full-e2e-v4/);
assert.match(runtimeDrill,
  /package=computer\.helium\.sync\.test/);
assert.match(runtimeDrill,
  /\.helium-native-recovery-disposable-profile-v1/);
assert.match(runtimeDrill,
  /--helium-restore-disposable-native-\$kind=\$snapshot/);
assert.match(runtimeDrill, /verify_browser_receipt/);
assert.doesNotMatch(runtimeDrill, /computer\.helium\.sync(?!\.test)/);
assert.match(androidBoundary, /--native-recovery-profile/);
assert.match(androidBoundary,
  /native recovery admits only computer\.helium\.sync\.test/);

console.log("native Chromium password/cookie recovery source checks passed");
