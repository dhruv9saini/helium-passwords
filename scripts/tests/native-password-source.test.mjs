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

test("native remote revision is verified before local mutation publication", () => {
  const pull = source.indexOf("void HeliumPasswordSyncBridge::OnPullComplete");
  const reconcileRead = source.indexOf("RequestReconcileRead();", pull);
  const apply = source.indexOf("void HeliumPasswordSyncBridge::ReconcileRemotePasswords");
  const publish = source.indexOf("void HeliumPasswordSyncBridge::PublishLocalMutations");
  assert.ok(pull >= 0 && reconcileRead > pull && apply > 0 && publish > apply);
  assert.match(source.slice(apply, publish), /record\.revision <= state->second\.revision/);
  assert.match(source.slice(apply, publish), /ResolvePendingPublications/);
  assert.match(source.slice(apply, publish), /VerifyRemoteWrites/);
  const queue = source.indexOf("void HeliumPasswordSyncBridge::QueueLocalMutations");
  assert.ok(queue > publish);
  assert.match(source.slice(publish, queue), /state->second\.fingerprint == fingerprint/);
});

test("native records emit Chromium's complete password specifics schema", () => {
  const serialize = source.slice(
    source.indexOf("std::optional<std::string> PasswordPayloadJSON"),
    source.indexOf("std::optional<Credential> PayloadToCredential"),
  );
  assert.match(serialize, /SpecificsDataFromStoredCredential/);
  assert.match(serialize, /SerializeToString/);
  assert.match(source, /chromium-password-specifics-data-v1/);
  assert.match(serialize, /password_specifics_data_b64/);
  assert.doesNotMatch(serialize, /payload\.Set\("password"/);
  assert.doesNotMatch(serialize, /payload\.Set\("note"/);
});

test("greenfield records reject legacy simple payloads", () => {
  const parse = source.slice(
    source.indexOf("std::optional<Credential> PayloadToCredential"),
    source.indexOf("std::optional<Record> UpsertRecordForCredential"),
  );
  assert.match(parse, /PasswordSpecificsData specifics/);
  assert.match(parse, /CredentialFromSpecifics/);
  assert.match(source, /StoredCredentialFromSpecifics/);
  assert.doesNotMatch(source, /kLegacySimplePayloadFormat|helium-password-v1/);
});

test("pinned Chromium StoredCredential APIs are used without version fallbacks", () => {
  assert.match(source, /using Credential = password_manager::StoredCredential/);
  assert.match(source, /return change\.credential\(\)/);
  assert.match(source, /SpecificsDataFromStoredCredential/);
  assert.doesNotMatch(source, /__has_include|ToPasswordForm/);
});

test("remote writes validate identity and choose one add-or-update operation", () => {
  const reconcile = source.slice(
    source.indexOf("void HeliumPasswordSyncBridge::ReconcileRemotePasswords"),
    source.indexOf("void HeliumPasswordSyncBridge::PublishLocalMutations"),
  );
  assert.match(reconcile, /PasswordRecordKey\(\*credential\) != record\.key/);
  assert.match(reconcile, /profile_store_->AddLogin/);
  assert.match(reconcile, /profile_store_->UpdateLogin/);
  assert.doesNotMatch(source, /AddRemoteLoginAfterUpdate/);
});
