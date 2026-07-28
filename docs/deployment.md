# Helium Sync Deployment Runbook

Do not use this runbook on a personal profile until every disposable gate in
`acceptance.md` is recorded against the exact returned artifact. Commands are
shown with placeholders and never print a token, cookie, password,
or tab URL.

## 1. Build and return artifacts

Run from the clean private checkout on lm. The active native compile uses the
same form:

```sh
job=hs-android-150-native-sync-N
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$job" 80
scripts/chromiumer-job.sh start "$job" \
  --summary "Chromium 150 Android native Helium sync compile" \
  --next "Fetch and verify the compile proof, then start the bounded APK job." -- \
  scripts/chromiumer-nix.sh run -- env \
    HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
    CHROMIUM_ANDROID_PHASE=all \
    CHROMIUM_TARGET=chrome/browser/helium_sync:helium_sync \
    CHROMIUM_ANDROID_PROVENANCE_ONLY=true \
    USE_CCACHE=false CHROMIUM_ANDROID_SKIP_SYSTEM_DEPS=true \
    CHROMIUM_ANDROID_USE_SISO=false AUTONINJA_JOBS=1 GCLIENT_JOBS=1 \
    bash scripts/chromium/build-android-ci.sh

scripts/chromiumer-job.sh status "$job"
scripts/chromiumer-job.sh logs "$job" 120
# One cancellation command:
scripts/chromiumer-job.sh cancel "$job"
```

After success, fetch the named compile tarball to the NAS, verify its automatic
receipt, then clean the remote workspace. Use a new job ID for
`chrome_public_apk`; never mutate or resume a terminal job.

Accept the focused compile only after its carried provenance and exact target
pass the independent verifier:

```sh
scripts/chromium/verify-android-compile-proof.sh \
  /srv/nas/helium-builds/JOB/compile-chrome_browser_helium_sync_helium_sync-arm64.tar.xz \
  chrome/browser/helium_sync:helium_sync HELIUM_SYNC_COMMIT
```

## 2. Prove disposable behavior

Use synthetic credentials, fixture cookies, and new disposable profiles on d,
da, and oneplus. Record:

- d seed, da pending join, oneplus pending join;
- zero records published by either initial join;
- equal password/cookie/client verified cursors before explicit promotion;
- zero records after an unchanged restart;
- save prompt, autofill, update, deletion/tombstone, stale conflict;
- whole-cookie identity, session cookies, partition keys, two rotations,
  destination rollback, DBSC/rejection handling, and imported-session outcome;
- streaming and codec fixtures; and
- local tab capture, both off-source hashes, corruption quarantine, retention,
  and restore into a new disposable browser state.

The oneplus disposable APK must use the parallel package identity; it may not
replace the installed personal package:

```sh
CHROMIUM_ANDROID_MANIFEST_PACKAGE=computer.helium.sync.test
```

Confirm the returned APK manifest and `build-provenance/gn-args-resolved.txt`
both name `computer.helium.sync.test` before installation. Android then gives
the fixture browser an independent app-data directory. The later production
artifact is a separate clean build with the default `computer.helium.sync`;
back up that app's complete existing data before installing it. The `.test`
artifact explicitly has `debuggable_apks = true` for rootless synthetic
instrumentation; the production artifact explicitly has
`debuggable_apks = false`. Both remain `is_debug = false` with DCHECKs off.

Run the native password lifecycle through the shared
`docs/password-runtime-acceptance.md` protocol, then run the private
`docs/password-runtime-sync-acceptance.md` extension. The public receipt binds
native UI screenshots to the fixture and artifact; `sync-receipt.json` binds
the bridge state, journal agreement, revisions, tombstone, and no-op restarts
to that public receipt. CDP password writes, extensions, raw password
databases, and checklist-only evidence are rejected.

Make that check executable on lm (the current SDK tool path is explicit):

```sh
AAPT2="$HOME/Android/Sdk/build-tools/36.0.0/aapt2" \
  scripts/chromium/verify-android-artifact.sh \
  /srv/nas/helium-builds/JOB/chrome_public_apk-arm64.tar.xz \
  computer.helium.sync.test HELIUM_SYNC_COMMIT
```

