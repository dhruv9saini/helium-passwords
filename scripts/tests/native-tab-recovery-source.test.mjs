import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const repoURL = relative => new URL(`../../${relative}`, import.meta.url);
const source = relative => fs.readFileSync(repoURL(relative), "utf8");

const service = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");
const importer = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_tab_restore_bridge.cc");
const build = source(
  "chromium/overlay/chrome/browser/helium_sync/BUILD.gn");

test("explicit topology importer is unreachable from normal launch", () => {
  assert.match(importer,
    /constexpr char kRestoreSwitch\[\] = "helium-restore-disposable-tabs"/);
  assert.match(service, /HeliumTabRestoreBridge::IsRequested\(\)/);
  assert.match(importer, /kDisposableRootMarker/);
  assert.match(importer, /kProfileMarker/);
  assert.match(importer, /kPreparedMarker/);
  assert.match(importer, /TransitionMarker\(root_, kPreparedMarker, kInProgressMarker\)/);
  assert.match(importer, /CreateBrowserWindow\(/);
  assert.match(importer, /GetController\(\)\.Restore/);
  assert.match(importer, /CreateTabGroup/);
  assert.match(importer, /SetTabGroupVisualData/);
  assert.match(importer, /final-topology-readback/);
  assert.match(importer, /Rollback\(\)/);
  assert.match(importer, /kConsumedMarker/);
  assert.match(importer, /kFailedMarker/);
  assert.doesNotMatch(importer, /HeliumSyncClient|Latest\(|Push\(/);
  const restoreMode = service.slice(
    service.indexOf("if (helium_sync::HeliumTabRestoreBridge::IsRequested())"),
    service.indexOf("const base::FilePath config_dir"));
  assert.match(restoreMode, /tab_restore_bridge_->Start\(\);[\s\S]*return;/);
  assert.doesNotMatch(restoreMode, /tab_snapshot_bridge_|HeliumSyncClient/);
  assert.match(importer, /kMaxTotalNavigations/);
  assert.match(importer, /int navigation_count = 0/);
  assert.match(importer, /plan->navigation_count = navigation_count/);
  assert.match(importer, /RestoreWindowAt\(/);
  assert.match(importer, /O_NOFOLLOW/);
  assert.match(importer, /BUILDFLAG\(IS_ANDROID\)[\s\S]*st_mtime_nsec/);
  assert.match(importer, /BUILDFLAG\(IS_APPLE\)[\s\S]*st_mtimespec/);
  assert.match(importer, /url\.is_valid\(\) && !url\.scheme\(\)\.empty\(\)/);
  assert.match(importer, /source_inventory/);
  assert.match(importer, /exact-supported-live-topology/);
  assert.match(importer, /verified-rollback/);
});

test("only the neutral importer is wired into the tab recovery overlay", () => {
  assert.match(build, /"helium_tab_restore_bridge\.cc"/);
  assert.match(build, /"\/\/components\/sessions"/);
  assert.doesNotMatch(build, /helium_tab_journal_bridge|\/\/sql/);
  assert.doesNotMatch(service, /HeliumTabJournalBridge|tab_journal_root/);
  assert.equal(fs.existsSync(repoURL(
    "chromium/overlay/chrome/browser/helium_sync/helium_tab_journal_bridge.cc")),
    false);
});

test("retired capsule and event-journal tooling is absent", () => {
  for (const retired of [
    "chromium/overlay/chrome/browser/helium_sync/helium_tab_journal_bridge.h",
    "cmd/helium-session-capsule",
    "cmd/helium-tab-journal",
    "internal/sessioncapsule",
    "internal/tabjournal",
    "scripts/tabs/native-session-capsule-backup.sh",
    "scripts/tabs/native-session-capsule.conf.example",
    "scripts/tabs/tab-journal-backup.sh",
    "scripts/tabs/tab-journal.conf.example",
    "systemd/helium-native-session-capsule@.service",
    "systemd/helium-native-session-capsule@.timer",
    "systemd/helium-tab-journal-backup@.service",
    "systemd/helium-tab-journal-backup@.timer",
  ]) {
    assert.equal(fs.existsSync(repoURL(retired)), false, retired);
  }
});
