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

## Streaming and media

The codec and streaming fixtures live under `scripts/android-media/`.
`scripts/chromium/build-android-ci.sh` pins the Chromium/core commits, rejects
moving refs, composes the shared Passwords/Sync patch train, records resolved GN
args, packages the commit-bound runtime acceptance scripts, and compiles only
on chromiumer. Its codec flags and source tests are necessary but not runtime
proof. `scripts/android-media/prepare-disposable-acceptance.sh` verifies a
returned Sync or upstream-control test-package archive, creates a new
checksum-complete test directory with one `Browser-test.apk`, and never
installs or launches it. That directory carries `run-device-probe.sh`, which
owns the fixed ADB mappings, background/resume cycle, optional Wi-Fi-to-cellular
handoff with restoration, immutable evidence directory, and protocol/lifecycle
validation. The exact device command is in `deployment.md`. Acceptance still
requires same-source upstream-control and Sync APKs on oneplus for H.264/AAC, MSE,
VP9/Opus, progressive Fetch, gzip/Brotli, SSE, actually negotiated HTTP/2 and
HTTP/3, background/foreground, and network handoff.
The carried probe records EME and `com.widevine.alpha` availability separately;
ordinary codec playback never proves DRM, and protected playback remains
outside the passing gate until a CDM is deliberately provisioned.

Each artifact also carries the A/B pair verifier. The probe requires a
controlled disposable Service Worker to relay a progressive Fetch response;
the final pair receipt proves that Sync and control used the same private
source commit, Chromium commit, runtime harness, media bytes, protocol fixture,
and lifecycle matrix. Two standalone pass files are insufficient.

The rootless lm protocol fixture service is enabled with a repository-external
private CA/leaf and its credential-free HTTP/2-only/HTTP/3 behavior passes lm
runtime and restart tests. Its non-secret receipt binds the exact leaf SPKI
override admitted only for a disposable `.test` browser; the device runner
verifies the effective command line and rejects broad certificate bypasses.
da passes HTTP/2 and the HTTP/3-origin warm-up but direct HTTP/3 currently
times out, so device HTTP/3 remains open. `deployment.md` owns the exact health,
endpoint, receipt, and rollback commands.

## Tabs

Android tabs remain local. The native tab bridge exports a neutral snapshot for
the oneplus-local repository; the backup job age-encrypts that generation to
lm NAS and da. No backup is imported into d or da as browser state, and no copy
auto-opens. See `tab-backup-operations.md`.
