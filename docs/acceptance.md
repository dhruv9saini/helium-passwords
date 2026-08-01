# Helium Browser Acceptance Gates

All automated browser tests use a disposable profile, fixture credentials, and
local test servers. Logs may contain fixture values but never real credentials,
cookies, tokens, URLs from real sessions, or profile contents.

The source-level synthetic gate is:

```sh
node --test scripts/tests/*.test.mjs
go test ./...
```

It currently proves the HS-001 reconcile state machine, cookie partition and
source/replica semantics, independent tab generation/retention/restore
invariants, bounded immutable multi-page record snapshots, authenticated
sync-store journal recovery, exact private-Tailnet endpoint admission, and
hash-only bearer authentication. It does not
replace the browser gates below.

## Gate 0: Provenance and Source Preparation

- Working trees are clean and Helium Sync contains the selected Helium
  Passwords commit.
- Both password patches are byte-identical across repositories.
- Helium core, every platform repo, and Chromium resolve to the manifest's
  exact commits and one Chromium version.
- Ordered patch hashes and complete GN args match the artifact manifest.
- Every patch passes source-backed application checks before compilation.
- `scripts/dev.sh check` passes in both repositories.
- `scripts/chromiumer-job.sh preflight <disk-budget-gib>` passes, the staged
  job records that same explicit budget, the source manifest matches the
  staged commit/tree/archive, and the detached job reports the production
  cgroup limits and a healthy watchdog.
- The returned artifact hash matches chromiumer's hash and an artifact receipt
  exists before its build workspace is eligible for cleanup.
- Android disposable evidence uses `computer.helium.sync.test`; manifest and GN
  provenance must agree. It must coexist with, and never upgrade or read, the
  existing `computer.helium.sync` app data.
- The disposable Sync and control packages are non-debug Chromium builds with
  DCHECKs disabled but have `debuggable_apks = true` for rootless test-only
  command-line selection and synthetic bridge inspection. Production
  `computer.helium.sync` has `debuggable_apks = false`. Artifact admission
  requires the GN value and manifest flag to agree with the package role.
- The returned Android archive must carry a checksum-verified runtime acceptance
  kit bound to the same Helium Sync commit, Chromium commit, package, arm64 CPU,
  and `chrome_public_apk` target. A prepared disposable directory must pass its
  complete `PACKAGE_SHA256SUMS` inventory before installation or execution.
- Installation and launch use the prepared directory's artifact-carried
  `runtime-acceptance/disposable-browser.sh`. It admits only the exact prepared
  `.test` APK, re-hashes the installed base APK, derives the fixed package
  socket, and restores both Android global Chromium command-line files plus the
  temporary debug-app selection on every exit. Pre-existing debug state,
  unsafe command-line paths, concurrent changes, a broad certificate bypass,
  or a non-receipt SPKI override fail before probing.
- Both the Sync and upstream-control archives carry the realized Chromiumer Nix
  store path, closure hash/size, realization capacity record, and exact
  shell-escaped build command inside the artifact checksum boundary. Sync
  provenance requires the locked Helium core plus core/Passwords/Sync
  composition layers; the control requires a clean Chromium tree and the sole
  `upstream-control` marker, and rejects any patched-composition provenance.
- No public Tailscale Funnel exists on lm and no Serve listener, Web proxy
  target, or TCP forward target has numeric port 44719. Leading-zero spellings
  are parsed as the same port, malformed targets fail closed, and unrelated
  tailnet-only Serve routes may coexist. Present `Foreground` and `Services`
  containers and every recursively descended config must be non-null objects.
  Run `scripts/tailnet-serve-acceptance.sh begin
  ABSOLUTE_NEW_STATE_DIRECTORY` before browser acceptance and the matching
  `verify` action afterward; the latter creates a receipt only when the
  canonical before/after JSON is byte-identical and has the same hash. The
  installed endpoint contains only lm's exact current Tailscale IPv4 address
  and port 44719.
- Each disposable client accepts only
  `http://<literal-100.64.0.0/10-address>:44719`. DNS names, HTTPS, userinfo,
  query/fragment components, wildcard addresses, and any non-Tailnet route fail
  before an Authorization header is sent.

## Gate 1: Helium Passwords

Run on Linux first, then the supported manual subset on macOS and Windows.
The executable artifact-bound protocol is
[`password-runtime-acceptance.md`](password-runtime-acceptance.md). Its final
public receipt requires the complete ordered native UI screenshot set and
loopback fixture attestation; a checklist alone cannot pass this gate.