The verifier also checks the relocatable provenance manifest, pinned Chromium
commit, clean tracked source status, exactly one `HeliumSync.apk`, and the
artifact-carried runtime acceptance kit. It rejects an artifact lock other than
the repository lock and uses `aapt2 dump badging` to require the package-role
debuggable bit plus versionCode
`787500005` and versionName `150.0.7871.181`; the code is exactly one above the
observed installed production code `787500004`. It prints those versions plus
the APK and runtime-kit SHA-256 values. Prepare a new, immutable disposable test
directory from that verified archive:

```sh
AAPT2="$HOME/Android/Sdk/build-tools/36.0.0/aapt2" \
  scripts/android-media/prepare-disposable-acceptance.sh \
  /srv/nas/helium-builds/JOB/chrome_public_apk-arm64.tar.xz \
  computer.helium.sync.test \
  HELIUM_SYNC_COMMIT \
  /srv/nas/helium-acceptance/JOB

(cd /srv/nas/helium-acceptance/JOB && sha256sum -c PACKAGE_SHA256SUMS)
```

The preparer refuses an existing destination. It copies the exact test APK,
build provenance, and artifact-carried probe scripts, generates deterministic
synthetic media with those scripts, and records hashes for the archive, APK,
runtime kit, and complete prepared directory. It does not install or launch
the APK.

Install only that checksum-admitted disposable identity through the repository
boundary:

```sh
sync_acceptance=/srv/nas/helium-acceptance/SYNC_JOB
serial=ONEPLUS_ADB_SERIAL
"$sync_acceptance/runtime-acceptance/disposable-browser.sh" \
  install "$sync_acceptance" "$serial"
```

The boundary rechecks the complete prepared-directory inventory before any ADB
call, streams only its exact `Browser-test.apk` to user 0, and then re-reads the
installed monolithic `base.apk` to require the same SHA-256, version, and
package identity. It admits only `computer.helium.sync.test` and
`computer.helium.control.test`; it has no normal-package selector, uninstall,
or profile-clearing operation.

While the installed Sync test package is stopped, create its one new
native-cookie fixture profile:

```sh
"$sync_acceptance/runtime-acceptance/prepare-cookie-acceptance-profile.sh" \
  "$sync_acceptance" "$serial"
```

The command requires the exact installed APK hash and debuggable
`computer.helium.sync.test`, refuses a running package, and refuses any
existing `app_chrome/Default`; it does not clear, stop, install, or inspect
another app. The next admitted launch runs the fixed native CookieManager
fixture before normal sync. Do not prepare the control package. The Sync
device probe requires and collects the passed content-free native report.

Build the same-commit control through the separate no-patch entry point:

```sh
scripts/chromiumer-job.sh start "$control_job" \
  --summary "Unmodified Chromium 150 Android control APK" \
  --next "Fetch, verify, and run the disposable control probe before the Sync APK." -- \
  scripts/chromiumer-nix.sh run -- env \
    HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
    AUTONINJA_JOBS=1 GCLIENT_JOBS=1 \
    bash scripts/chromium/build-android-control-ci.sh
```

Its composition proof is exactly `upstream-control`, its package is
`computer.helium.control.test`, and its archive contains
`ChromiumControl.apk`. Verify and prepare it with the same tools by supplying
that package and a different nonexistent acceptance directory. Both prepared
directories name the admitted file `Browser-test.apk`; their package identity,
archive hash, source commit, and composition remain explicit in provenance.

### lm HTTP/2 and HTTP/3 fixture origins

The disposable protocol origins are a separate rootless user service. They
carry no authentication, cookies, writable application state, request log, or
personal profile data. The Node backend listens only on loopback. Caddy binds
only lm's current Tailscale IPv4 on fixed high ports: `44723/tcp` is HTTP/2
only, while `44724/tcp` and `44724/udp` provide the HTTP/3 origin and its
explicit Alt-Svc advertisement. Both origins require TLS 1.3 and proxy the
same delayed deterministic fixture response.

