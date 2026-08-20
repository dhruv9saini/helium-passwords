import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const repoFile = relative => fs.readFileSync(
  new URL(`../../${relative}`, import.meta.url), "utf8");

const cookie = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_cookie_sync_bridge.cc");
const service = repoFile(
  "chromium/overlay/chrome/browser/helium_sync/helium_sync_service.cc");
const prepare = repoFile(
  "scripts/android-media/prepare-cookie-acceptance-profile.sh");
const deviceProbe = repoFile("scripts/android-media/run-device-probe.sh");
const cdpProbe = repoFile("scripts/android-media/run-cdp-probe.mjs");

const fixture = cookie.slice(
  cookie.indexOf("class HeliumCookieAcceptanceFixture::Impl"),
  cookie.indexOf("HeliumCookieAcceptanceFixture::HeliumCookieAcceptanceFixture"),
);

test("native cookie fixture is disposable-only and suppresses normal sync", () => {
  assert.match(fixture, /computer\.helium\.sync\.test/);
  assert.match(fixture, /apk_info::is_debug_app/);
  assert.match(fixture, /BaseName\(\)\.AsUTF8Unsafe\(\) != "Default"/);
  assert.match(fixture, /permissions != 0600/);
  assert.match(fixture, /fixture-profile-must-start-with-empty-cookie-store/);
  assert.match(service,
    /HeliumCookieAcceptanceFixture::IsRequested[\s\S]*cookie_acceptance_fixture_->Start\(\);[\s\S]*return;/);
  assert.ok(
    service.indexOf("HeliumCookieAcceptanceFixture::IsRequested") <
      service.indexOf("HeliumTabRestoreBridge::IsRequested"),
    "cookie marker gate must run before exporters, enrollment, or sync",
  );
  assert.ok(
    fixture.indexOf("fixture-requires-debuggable-sync-test-package") <
      fixture.indexOf("manager()->GetAllCookies"),
    "package admission must precede the first CookieManager read",
  );
  assert.match(cookie,
    /IsRequested\(Profile \*profile\)[\s\S]*PathExists\(marker\) \|\| base::IsLink\(marker\)/);
  const normalBridge = fixture.slice(fixture.indexOf("void Start()"));
  assert.doesNotMatch(normalBridge, /HeliumSyncClient|Latest\(|Push\(|DevTools|CDP/);
});

test("marker admission rejects links, FIFOs, and wrong-sized files before reading", () => {
  const markerReader = fixture.slice(
    fixture.indexOf("bool ReadAcceptanceMarker"),
    fixture.indexOf("bool CanWriteAcceptanceFile"),
  );
  assert.match(markerReader, /O_NOFOLLOW/);
  assert.match(markerReader, /O_NONBLOCK/);
  assert.match(markerReader, /fstat/);
  assert.match(markerReader, /S_ISREG/);
  assert.match(markerReader, /st_mode & 0777\) != 0600/);
  assert.match(markerReader, /st_size != static_cast<off_t>\(kExpectedSize\)/);
  assert.ok(
    markerReader.indexOf("fstat") < markerReader.indexOf("read(marker_fd.get()"),
    "descriptor type, mode, and exact size must be checked before marker content is read",
  );
});

test("unsafe output paths fail without traversing or reporting through them", () => {
  const start = fixture.slice(
    fixture.indexOf("void Start()"),
    fixture.indexOf("void Stop()"),
  );
  assert.match(start, /base::PathExists\(output_dir_\)/);
  assert.match(start, /base::IsLink\(output_dir_\)/);
  assert.ok(
    start.indexOf("base::IsLink(output_dir_)") <
      start.indexOf("output_paths_admitted_ = true"),
    "the output parent must be absent and non-symlinked before writes are admitted",
  );
  const writer = fixture.slice(
    fixture.indexOf("bool CanWriteAcceptanceFile"),
    fixture.indexOf("std::optional<net::CanonicalCookie>"),
  );
  assert.match(writer, /path\.DirName\(\) != output_dir_/);
  assert.match(writer, /base::IsLink\(output_dir_\)/);
  assert.match(writer, /base::IsLink\(path\)/);
  assert.match(writer, /directory_permissions != 0700/);
  assert.match(writer, /file_permissions != 0600/);
  const fail = fixture.slice(
    fixture.indexOf("void Fail("),
    fixture.indexOf("raw_ptr<Profile>"),
  );
  assert.match(fail, /if \(output_paths_admitted_/);
  assert.doesNotMatch(fail, /WriteSecretFile/);
});

test("fixture uses the canonical native CookieManager transaction surface", () => {
  assert.match(fixture, /GetCookieManagerForBrowserProcess/);
  assert.match(fixture, /GetAllCookies/);
  assert.match(fixture, /SetCanonicalCookie/);
  assert.match(fixture, /DeleteCanonicalCookie/);
  assert.match(fixture, /BuildSnapshot/);
  assert.match(fixture, /DiffSnapshots/);
  assert.match(fixture, /CookiePartitionKey::FromUntrustedInput/);
  assert.match(fixture, /HasDistinctPartitionIdentities/);
  assert.match(fixture, /snapshot_persisted_before_apply/);
  assert.match(fixture, /import-apply-readback-mismatch/);
  assert.match(fixture, /negative-cookie-operation-was-accepted/);
  assert.match(fixture, /destination-rollback-readback-mismatch/);
  assert.match(fixture, /complete_profile_cookie_store/);
});

test("fixture evidence is content-free and reports unsupported origin state honestly", () => {
  assert.match(fixture, /cookie_names_guessed", false/);
  assert.match(fixture, /registered_adapter_count", 0/);
  assert.match(fixture, /non_cookie_transfer_result", "not-tested"/);
  const report = fixture.slice(
    fixture.indexOf("base::DictValue Report"),
    fixture.indexOf("void Pass()"),
  );
  assert.doesNotMatch(report, /cookie\.Name|cookie\.Value|cookie\.Domain/);
  assert.doesNotMatch(report, /destination-baseline|imported-rotation|partitioned-session/);
});

test("profile preparation cannot target an existing or non-test profile", () => {
  assert.match(prepare, /package=computer\.helium\.sync\.test/);
  assert.match(prepare, /test ! -e app_chrome\/Default/);
  assert.match(prepare, /pidof "\$package"/);
  assert.match(prepare, /sha256sum/);
  assert.match(prepare, /chmod 600/);
  assert.doesNotMatch(prepare, /pm clear|rm -|force-stop|computer\.helium\.sync["']/);
});

test("device probe captures package-only logs, CDP Media events, and native evidence", () => {
  assert.match(deviceProbe, /logcat --uid="\$package_uid"/);
  assert.match(deviceProbe, /media-diagnostics\.json/);
  assert.match(deviceProbe, /cookie-native-acceptance\.json/);
  assert.match(deviceProbe, /exec-out run-as "\$package" cat "\$cookie_remote"/);
  assert.match(deviceProbe, /failed_evidence_directory/);
  assert.doesNotMatch(deviceProbe, /logcat -c|logcat \*:V/);
  assert.match(cdpProbe, /Target\.createTarget"[\s\S]*url: "about:blank"/);
  assert.match(cdpProbe, /Media\.enable/);
  assert.match(cdpProbe, /CDP Media domain/);
  assert.match(cdpProbe, /mediaDiagnostics\.evidence/);
});