- Native settings, app-menu, omnibox, toolbar/page-action, and importer entry
  points open the intended native surfaces.
- A fixture HTML login submission prompts once to save.
- Saved credentials survive a clean restart and a crash restart.
- Username/password suggestions and fill work after restart.
- A changed fixture password produces an update prompt and replaces the value.
- Decline and never-save behavior is scoped correctly.
- Guest and incognito sessions do not persist credentials.
- Browser restart and upgrade do not corrupt the native store.
- The runtime harness receipt binds all public evidence to the unchanged
  artifact and Linux synthetic profile or `computer.helium.sync.test` package.

## Gate 2: Password Sync

Use three disposable profiles named `oneplus-test`, `d-test`, and `da-test`.
For the native lifecycle, run the private extension in
[`password-runtime-sync-acceptance.md`](password-runtime-sync-acceptance.md).
Its receipt binds secret-free bridge state and readable-journal metadata to the
public screenshots and enforces save/update/tombstone revisions plus three
byte-identical no-op restart snapshots.

- d is explicitly created as the sole seed. da and oneplus start pending and
  pull d's inventory without publishing any pre-existing local credential.
- Native promotion occurs only after password and cookie bridges independently
  apply, read back, persist, and acknowledge the same current server cursor;
  mismatched cursors trigger another pull and publish nothing. The offline
  completion command proves the equivalent stopped-profile gate.
- Restarting an unchanged profile publishes zero password records.
- Two password forms that differ only in username element or password element
  remain distinct. Password state accepts only schema 6 and has no legacy
  migration map.
- Rapid update/update/delete observer events publish one record at a time; the
  next mutation uses the pulled accepted revision rather than reusing the first
  mutation's expected revision.
- Terminate the browser after the server accepts a mutation but before a usable
  response reaches the bridge. Restart resolves the durable pending intent by
  pull: an exact accepted record advances, an unchanged baseline retries, and a
  different newer record stops as stale.
- One profile changes a password while a second is offline; reconnecting the
  stale profile does not overwrite the newer value.
- Independent credentials changed offline converge after reconnect.
- A verified local deletion creates a tombstone; a new or stale device cannot
  resurrect it.
- Unicode usernames, Android facets, federated credentials, notes, passkeys
  where supported, and multiple credentials for one origin preserve identity.
- A malformed, oversized, unknown-version, or unauthenticated record is
  rejected while the last good record stays usable.
- Token rotation completes with an overlap window, then the old token is
  rejected on every client. The stopped-profile cutover preserves a mode-0600
  rollback token and atomically installs only a server-confirmed new token.
- No plaintext password or bearer token appears in daemon/browser logs.
- Enrollment promotion rejects unknown schemas and queued or pending password
  publication state.

## Gate 3: Cookies and Login State

The fixture server issues controlled cookies and rotating synthetic tokens.
The Linux d/da transport lifecycle and immutable receipt are specified in
[`cookie-runtime-acceptance.md`](cookie-runtime-acceptance.md). It proves one
real host-only HttpOnly cookie create/update/tombstone round trip through two
returned-browser disposable profiles; it does not substitute for the Android
transaction fixture or the broader attribute and partition matrix below.
Before the networked three-client cases, the Android Sync test package must
pass its browser-native CookieManager fixture. Prepare only a stopped,
hash-admitted `computer.helium.sync.test` package with the artifact-carried
`prepare-cookie-acceptance-profile.sh`. It refuses an existing `Default`
directory, writes one mode-0600 marker, and never clears or force-stops an app.
On the next launch the native service sees that marker before enrollment,
requires the debuggable test package and an otherwise empty cookie store, and
returns without starting normal password or cookie sync.
The browser opens the marker with `O_NOFOLLOW|O_NONBLOCK`, then requires a
regular file with the exact mode, size, and contents before the first
CookieManager read. The output directory must not exist. An unsafe marker or
output path suppresses normal sync but deliberately writes no report through
that untrusted path; the package-scoped log is the only failure signal.

The fixed synthetic transaction creates a known destination cookie, persists
its complete snapshot before apply, imports a three-record target through
`network::mojom::CookieManager`, and reads the whole store back. The target
covers session and persistent, HttpOnly, Secure, SameSite, host-only, domain,
partitioned, and unpartitioned records. The fixture requires partitioned and
unpartitioned canonical keys to remain distinct. It then submits a valid
Secure cookie against an HTTP source, requires Chromium to reject it, restores
the destination snapshot through CookieManager, verifies rollback, and cleans
the synthetic store. Its report contains only counts, booleans, and
fingerprints. It reports zero origin-state adapters and `not-tested` rather
than inventing localStorage, IndexedDB, or service-worker portability. A pass
proves CookieManager transaction mechanics only; it does not claim that a
destination is authenticated or that any site session is portable.

