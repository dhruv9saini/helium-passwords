import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const cookie = fs.readFileSync(new URL(
  "../../chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc",
  import.meta.url,
), "utf8");
const tabs = fs.readFileSync(new URL(
  "../../chromium/overlay/chrome/browser/helium_sync/helium_tab_snapshot_bridge.cc",
  import.meta.url,
), "utf8");
const service = fs.readFileSync(new URL(
  "../../chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc",
  import.meta.url,
), "utf8");

test("native cookie identity includes partition, host/domain form, scheme, and port", () => {
  const identity = cookie.slice(
    cookie.indexOf("std::optional<std::string> CookieIdentity"),
    cookie.indexOf("std::optional<std::string> CookieRecordKey"),
  );
  assert.match(identity, /CookiePartitionKey::Serialize\(cookie\.PartitionKey\(\)\)/);
  assert.match(identity, /TopLevelSite/);
  assert.match(identity, /has_cross_site_ancestor/);
  assert.match(identity, /cookie\.Domain\(\)/);
  assert.match(identity, /cookie\.Path\(\)/);
  assert.match(identity, /cookie\.Name\(\)/);
  assert.match(identity, /cookie\.SourceScheme\(\)/);
  assert.match(identity, /cookie\.SourcePort\(\)/);
});

test("native cookie reconciliation pulls first and publishes only local mutations", () => {
  const reconcile = cookie.slice(
    cookie.indexOf("void Reconcile()"),
    cookie.indexOf("void OnLatest"),
  );
  assert.match(reconcile, /client_->Latest\(\s*\{kCookieKind\}/);

  const publish = cookie.slice(
    cookie.indexOf("void PublishLocalMutations"),
    cookie.indexOf("void OnPushComplete"),
  );
  assert.match(publish, /baseline_cookie_fingerprint/);
  assert.match(publish, /expected_revision/);
  assert.match(publish, /mutation\.deleted = true/);
  assert.equal((publish.match(/client_->Push/g) ?? []).length, 1);
});

test("native cookie apply uses Chromium CookieManager and rejects malformed authority", () => {
  assert.match(cookie, /GetCookieManagerForBrowserProcess\(\)/);
  assert.match(cookie, /GetAllCookies/);
  assert.match(cookie, /SetCanonicalCookie/);
  assert.match(cookie, /DeleteCanonicalCookie/);
  assert.match(cookie, /record\.device_id\.empty\(\)/);
  assert.match(cookie, /record\.key_id\.empty\(\)/);
  assert.match(cookie, /cookie-key-epoch-changed/);
  assert.match(cookie, /CookiePartitionKey::FromUntrustedInput/);
  assert.match(cookie, /CookieRecordKey\(\*cookie\)/);
  assert.match(cookie, /SealLocalPayload/);
  assert.match(cookie, /destination-set-rejected/);
});

test("native tab export matches the independent store schema and is atomic", () => {
  for (const field of [
    "schema_version", "windows", "active_index", "tabs", "pinned",
    "group", "current_index", "navigations", "url", "title",
  ]) {
    assert.match(tabs, new RegExp(`Set\\(\"${field}\"`));
  }
  assert.match(tabs, /ImportantFileWriter::WriteFileAtomically/);
  assert.match(tabs, /fingerprint == last_fingerprint_/);
  assert.match(tabs, /if \(!contents\)/);
  assert.match(tabs, /valid = false/);
  assert.match(tabs, /SchemeIsHTTPOrHTTPS/);
});

test("tab snapshots stay independent of remote-sync credentials and profile files", () => {
  const tabStart = service.indexOf("tab_snapshot_bridge_->Start()");
  const tokenRead = service.indexOf("ReadConfigValue(config_dir, kTokenFile)");
  assert.ok(tabStart >= 0 && tokenRead > tabStart);
  assert.match(tabs, /profile_->GetPath\(\)\.IsParent\(export_path_\)/);
  assert.doesNotMatch(tabs, /Session_|Tabs_|Login Data|Network\/Cookies/);
  assert.doesNotMatch(tabs, /HeliumSyncClient|Latest\(|Push\(|AcknowledgeApplied/);
  assert.doesNotMatch(tabs, /base_url|token|client\.json|syncstore/i);
});
