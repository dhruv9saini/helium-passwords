import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const repoURL = relative => new URL(`../../${relative}`, import.meta.url);
const source = relative => fs.readFileSync(repoURL(relative), "utf8");

const service = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");
const importer = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_tab_restore_bridge.cc");
const journal = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_tab_journal_bridge.cc");
const snapshot = source(
  "chromium/overlay/chrome/browser/helium_sync/helium_tab_snapshot_bridge.cc");
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
  assert.match(importer, /O_NOFOLLOW/);
  assert.match(importer, /BUILDFLAG\(IS_ANDROID\)[\s\S]*st_mtime_nsec/);
  assert.match(importer, /BUILDFLAG\(IS_APPLE\)[\s\S]*st_mtimespec/);
  assert.match(importer, /url\.is_valid\(\) && !url\.scheme\(\)\.empty\(\)/);
  assert.match(importer, /source_inventory/);
  assert.match(importer, /exact-supported-live-topology/);
  assert.match(importer, /verified-rollback/);
});

test("journal is an independent observer and SQLite hash-chain producer", () => {
  for (const callback of [
    "OnTabAdded", "OnActiveTabChanged", "OnTabRemoved", "OnTabMoved",
    "OnWebContentsReplaced", "PrimaryPageChanged", "TitleWasSet",
  ]) {
    assert.match(journal, new RegExp(callback));
  }
  assert.match(journal, /CREATE TABLE events/);
  assert.match(journal, /PRIMARY KEY\(epoch, sequence\)/);
  assert.match(journal, /PRAGMA journal_mode=WAL/);
  assert.match(journal, /PRAGMA synchronous=FULL/);
  assert.match(journal, /HashEvent\(/);
  assert.match(journal, /previous_sha256/);
  assert.match(journal, /kHeartbeatInterval = base::Minutes\(5\)/);
  assert.match(journal, /sequence_ > 0[\s\S]*heartbeat_timer_\.Start/);
  assert.match(journal,
    /if \(!AppendCheckpoint\([\s\S]*FailClosed\("initial-checkpoint"\)[\s\S]*if \(sequence_ > 0\) \{[\s\S]*heartbeat_timer_\.Start/);
  assert.match(journal, /sequence_ >= kMaxEventsPerEpoch[\s\S]*RotateEpoch/);
  assert.match(journal, /bool RotateEpoch\(\)/);
  assert.match(journal, /PollTopology/);
  assert.match(journal, /last_payload_/);
  assert.match(journal, /initial-checkpoint/);
  assert.match(journal, /final-checkpoint/);
  assert.match(journal, /kJournalRootMarker/);
  assert.match(journal, /journal_root_\.IsParent\(profile_->GetPath\(\)\)/);
  assert.match(journal, /GetURL\(\)/);
  assert.match(journal, /GetTitle\(\)/);
  assert.match(journal, /ListTabGroups\(\)/);
  assert.match(journal, /GetTabGroupVisualData/);
  assert.match(journal, /visual->is_collapsed\(\)/);
  assert.match(journal, /url\.is_valid\(\) && !url\.scheme\(\)\.empty\(\)/);
  assert.match(journal, /deferred incomplete topology/);
  assert.doesNotMatch(journal, /BuildSnapshot|Session_|Tabs_|HeliumSyncClient/);
  assert.doesNotMatch(snapshot, /HeliumTabJournalBridge|CREATE TABLE events/);
});

test("journal and importer are wired against explicit pinned dependencies", () => {
  assert.match(build, /"helium_tab_journal_bridge\.cc"/);
  assert.match(build, /"helium_tab_restore_bridge\.cc"/);
  assert.match(build, /"\/\/sql"/);
  assert.match(build, /"\/\/components\/sessions"/);
  const journalStart = service.indexOf("tab_journal_bridge_->Start()");
  const tokenRead = service.indexOf("ReadConfigValue(config_dir, kTokenFile)");
  assert.ok(journalStart >= 0 && tokenRead > journalStart);
});