- Host-only and domain cookies remain distinct.
- Secure, HttpOnly, SameSite, priority, path, expiry, source scheme/port, and
  session/persistent behavior round-trip where CDP/Chromium supports them.
- Partitioned and unpartitioned cookies with identical domain/path/name remain
  separate across two top-level sites.
- All live cookies are selected by default, including session, persistent,
  HttpOnly, Secure, SameSite, host-only, domain, and partitioned cookies. Only
  expired/malformed records or an exact destination-rejected revision are
  absent from the destination after verified rollback.
- One authenticated device rotates a token twice; destinations receive each
  revision and never ping-pong the previous token. A concurrent local edit and
  newer remote revision stops without discarding the last good local session.
- A higher CAS revision applies and advances the cookie record. Same-revision
  payload substitution and stale expected revisions fail closed.
- Expired cookies are not recreated. A verified local deletion creates a
  revisioned tombstone.
- A device-bound-session fixture or known DBSC test site never classifies all
  cookies on the site. An actual destination rejection records the exact
  canonical cookie key, remote revision and payload fingerprint plus exact
  same-site session keys observed locally, without claiming a session-to-cookie
  binding or successful destination authentication.
- Cookie state accepts only schema 5. Revisions, fingerprints, deletion state,
  pending CAS state, and exact destination exceptions are atomic; legacy
  schemas and content-key fields fail closed.
- Every apply records a destination preview and private readable rollback first. A
  rejected set or verification mismatch restores the destination snapshot.
- A pending join with a different local cookie at the same canonical identity
  transactionally applies d's authoritative value under that rollback; its
  unrelated local cookies remain unpublished during initial enrollment.
- More than 32 local cookie changes drain over multiple deterministic
  publication batches, and no serialized native request exceeds 4 MiB.
- The same rejected revision is not retried every cycle. A higher
  remote revision retries transactionally. A local cookie change while the
  exception remains is marked unverified, held locally, and never published as
  proof of reauthentication. Successful readback clears the prior exception
  without overwriting the last-good rollback state.
- The local reauthentication intent contains the schemeful site but no guessed
  origin or login path, forbids navigation and automatic form submission, and
  cannot claim browser-native reauthentication until a disposable run provides
  the exact origin, entry, tab, and discovered password form.
- Android browser suspension and process restart recover without overwriting a
  newer remote record. No DevTools path participates.
- Cookie payload corruption is detected before apply.
- For each target site, audit localStorage, IndexedDB, service-worker storage,
  and other origin state in disposable profiles. Transfer only an evidenced,
  origin-scoped export; never live-merge an application database.
- Bind the metadata-only audit to the exact disposable artifact and target:
  `node scripts/session-state/origin-state-audit.mjs EVIDENCE.json ARTIFACT`.
  Synthetic evidence must produce only synthetic/unknown classifications;
  a missing, symlinked, or hash-mismatched artifact and any secret-bearing
  evidence field must fail.
- Origin-state evidence schema 2 requires separate preview, apply, readback,
  and rollback results. Because no source-registered adapter exists, any
  evidence that names one or reports a transfer result fails closed.

## Gate 4: Durable Tabs

- A profile with multiple windows, pinned tabs, groups, duplicate URLs,
  back/forward history, and an unloaded tab restores locally after clean exit.
- The same state restores after a forced crash without pre-marking the profile
  clean.
- No server request, record, schema, credential, or normal launch path contains
  tabs. A backup from one device is never displayed or auto-opened on another.
- Prove all three mechanisms independently: Chromium clean/crash session
  recovery, neutral topology generations, and stopped compressed full-profile
  generations. Two replicas of one generation still count as one mechanism.
- Each source runs its own capture/backup schedule. d and oneplus each copy to
  lm NAS and da; da copies to lm NAS and d. Destination namespaces never merge.
- An empty, malformed, oversized, wrong-parent, or unknown-schema local
  generation leaves the previous known-good local generation available.
- Snapshot creation while quiescent produces a hash-valid immutable generation.
- Retention keeps configured hourly/daily/weekly buckets and protected
  known-good generations, and never removes the last valid copy or any local
  generation lacking two verified off-source copies.
- A restore drill into a disposable profile checks counts and representative
  state, restarts a second time, and records success.
