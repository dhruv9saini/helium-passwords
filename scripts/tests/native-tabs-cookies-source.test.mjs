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
    cookie.indexOf("std::optional<base::ListValue> CookiesToValue"),
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

test("native cookie reconciliation pulls first and only policy sources publish", () => {
  const reconcile = cookie.slice(
    cookie.indexOf("void Reconcile()"),
    cookie.indexOf("void OnLatest"),
  );
  assert.match(reconcile, /client_->Latest\(\s*\{kCookieKind\}/);

  const onCookies = cookie.slice(
    cookie.indexOf("void OnCookies"),
    cookie.indexOf("void OnSourcePush"),
  );
  assert.match(onCookies, /if \(policy\.source == device_name_\)/);
  assert.match(onCookies, /!policy\.replicas\.contains\(device_name_\)/);
  assert.match(onCookies, /source_records\.push_back/);
  assert.match(onCookies, /needs_reauthentication = true/);
  assert.equal((onCookies.match(/client_->Push/g) ?? []).length, 1);
});

test("native cookie apply uses Chromium CookieManager and rejects malformed authority", () => {
  assert.match(cookie, /GetCookieManagerForBrowserProcess\(\)/);
  assert.match(cookie, /GetAllCookies/);
  assert.match(cookie, /SetCanonicalCookie/);
  assert.match(cookie, /DeleteCanonicalCookie/);
  assert.match(cookie, /origin != policy\.source/);
  assert.match(cookie, /CookiePartitionKey::FromUntrustedInput/);
  assert.match(cookie, /DomainsOverlap\(existing\.domain, policy\.domain\)/);
  assert.match(cookie, /source_port == 0/);
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
  const tokenRead = service.indexOf("ReadFirstConfigValue(profile, kTokenFile)");
  assert.ok(tabStart >= 0 && tokenRead > tabStart);
  assert.match(tabs, /profile_->GetPath\(\)\.IsParent\(export_path_\)/);
  assert.doesNotMatch(tabs, /Session_|Tabs_|Login Data|Network\/Cookies/);
});
