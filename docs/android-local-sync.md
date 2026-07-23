# Android and Chroot Helium Sync

The Android app and the Arch chroot browser use the same product architecture
as desktop: Chromium's native password store, Chromium's native CookieManager,
profile-local E2EE state, and the HTTPS service on lm. There is no phone-local
sync daemon and no shared server state inside the chroot.

Normal installation does not fetch, install, or launch CookieCloud; expose a
DevTools port for synchronization; install a CDP password writer; copy a sync
server journal; or copy one profile's enrollment state into another profile.
The obsolete CookieCloud server and browser-automation password/cookie writers
are not retained as runnable repository utilities. The CDP media probe carried
in disposable acceptance kits is read-only and has no sync or storage mutation
methods.

## Android app profile

The native app package is `computer.helium.sync`. Its sync enrollment belongs
only in:

```text
<dataDir>/app_chrome/Default/helium-sync/
```

The directory contains the oneplus-specific token, oneplus `client.json`, and
the lm direct-TLS tailnet URL. Before any of those are installed, Android must
explicitly enroll the independently authenticated, endpoint-constrained Helium
Sync CA as a user VPN/apps root and its DER SHA-256 must match d/da. The CA
private key and lm leaf key never go to oneplus. da or d credentials/state must
never be copied there. The app must be force-stopped and its full app profile
backed up before this directory or APK is changed.

A pending oneplus profile starts the native bridges, pulls passwords and
cookies, applies and verifies them, but cannot publish. Promotion is performed
only after both bridge cursors equal the client cursor and the app is stopped.
The next start reloads active scope.

## Arch chroot browser

The chroot browser has its own profile and therefore its own device identity if
it is ever enrolled. It must not reuse the Android app's oneplus credential or
client state. `scripts/android-local/chromium-helium-local-root.sh` requires
an existing HTTPS enrollment directory and the built Helium Sync binary at
`/opt/helium-sync/helium` through `/usr/local/bin/helium`. It fails instead of
falling back to stock Chromium.

`scripts/android-local/install-phone-sync.sh` installs the enrollment CLI,
local tab tool, launcher, and unrelated desktop helpers. It does not install a
server, CookieCloud, or CDP writers. The launcher requires the profile's native
HTTPS enrollment and starts Helium directly; there is no sidecar or secondary
writer to enable as a fallback. Normal launch does not load Browserpass or
unreviewed extension-directory globs, rewrite Chromium clean-exit state, or
delete recovered pages through CDP.

## Cookies and origin state

The native bridge transports every valid live cookie returned by CookieManager,
including session, persistent, Secure, HttpOnly, SameSite, host-only, domain,
and partitioned cookies. A destination snapshot and sealed rollback precede
every apply. A destination rejection is scoped to the exact canonical cookie
record and remote revision, restores the last local session, and requests
password reauthentication. Chromium's same-site DBSC session keys are recorded
only as local evidence; they do not classify every cookie on the site or prove
destination authentication. A later active-epoch revision or a verified local
cookie change after reauthentication may proceed through normal CAS.

Authentication state in localStorage, IndexedDB, service-worker storage, or
other profile stores is not copied. Each target origin needs a disposable audit
and a narrow export/import adapter if cookies plus password reauthentication
are insufficient. Raw application databases are never merged.

The Sync test APK also contains one explicit browser-native acceptance fixture.
It activates only when a new empty `Default` profile carries the exact
mode-0600 marker created by the artifact's
`prepare-cookie-acceptance-profile.sh`, and only in debuggable
`computer.helium.sync.test`. The service returns before normal sync, uses the
same native snapshot and canonical-identity helpers plus CookieManager to prove
destination snapshot, synthetic import/apply/readback, partition identity,
native rejection, rollback, and cleanup, then writes a content-free fixed-path
report. A malformed marker or failed fixture never falls through to enrollment.
The preparer cannot select a production package or existing profile. A fixture
pass does not claim authenticated-session success: the origin-state adapter
count remains zero and non-cookie transfer remains `not-tested`.