- Before any browser preparation, the standalone `validate-restore` command
  independently rechecks the receipt's source binding, session hash and size,
  strict schemas, permissions, symlink rejection, and exact two-file
  inventory. `prepare-browser-profile` accepts only a nonexistent `drill-*`
  child of an exactly marked mode-0700 disposable root, never a normal profile.
  Before first launch, `validate-browser-profile` proves the complete retained
  topology matches manifest counts and hashes, both versioned disposable
  markers are exact, Preferences are empty, and no startup or clean-exit state
  was forged. The explicit native importer must reconstruct and read back every
  supported live field. `validate-browser-state` must then bind its terminal
  marker and receipt to the exact immutable input. Close and relaunch the
  disposable profile without the import switch to prove Chromium persisted it.
  Normal launch never consumes a backup, rewrites clean-exit state, or broadly
  deletes pages through CDP.
- A stopped full-profile generation uses a separate producer, configuration,
  format, retention state, and restore command from the neutral snapshots. It
  streams directly to both private off-device destinations, leaves no
  source-local archive, and restores only below a
  marked mode-0700 disposable root.
- `tab-recovery-health.sh` always emits exactly three distinct mechanism
  statuses. A missing, stale, wrong-device, future, symlinked, group-readable,
  or malformed proof makes only that named mechanism unhealthy; replicas do
  not create extra status entries. Produce these statuses only through the
  authenticated evidence workflow in `tab-runtime-proof.md`: native requires
  one clean/crash/second-restart proof; neutral and full-profile each require
  two validated proofs from distinct source destinations.
- Corrupt one neutral exporter, full-profile producer, scheduler, recovery
  key, retention plan, newest generation, and destination independently. In
  every case only that mechanism becomes red and a sibling recovery path
  remains usable without changing a live profile.

## Gate 5: Android Media

Record `canPlayType`, `MediaCapabilities.decodingInfo`, playback completion,
audio presence, dropped frames, CDP's pinned browser-observable `Media` domain,
and package-UID-scoped Android logcat. The runner creates the probe target at
`about:blank`, enables `Media` before navigating to the synthetic fixture, and
stores bounded player events in `media-diagnostics.json`; this is the
automation-safe Chromium 150 equivalent of reading `chrome://media-internals`.
It never clears global logcat and never captures another Android UID.

| Fixture | Expected |
| --- | --- |
| MP4 + H.264 baseline + AAC-LC | Plays with audio |
| MP4 + H.264 high profile + AAC | Plays if the device decoder reports support |
| WebM + VP9 + Opus | Plays |
| WebM/MP4 + AV1 | Matches OnePlus hardware/software capability and is recorded |
| MSE segmented H.264/AAC | Appends and plays to completion |
| HLS/DASH test manifest | The fixture parser resolves only fixed same-origin media and appends the init/media fragments through MSE |
| Widevine DRM fixture | EME API and `com.widevine.alpha` availability are recorded separately; protected playback is expected to fail until CDM provisioning is deliberately implemented |

Run the matrix on an upstream Chromium control APK and Helium Sync APK from the
same Chromium commit. The artifact-carried probe must record the browser
product, CDP protocol/WebKit metadata, and fixture origin, verify all three
media fixture hashes, observe completed playback and nonzero duration, and
record video dimensions and decoded-audio bytes for MP4, WebM, and MSE. Missing
media manifest entries or unavailable audio evidence fail the automated gate
rather than silently reducing the matrix. The probe's Widevine key-system
observation is evidence only about EME/CDM availability; ordinary MP4 playback
does not count as DRM support, and no protected content is required or fetched.
Every pass also contains `package-logcat.txt`, a nonempty Media summary with at
least one observed player, and the complete bounded Media event file. If the
runner fails after staging begins, it still stops capture processes and
atomically preserves `failure.env`, package-only logcat, fixture logs, and any
Media/result files already produced in the requested evidence directory.
Failed evidence cannot satisfy the pair verifier.

## Gate 6: Streaming Responses

For each HTTP/1.1 chunked, HTTP/2, HTTP/3, SSE, Fetch `ReadableStream`, gzip,
and Brotli fixture:

- headers arrive within the fixture timeout;
- at least three strictly increasing numbered-chunk milestones become visible
  before response completion (network read count alone is not evidence);
- chunk order and final payload are correct;
- the page remains interactive during the stream;
- an activated disposable Service Worker relays an additional identity stream
  without buffering it;
- background/foreground and network handoff have a recorded result; and
- the upstream-control and patched-APK comparison identifies any regression.