The gateway is Caddy `2.11.3` at exact upstream commit
`cc58caa1099240ef1a4c280b892260b380a85c86`, with quic-go `0.59.1`. The
source archive and the one downstream patch are independently SHA-256 pinned
in `scripts/android-media/protocol-fixture.conf`. The patch changes only
quic-go's server `InitialPacketSize` from its 1280-byte default to the
RFC-permitted 1200-byte minimum. This is required on the tailnet path:
Tailscale's interface MTU is 1280 bytes, while a 1280-byte QUIC UDP payload
needs another 28 bytes for IPv4 and UDP headers. The unpatched server receives
the remote ClientHello but its first server flight never reaches the client.
The 1200-byte initial payload leaves 52 bytes below the interface MTU and lets
quic-go's normal path-MTU discovery proceed after the handshake.

`install-source` verifies the source and patch hashes, applies the patch
fail-closed, builds with the host's local Go toolchain using two jobs and
`CGO_ENABLED=0`, and requires 6 GiB free before beginning the bounded Caddy
build. It records the upstream/build/quic-go versions, source and patch hashes,
Go version, final binary hash, Node/runtime hash, and asset generation before
installing inactive under `~/.local/share/helium-media-fixtures`. Private
endpoint state is mode 0600 under
`~/.local/state/helium-media-fixtures`; no certificate or key enters the
repository.

Install and verify source without opening a listener:

```sh
scripts/android-media/install-protocol-fixtures.sh install-source
scripts/android-media/install-protocol-fixtures.sh verify-source
CADDY_BIN="$HOME/.local/share/helium-media-fixtures/bin/caddy" \
  scripts/tests/android-protocol-fixture-runtime.test.sh
```

The runtime test uses a one-day synthetic certificate in a temporary
directory, proves HTTP/2, HTTP/3 warm-up/Alt-Svc, direct HTTP/3, TLS 1.3, exact
chunks, and absent `Server`/`Set-Cookie` headers, then stops both temporary
processes and removes the certificate. It is source proof, not an
Android-trusted endpoint.

The live disposable origins use a local, fixture-only P-256 CA and leaf. This
avoids making tailnet-wide HTTPS administration a prerequisite and does not
add the CA to any system trust store. Generate both outside the repository,
verify, and activate with:

```sh
scripts/android-media/install-protocol-fixtures.sh issue-private-tls
scripts/android-media/install-protocol-fixtures.sh verify-endpoint
scripts/android-media/install-protocol-fixtures.sh enable
scripts/android-media/install-protocol-fixtures.sh verify-live
```

`issue-private-tls` retains the CA and leaf keys only in a mode-0600 immutable
generation under `~/.local/state/helium-media-fixtures/tls`. It refuses the
wrong host, chain, key, SPKI, or less than 24 hours remaining. It also writes a
non-secret mode-0600 `config/fixture-provenance.json`, served at that path on
both origins. The receipt binds the leaf certificate SHA-256 and Base64 SPKI
SHA-256 to the hostname and ports. `enable` refuses occupied TCP and UDP ports
and disables both units if the ten-second HTTP/2/HTTP/3 health gate fails. The
gateway waits for the loopback backend before binding. The fixed URLs after
`verify-live` passes are:

```text
https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity
https://lm.tail0168aa.ts.net:44724/stream/fetch?encoding=identity
```

Inspect or stop the service with one command. Stop preserves every immutable
source, asset, provenance, and TLS generation:

```sh
scripts/android-media/install-protocol-fixtures.sh status
scripts/android-media/install-protocol-fixtures.sh disable
```

For host probes, supply only the public CA certificate explicitly with
`--cacert`; never install it as a host root and never copy either private key:

```sh
ca="$HOME/.local/state/helium-media-fixtures/tls/current/ca-cert.pem"
curl --http2 --cacert "$ca" \
  'https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity'
curl --http3-only --cacert "$ca" \
  'https://lm.tail0168aa.ts.net:44724/stream/fetch?encoding=identity'
```

The disposable Android test browser must be launched with the receipt's exact
`required_chromium_switch`, never the broad `--ignore-certificate-errors`, and
with its existing test-only automation/CDP switch so the runner can inspect
the effective browser command line. Pass the same receipt to the runner with
`--fixture-receipt`. The runner already rejects every normal package, rejects
a missing/different/multiple certificate override, and stores the receipt and
hash in evidence. Never put this override into a normal launcher or a global
Android flag file.