## Streaming and media

The codec and streaming fixtures live under `scripts/android-media/`.
`scripts/chromium/build-android-ci.sh` pins the Chromium/core commits, rejects
moving refs, composes the shared Passwords/Sync patch train, records resolved GN
args, packages the commit-bound runtime acceptance scripts, and compiles only
on chromiumer. Its codec flags and source tests are necessary but not runtime
proof. `scripts/android-media/prepare-disposable-acceptance.sh` verifies a
returned Sync or upstream-control test-package archive, creates a new
checksum-complete test directory with one `Browser-test.apk`, and never
installs or launches it. The artifact-carried
`runtime-acceptance/disposable-browser.sh`, sourced from
`scripts/android-media/disposable-browser.sh`, is the sole install/launch
boundary for those prepared artifacts. It admits only the two `.test`
identities, installs and re-hashes exactly `Browser-test.apk`, derives rather
than accepts the package-specific DevTools socket, and launches with exactly
the automation switch plus the optional fixture receipt's exact SPKI switch.
It snapshots, validates, and restores both Android Chromium command-line files
byte-for-byte and clears its temporary debug-app selection on every exit; it
refuses existing global debug state instead of force-stopping another app.
The same directory carries `run-device-probe.sh`, which owns the fixed ADB
mappings, background/resume cycle, optional Wi-Fi-to-cellular handoff with
restoration, immutable evidence directory, and protocol/lifecycle validation.
The exact install, launch, and device-probe commands are in `deployment.md`.
Acceptance still requires same-source upstream-control and Sync APKs on
oneplus for H.264/AAC, MSE, VP9/Opus, progressive Fetch, gzip/Brotli, SSE,
actually negotiated HTTP/2 and HTTP/3, background/foreground, and network
handoff.
Both disposable packages use `is_debug = false` and disable DCHECKs, but set
`debuggable_apks = true` so a rootless Android shell can select only the
`.test` app for its isolated command line and inspect synthetic bridge state.
The later `computer.helium.sync` build explicitly sets
`debuggable_apks = false`. Artifact admission rejects a package whose manifest
debuggable bit and GN role do not match.
The carried probe records EME and `com.widevine.alpha` availability separately;
ordinary codec playback never proves DRM, and protected playback remains
outside the passing gate until a CDM is deliberately provisioned.

Each artifact also carries the A/B pair verifier. The probe requires a
controlled disposable Service Worker to relay a progressive Fetch response;
the final pair receipt proves that Sync and control used the same private
source commit, Chromium commit, runtime harness, media bytes, protocol fixture,
and lifecycle matrix. Two standalone pass files are insufficient.
The runner enables Chromium 150's target-scoped CDP `Media` domain before
navigating to the synthetic page and records bounded player events. In
parallel it captures Android logcat with the exact disposable package UID; it
never clears or reads global logcat. Both files are mandatory pair evidence,
and partial diagnostics are retained under `failure.env` when a probe fails.

The rootless lm protocol fixture service is enabled with a repository-external
private CA/leaf and its credential-free HTTP/2-only/HTTP/3 behavior passes lm
runtime and restart tests. Its non-secret receipt binds the exact leaf SPKI
override admitted only for a disposable `.test` browser; the device runner
verifies the effective command line and rejects broad certificate bypasses.
The pinned Caddy source patch keeps its QUIC Initial UDP payload at 1200 bytes,
below Tailscale's 1280-byte interface MTU after IP/UDP overhead. lm and da pass
HTTP/2, the HTTP/3-origin warm-up, and direct HTTP/3 with the unchanged private
CA/SPKI. OnePlus browser negotiation remains an APK/device acceptance gate.
`deployment.md` owns the exact health, endpoint, receipt, and rollback
commands.

## Tabs

Android tabs remain local. The native tab bridge exports a neutral snapshot for
the oneplus-local repository; the backup job age-encrypts that generation to
lm NAS and da. No backup is imported into d or da as browser state, and no copy
auto-opens. See `tab-backup-operations.md`.