Run the artifact-carried `runtime-acceptance/run-device-probe.sh` from the
prepared acceptance directory. For the combined lifecycle gate, use a USB or
other non-network ADB transport, request the background/foreground cycle, and
request `wifi-to-cellular`; the runner fails before changing networking unless
Wi-Fi and mobile data are both enabled and restores Wi-Fi on every exit. The
HTTP/2 and HTTP/3 URLs are separate credential-free synthetic HTTPS origins.
Evidence passes only when the browser reports the requested `h2`/`h3`
negotiation and the page observes the required visibility and connection
events. Before the measured HTTP/3 request, the probe fully consumes one
warm-up response so the browser can learn the origin's authenticated Alt-Svc
advertisement; the measured request still must report `h3`. A script action
alone is not acceptance evidence.

On lm, `scripts/android-media/install-protocol-fixtures.sh verify-live` is a
mandatory precondition. It requires the explicitly supplied disposable
private CA, TLS 1.3, exact tailnet-IP binding, no Alt-Svc or UDP listener on the
HTTP/2-only origin, the
explicit pinned Alt-Svc port on the HTTP/3 origin, actual curl HTTP versions 2
and 3, absent `Set-Cookie`, and exact fixture bodies. The admitted endpoints
are `https://lm.tail0168aa.ts.net:44723/stream/fetch?encoding=identity` and
`https://lm.tail0168aa.ts.net:44724/stream/fetch?encoding=identity`. The
fixture receipt's exact SPKI override must be the running `.test` browser's
only certificate override; the broad ignore-certificate-errors switch and any
normal package fail before evidence capture. The temporary self-signed runtime
test proves source behavior only and cannot satisfy this device gate.

The two APKs are independently installable and must never share a DevTools
endpoint. Install and launch each prepared directory with the boundary before
running the artifact-carried probe:

```sh
acceptance=/srv/nas/helium-acceptance/JOB
serial=ONEPLUS_ADB_SERIAL
"$acceptance/runtime-acceptance/disposable-browser.sh" \
  install "$acceptance" "$serial"
"$acceptance/runtime-acceptance/disposable-browser.sh" \
  launch "$acceptance" "$serial" \
  --fixture-receipt \
    "$HOME/.local/state/helium-media-fixtures/config/fixture-provenance.json"
```

The admitted process receives exactly one `--enable-automation` switch and its
derived command-line override:

```text
computer.helium.sync.test     --remote-debugging-socket-name=helium_sync_test_devtools_remote
computer.helium.control.test  --remote-debugging-socket-name=helium_control_test_devtools_remote
```

The device runner hashes the installed monolithic `base.apk` and compares it
with `Browser-test.apk`, requires the installed version, requires one running
main process and one exact abstract socket, forwards only that socket, and then
requires CDP's `Android-Package` and embedded WebKit source revision to match
the artifact. A same-version different APK, generic/fallback Chrome socket,
wrong package, or wrong source revision fails before a probe target is created.

After both device runs pass, use the artifact-carried
`verify-probe-pair.sh` to create the A/B receipt. It refuses a different private
source commit, Chromium commit, runtime kit, fixture certificate, media byte
manifest, lifecycle matrix, or package-bound result. Separate individually
passing result files are not an accepted A/B comparison.

After deterministic gates pass, run ChatGPT as a manual end-to-end scenario and
record only timing/status observations, never conversation content or tokens.

## Gate 7: Device Matrix

| Device | Desktop browser | Android browser | Required manual checks |
| --- | --- | --- | --- |
| `d` | Linux x86_64 | N/A | Authoritative seed, password lifecycle, service restart, local tab restore |
| `da` | Linux x86_64 | N/A | Pull-only join, password/cookie convergence, independent local tab restore |
| `oneplus` | Linux ARM64 chroot Helium | Android arm64 Helium Sync | Native Android password store, background sync, codecs, streaming, tab restore |

An artifact is releasable only when every applicable gate has a linked result
and every expected failure is explicit.

## Gate 8: Rollout and rollback

- Before any install, stop the disposable or personal browser and create a
  checksum manifest plus two recoverable copies of its complete profile.
- Prove readable private server backup restore before registering the first
  join device.
- Prove both fixed private profile-backup destinations restore their
  checksum-identical archive into separate new disposable directories; an
  existing restore target fails.
- Install only a hash-verified artifact returned by chromiumer. Keep the prior
  application and untouched profile backup until all gates pass.
- Enroll d first, da second, and oneplus third. After each join, prove zero
  initial publication and zero unchanged-restart publication before proceeding.
- Verify the server survives stop/start and restored readable state; verify each
  device's tab backup freshness, both off-source hashes, corruption quarantine,
  and disposable restore.