Use the repository boundary to stage that exact command line and launch the
admitted test package:

```sh
fixture_receipt="$HOME/.local/state/helium-media-fixtures/config/fixture-provenance.json"
"$sync_acceptance/runtime-acceptance/disposable-browser.sh" \
  launch "$sync_acceptance" "$serial" \
  --fixture-receipt "$fixture_receipt"
```

The launch has exactly `--enable-automation`, the package-specific DevTools
socket, and, only when supplied, the receipt's exact SPKI override. Before
writing anything it snapshots both `/data/local/tmp/chrome-command-line` and
`/data/local/chrome-command-line`, including bytes, existence, and mode. It
refuses symlinks, non-files, a concurrent change, an existing Android
`debug_app`, or an existing wait-for-debugger state. It temporarily selects
only the admitted `.test` package, waits for its one exact abstract socket,
then clears that selection and restores or removes both global files before
returning. A successful browser process remains running with the flags it
already consumed. Every failure after launch begins force-stops only that
disposable package. Restoration failure is a hard failure; the boundary never
continues to the probe.

For the upstream control, repeat `install` and `launch` with its distinct
prepared directory. The boundary derives
`helium_control_test_devtools_remote` from the admitted control package; a
caller cannot supply or reuse a socket name.

Tailscale's publicly trusted certificate remains an optional later
simplification. It requires enabling HTTPS for the tailnet and acknowledging
public Certificate Transparency publication of lm's DNS name; it is not a
fixture availability requirement.

As of 2026-07-22, the MTU-safe rootless service is enabled and survived a
source refresh without replacing its private CA, leaf, SPKI, or endpoint
receipt. lm and da both pass private-CA HTTP/2, Alt-Svc warm-up, direct
HTTP/3, exact-body, receipt, and HTTP/2-port direct-QUIC-refusal checks.
The server-side qlog diagnosis and the before/after packet sizes are recorded
in the issue ledger; qlog is diagnostic-only and is not enabled on the
credential-free service.

After `disposable-browser.sh install`, the optional Sync-only cookie fixture
preparation, and `disposable-browser.sh launch` succeed on disposable oneplus
state, run the artifact-carried device orchestrator from the host connected to
that device. Use a new evidence directory for every run. The two HTTPS
endpoints must be credential-free synthetic fixtures: configure the first to
allow HTTP/2 but not HTTP/3 and the second to advertise and serve HTTP/3. The
browser records the actually negotiated protocols:

```sh
acceptance=/srv/nas/helium-acceptance/JOB
serial=ONEPLUS_ADB_SERIAL
evidence=/srv/nas/helium-acceptance-evidence/JOB/oneplus-sync-N
fixture_receipt="$HOME/.local/state/helium-media-fixtures/config/fixture-provenance.json"
"$acceptance/runtime-acceptance/run-device-probe.sh" \
  "$acceptance" "$serial" "$evidence" \
  --h2 'https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity' \
  --h3 'https://lm.tail0168aa.ts.net:44724/stream/fetch?encoding=identity' \
  --fixture-receipt "$fixture_receipt" \
  --background-foreground true \
  --network-handoff wifi-to-cellular
(cd "$evidence" && sha256sum -c EVIDENCE_SHA256SUMS)
```

The test app must already be the hash-verified `computer.helium.sync.test` APK;
the local fixture and CDP endpoints stay on loopback. The runner verifies the
complete prepared-directory inventory, requires the installed package's
versionCode and versionName to match the admitted artifact, refuses existing
evidence, and uses only its two fixed ADB mappings.
It never installs, clears, or uninstalls an app and never uses `--remove-all`.
The Wi-Fi handoff is allowed only over a non-network ADB transport, requires
mobile data and Wi-Fi to start enabled, and restores Wi-Fi on every exit. Its
action evidence contains package/action/timestamp metadata, not SSIDs,
addresses, page content, or profile data.
For both Sync and control it also starts `adb logcat` with only the admitted
package UID, enables CDP's target-scoped `Media` domain before fixture
navigation, and stores `package-logcat.txt` plus `media-diagnostics.json`. It
never calls `logcat -c`. On a probe failure the requested new evidence
directory is still committed with `failure.env` and every diagnostic produced
before failure; that directory is diagnostic only and the pair gate rejects it.

