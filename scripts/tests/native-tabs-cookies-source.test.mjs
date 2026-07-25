import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const repoURL = relative => new URL(`../../${relative}`, import.meta.url);
const repoFile = relative => fs.readFileSync(repoURL(relative), "utf8");

const cookie = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc");
const tabs = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_tab_snapshot_bridge.cc");
const service = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");
const tabExporter = repoFile("scripts/tabs/helium-tab-exporter.sh");

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
  assert.doesNotMatch(cookie, /key_id|active_key_id|key-epoch/);
  assert.match(cookie, /CookiePartitionKey::FromUntrustedInput/);
  assert.match(cookie, /CookieRecordKey\(\*cookie\)/);
  assert.match(cookie, /root\.Set\("payload", std::move\(\*payload\)\)/);
  assert.doesNotMatch(cookie, /SealLocalPayload|OpenLocalPayload|sealed_payload/);
  assert.match(cookie, /destination-set-rejected/);
});

test("native tab export matches the independent store schema and is atomic", () => {
  for (const field of [
    "schema_version", "windows", "active_index", "groups", "tabs", "pinned",
    "group", "history_state", "current_index", "navigations", "url", "title",
    "color", "collapsed", "metadata_state",
  ]) {
    assert.match(tabs, new RegExp(`Set\\(\"${field}\"`));
  }
  assert.match(tabs, /constexpr int kSchemaVersion = 2/);
  assert.match(tabs, /ListTabGroups\(\)/);
  assert.match(tabs, /GetTabGroupVisualData/);
  assert.match(tabs, /visual_data->is_collapsed\(\)/);
  assert.match(tabs, /GroupColorName/);
  assert.match(tabs, /item\.Set\("pinned", tab->IsPinned\(\)\)/);
  assert.match(tabs, /item\.Set\("group", group_id\)/);
  assert.match(tabs, /ImportantFileWriter::WriteFileAtomically/);
  assert.match(tabs, /SetPosixFilePermissions\(export_path_\.DirName\(\), 0700\)/);
  assert.match(tabs, /SetPosixFilePermissions\(export_path_, 0600\)/);
  assert.doesNotMatch(tabs, /last_fingerprint_|SHA256HashString/);
  assert.match(tabs, /HistoryCurrentOnlyUnloaded/);
  assert.match(tabs, /tab->GetURL\(\)/);
  assert.doesNotMatch(tabs, /LoadIfNeeded/);
  assert.match(tabs, /url\.is_valid\(\) && !url\.scheme\(\)\.empty\(\)/);
  assert.doesNotMatch(tabs, /SchemeIsHTTPOrHTTPS/);
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

test("tab export adapter rejects stale or mutable source boundaries", () => {
  assert.match(tabExporter, /\[ ! -L "\$\{source_file\}" \] && \[ -f/);
  assert.match(tabExporter, /stat -c %u/);
  assert.match(tabExporter, /8#077/);
  assert.match(tabExporter, /age_seconds.*max_age_seconds/s);
  assert.match(tabExporter, /before=.*stat -c.*%d:%i:%s:%Y/s);
  assert.match(tabExporter, /\[ "\$\{before\}" = "\$\{after\}" \]/);
  assert.match(tabExporter, /\[ ! -e "\$\{output_file\}" \]/);
});

test("normal launch preserves native tab recovery and the native password path", () => {
  const laptop = repoFile("scripts/laptop/start-helium-sync-local.sh");
  const chroot = repoFile("scripts/android-local/chromium-helium-local-root.sh");
  const installer = repoFile("scripts/android-local/install-phone-sync.sh");
  const migration = repoFile(
    "scripts/android-local/merge-helium-laptop-extensions-root.sh");

  for (const source of [laptop, chroot, installer]) {
    assert.doesNotMatch(source,
      /browserpass|helium-prepare-profile|helium-cleanup-startup-tabs|tab-pin-helper/i);
  }
  assert.doesNotMatch(chroot,
    /HELIUM_CHROOT_BROWSER|command -v chromium|browser=chromium|helium-extensions\/\*/);
  assert.match(chroot, /browser=\/usr\/local\/bin\/helium/);
  assert.match(chroot, /-x \/opt\/helium-sync\/helium/);
  assert.doesNotMatch(chroot, /exited_cleanly|exit_type|\/json\/close|Target\.closeTarget/);

  assert.match(migration, /pjmbgaakjkbhpopmakjoedenlfdmcdgm/);
  assert.doesNotMatch(migration, /\.local\/share\/browserpass/);
  for (const obsolete of [
    "scripts/android-local/helium-prepare-profile-root.py",
    "scripts/android-local/helium-cleanup-startup-tabs-root.py",
  ]) {
    assert.equal(fs.existsSync(repoURL(obsolete)), false, obsolete);
  }
});
