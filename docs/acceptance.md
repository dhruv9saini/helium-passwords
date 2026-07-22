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
sync-store journal recovery, constrained TLS
issuance, wrong-identity rejection, and a TLS 1.3 handshake. It does not
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
- The returned Android archive must carry a checksum-verified runtime acceptance
  kit bound to the same Helium Sync commit, Chromium commit, package, arm64 CPU,
  and `chrome_public_apk` target. A prepared disposable directory must pass its
  complete `PACKAGE_SHA256SUMS` inventory before installation or execution.
- Both the Sync and upstream-control archives carry the realized Chromiumer Nix
  store path, closure hash/size, realization capacity record, and exact
  shell-escaped build command inside the artifact checksum boundary. Sync
  provenance requires the locked Helium core plus core/Passwords/Sync
  composition layers; the control requires a clean Chromium tree and the sole
  `upstream-control` marker, and rejects any patched-composition provenance.
- Tailscale Serve and Funnel are empty on lm. The installed TLS generation
  verifies against lm's current `.ts.net` name and `100.64.0.0/10` IPv4
  address, has at least 30 days remaining, and the offline CA private key is
  absent from lm, NAS backups, source, and build hosts.
- Each disposable client independently authenticates and enrolls the exact CA
  DER SHA-256 before receiving its URL or bearer token. The correct root
  reaches `https://lm.<tailnet>.ts.net:44719/v2/health` with TLS 1.3; missing,
  substituted, unconstrained, expired, and wrong-host roots/leaves fail before
  an Authorization header is sent. Port 44719 is unreachable outside the
  tailnet and no cleartext response exists on that address.

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
Its receipt binds secret-free bridge state and opaque-journal metadata to the
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
  remain distinct. A schema-3 state with both forms fails migration without
  dropping its preserved legacy state or merging the two forms.
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
- Enrollment promotion and content-key rekey reject schema-3, legacy-preserved,
  queued, or pending password state.

## Gate 3: Cookies and Login State

The fixture server issues controlled cookies and rotating opaque tokens.

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
- After a stopped-browser content-key cutover, a higher CAS revision
  re-encrypted under the active epoch applies and advances the cookie record's
  epoch. Same-revision epoch substitution, higher revisions under a stale
  epoch, and unknown epochs all fail closed.
- Expired cookies are not recreated. A verified local deletion creates a
  revisioned tombstone.
- A device-bound-session fixture or known DBSC test site never classifies all
  cookies on the site. An actual destination rejection records the exact
  canonical cookie key, remote revision and payload fingerprint plus exact
  same-site session keys observed locally, without claiming a session-to-cookie
  binding or successful destination authentication.
- A synthetic schema-2 cookie state migrates to schema 3 after writing an
  atomic mode-0600 `schema-v2.bak`; the active state rewrite is also atomic.
  Revisions, fingerprints, deletion state, and pending CAS state survive; the
  old site-wide `non_clonable` fields do not.
- Every apply records a destination preview and sealed rollback first. A
  rejected set or verification mismatch restores the destination snapshot.
- The same rejected revision is not retried every cycle. A higher active-epoch
  remote revision retries transactionally; a real local cookie change after
  reauthentication may publish the next CAS revision; successful readback
  clears the prior exception without overwriting the last-good rollback state.
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

## Gate 4: Durable Tabs

- A profile with multiple windows, pinned tabs, groups, duplicate URLs,
  back/forward history, and an unloaded tab restores locally after clean exit.
- The same state restores after a forced crash without pre-marking the profile
  clean.
- No server request, record, schema, credential, or normal launch path contains
  tabs. A backup from one device is never displayed or auto-opened on another.
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
  Before first launch, `validate-browser-profile` proves the current startup
  URLs still match the retained neutral restore and that no clean-exit state
  was forged. Normal launch never rewrites clean-exit state or broadly deletes
  pages through CDP.
- Corrupt the newest local session, newest local snapshot, NAS copy, and second
  host copy separately; in every case a different independent recovery path
  succeeds without changing a live profile.

## Gate 5: Android Media

Record `canPlayType`, `MediaCapabilities.decodingInfo`, playback completion,
audio presence, dropped frames, and `chrome://media-internals`/logcat outcome.

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

## Gate 6: Streaming Responses

For each HTTP/1.1 chunked, HTTP/2, HTTP/3, SSE, Fetch `ReadableStream`, gzip,
and Brotli fixture:

- headers arrive within the fixture timeout;
- at least three strictly increasing numbered-chunk milestones become visible
  before response completion (network read count alone is not evidence);
- chunk order and final payload are correct;
- the page remains interactive during the stream;
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
endpoint. Launch the admitted test package with exactly one
`--enable-automation` switch and its exact command-line override:

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
- Prove opaque server backup restore before registering the first join device.
- Prove both independently held recovery identities can decrypt their own
  off-source copy into new disposable directories and recover the authenticated
  d signing public key; a single recipient or existing restore target fails.
- Install only a hash-verified artifact returned by chromiumer. Keep the prior
  application and untouched profile backup until all gates pass.
- Enroll d first, da second, and oneplus third. After each join, prove zero
  initial publication and zero unchanged-restart publication before proceeding.
- Verify the server survives stop/start and restored opaque state; verify each
  device's tab backup freshness, both off-source hashes, corruption quarantine,
  and disposable restore.