A passing result requires three observable
numbered-chunk milestones for identity, gzip, and Brotli Fetch responses,
strictly time-separated milestone and ordered SSE delivery, a controlled
Service Worker streaming pass-through, verified MP4/WebM/MSE fixtures, completed playback, video
dimensions, decoded-audio evidence, required codec capabilities, and browser
product/protocol provenance. When requested, the same result must contain
actual `h2` and `h3` `PerformanceResourceTiming.nextHopProtocol` values, an
ordered hidden-to-visible transition, and a Network Information API change
event. The probe consumes an initial HTTP/3-origin response to allow Alt-Svc
discovery, records its protocol/status/timing, and then requires the measured
stream to use `h3`. Run the identical command with a new directory for the same-commit
upstream control; ChatGPT timing remains a separate content-free manual gate.

Do not compare the two results by inspection. After both exact commands pass,
produce one immutable pair receipt with the verifier carried by either admitted
artifact (the verifier sources must be byte-identical):

```sh
"$sync_acceptance/runtime-acceptance/verify-probe-pair.sh" \
  "$sync_acceptance" "$sync_evidence" \
  "$control_acceptance" "$control_evidence" \
  /srv/nas/helium-acceptance-evidence/JOB/oneplus-media-ab.env
```

The pair gate requires both disposable package roles, the same full Helium
Sync and Chromium commits, byte-identical probe sources and media manifest,
the same private fixture receipt, HTTP/2 and HTTP/3, background and foreground,
Wi-Fi-to-cellular handoff, Service Worker streaming, and artifact-bound CDP
results. It fails closed instead of accepting two passing runs from different
source locks.

A copied backup never opens a browser.

## 3. Prepare lm without activating personal sync

Helium Sync uses Tailscale as its confidentiality and peer-authentication
boundary. The server endpoint is exactly:

```text
http://LM_TAILSCALE_IPV4:44719
```

`LM_TAILSCALE_IPV4` must be the single current `100.64.0.0/10` address reported
for lm. The installers reject DNS names, HTTPS, wildcard/listen-all addresses,
wrong ports, public Serve/Funnel state, and endpoints that do not match the live
Tailnet identity. There is no Helium TLS CA or content-encryption key.

First deploy the source generation while production remains inactive:

```sh
sudo scripts/install-lm-sync-service.sh install-source
sudo scripts/install-lm-sync-service.sh install-endpoint
sudo scripts/install-lm-sync-service.sh verify-source
sudo scripts/install-lm-sync-service.sh verify-endpoint
sudo scripts/install-lm-sync-service.sh status
```

The source installer requires a clean pushed commit, builds outside tmpfs,
records checksums and build information in an immutable generation, points the
systemd units at that generation, and does not initialize or enable the
service. `endpoint.env` contains only `HELIUM_SYNC_LISTEN=IP:44719`.

The production service runs as the dedicated `helium-sync` account, writes only
`/var/lib/helium-sync`, and is restricted to Tailnet IPv4 peers. Its server
backup contains the hash-only registry, readable journal, snapshots, and
optional quarantine. It never contains client bearer tokens. Before production
activation:

```sh
sudo scripts/install-lm-sync-service.sh backup-drill
sudo scripts/install-lm-sync-service.sh enable
```

`enable` is intentionally a separate action. It refuses another port-44719
listener and requires a fresh restore drill. Do not run either command for
personal service state until disposable native browser gates and personal
profile backups pass.

### Synthetic rootless service

The user service is the only service that may be exercised now. It is
marker-gated synthetic state and must never receive personal credentials or
browser content:

```sh
scripts/install-lm-disposable-sync-service.sh install-source
scripts/install-lm-disposable-sync-service.sh install-endpoint
scripts/install-lm-disposable-sync-service.sh initialize BOOTSTRAP_JSON
scripts/install-lm-disposable-sync-service.sh backup-drill
scripts/install-lm-disposable-sync-service.sh enable
scripts/install-lm-disposable-sync-service.sh status
```

