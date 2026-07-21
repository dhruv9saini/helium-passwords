import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync(new URL(
  "../../chromium/overlay/components/helium_sync/helium_password_sync_bridge.cc",
  import.meta.url,
), "utf8");

test("native startup is pull-first and has no initial bulk-export path", () => {
  const start = source.slice(source.indexOf("void HeliumPasswordSyncBridge::Start()"),
    source.indexOf("void HeliumPasswordSyncBridge::Stop()"));
  assert.match(start, /state_trusted_ = LoadState\(\)/);
  assert.match(start, /PullAndApply\(\)/);
  assert.doesNotMatch(start, /AddObserver|PushRecords|GetAllLogins/);
  assert.doesNotMatch(source, /RequestInitialExport|ExportInitialPasswords/);
});

test("native remote sequence is applied before local mutation publication", () => {
  const pull = source.indexOf("void HeliumPasswordSyncBridge::OnPullComplete");
  const reconcileRead = source.indexOf("RequestReconcileRead();", pull);
  const apply = source.indexOf("void HeliumPasswordSyncBridge::ReconcileRemotePasswords");
  const publish = source.indexOf("void HeliumPasswordSyncBridge::PublishLocalMutations");
  assert.ok(pull >= 0 && reconcileRead > pull && apply > 0 && publish > apply);
  assert.match(source.slice(apply, publish), /remote\.seq <= state->second\.remote_seq/);
  assert.match(source.slice(publish, source.indexOf("void HeliumPasswordSyncBridge::PushRecords")),
    /state->second\.fingerprint == fingerprint/);
});