Initialization accepts the hash-only `server-bootstrap.json` emitted by a
temporary `helium-sync seed-init`. The matching client directory is disposable
test state. The independent user backup timer writes private readable server
archives to `/srv/nas/helium-sync-server-disposable` and proves restore before
activation. `disable` stops and disables the service and timer but preserves
all generations.

Only one production or disposable process may own port 44719.

## 4. Seed and join model

Do not create personal state without explicit approval. For a disposable seed:

```sh
umask 077
helium-sync seed-init \
  --state-file /secure/disposable/helium-sync-d/client.json \
  --token-file /secure/disposable/helium-sync-d/token \
  --bootstrap-file /secure/disposable/server-bootstrap.json
```

`client.json` schema 2 and `token` stay together in the client directory.
`server-bootstrap.json` contains the device ID, role, scopes, and only the
SHA-256 credential hash. Initialize the inactive server from that bootstrap;
never copy a client token into server state.

A joining disposable client starts pending and pull-only:

```sh
helium-sync join-init \
  --device synthetic-join \
  --state-file /secure/disposable/helium-sync-join/client.json \
  --token-file /secure/disposable/helium-sync-join/token \
  --auth-request-file /secure/disposable/join-server-request.json
sudo scripts/install-lm-sync-service.sh enroll-device \
  /secure/disposable/join-server-request.json
```

The native password and cookie bridges must both pull, apply, read back, and
durably acknowledge the same global cursor before promotion. Pending clients
cannot publish. There is no key wrapping, recovery-recipient exchange, or
content-key rotation.

Install one enrollment directory per stopped disposable profile:

```text
PROFILE/Default/helium-sync/
  base_url
  client.json
  token
```

`base_url` is exact private-Tailnet HTTP on port 44719. The native bridges add
their own state files after the first successful run. An offline diagnostic
promotion can use:

```sh
helium-sync enrollment-complete \
  --url http://LM_TAILSCALE_IPV4:44719 \
  --profile-dir /ABSOLUTE/DISPOSABLE-PROFILE \
  --state-file /ABSOLUTE/DISPOSABLE-PROFILE/Default/helium-sync/client.json \
  --token-file /ABSOLUTE/DISPOSABLE-PROFILE/Default/helium-sync/token
```

Never copy one profile's enrollment directory into another profile.

## 5. Bearer rotation and revocation

Every remote command uses the exact HTTP Tailnet URL, the device's schema-2
`client.json`, and its current `token` file:

```sh
helium-sync credential-stage \
  --url http://LM_TAILSCALE_IPV4:44719 \
  --state-file /ABSOLUTE/PROFILE/Default/helium-sync/client.json \
  --token-file /ABSOLUTE/PROFILE/Default/helium-sync/token
```

Stop the disposable browser before activating a staged credential, then
confirm it and retire the old credential according to the CLI help. The
registry keeps only credential hashes. Registry mutations go through
`install-lm-sync-service.sh enroll-device` or `revoke-device`, which stop an
active daemon, validate the complete registry, and restore the prior active
state only after health succeeds.

## 6. Private two-copy profile gate

Before any future personal install, stop the exact profile and use
`scripts/profile-backup/helium-profile-backup.sh` with config schema 3. The
fixed topology is one NAS copy on lm plus one authenticated peer copy. The
producer streams one zstd archive directly to both private destinations,
records the same SHA-256 and size, and stages no source-local archive.

Run `preflight`, `backup`, `status`, `receipt-export`, and an independent
`restore-to-disposable` from each destination. A restore can create only a new
`drill-*` child of a mode-0700 marked root and never launches a browser. See
[profile-deployment.md](profile-deployment.md).

## 7. Personal rollout remains gated

No personal profile, device enrollment, service credential, or sync activation
is authorized by this source repair. After a returned Chromium artifact passes
the disposable password, cookie, enrollment, tab, media, and backup gates, the
later explicitly approved order is d seed first, then da, then oneplus. Each
step must preserve the previous browser artifact, enrollment, and profile
generation for rollback.
