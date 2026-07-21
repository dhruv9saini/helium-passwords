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
invariants, and authenticated sync-store journal recovery. It does not replace
the browser gates below.

## Gate 0: Provenance and Source Preparation

- Working trees are clean and Helium Sync contains the selected Helium
  Passwords commit.
- Both password patches are byte-identical across repositories.
- Helium core, every platform repo, and Chromium resolve to the manifest's
  exact commits and one Chromium version.
- Ordered patch hashes and complete GN args match the artifact manifest.
- Every patch passes source-backed application checks before compilation.
- `scripts/dev.sh check` passes in both repositories.
- `scripts/chromiumer-job.sh preflight` passes, the source manifest matches the
  staged commit/tree/archive, and the detached job reports the production
  cgroup limits and a healthy watchdog.
- The returned artifact hash matches chromiumer's hash and an artifact receipt
  exists before its build workspace is eligible for cleanup.

## Gate 1: Helium Passwords

Run on Linux first, then the supported manual subset on macOS and Windows.

- Native settings, app-menu, omnibox, toolbar/page-action, and importer entry
  points open the intended native surfaces.
- A fixture HTML login submission prompts once to save.
- Saved credentials survive a clean restart and a crash restart.
- Username/password suggestions and fill work after restart.
- A changed fixture password produces an update prompt and replaces the value.
- Decline and never-save behavior is scoped correctly.
- Guest and incognito sessions do not persist credentials.
- Browser restart and upgrade do not corrupt the native store.

## Gate 2: Password Sync

Use three disposable profiles named `oneplus-test`, `d-test`, and `da-test`.

- Initial merge imports a credential from each profile without duplicates.
- Restarting an unchanged profile publishes zero password records.
- One profile changes a password while a second is offline; reconnecting the
  stale profile does not overwrite the newer value.
- Independent credentials changed offline converge after reconnect.
- A local deletion does not propagate and a later remote upsert restores only
  according to the documented additive policy.
- Unicode usernames, Android facets, federated credentials, notes, passkeys
  where supported, and multiple credentials for one origin preserve identity.
- A malformed, oversized, unknown-version, or unauthenticated record is
  rejected while the last good record stays usable.
- Token rotation completes with an overlap window, then the old token is
  rejected on every client.
- No plaintext password or bearer token appears in daemon/browser logs.

## Gate 3: Cookies and Login State

The fixture server issues controlled cookies and rotating opaque tokens.

- Host-only and domain cookies remain distinct.
- Secure, HttpOnly, SameSite, priority, path, expiry, source scheme/port, and
  session/persistent behavior round-trip where CDP/Chromium supports them.
- Partitioned and unpartitioned cookies with identical domain/path/name remain
  separate across two top-level sites.
- The configured source rotates a token twice; replicas receive each new
  generation and never republish the previous token.
- Expired cookies are not recreated. Replica deletion does not delete source
  state.
- A device-bound-session fixture or known DBSC test site reports that the
  target device must reauthenticate rather than claiming cookie-sync success.
- Android browser suspension, DevTools unavailability, and process restart
  yield bounded retries and recover without overwriting the remote record.
- Cookie payload corruption is detected before apply.

## Gate 4: Durable Tabs

- A profile with multiple windows, pinned tabs, groups, duplicate URLs,
  back/forward history, and an unloaded tab restores locally after clean exit.
- The same state restores after a forced crash without pre-marking the profile
  clean.
- Each device appears as a separate foreign session. Importing a foreign tab
  never replaces or closes local tabs.
- Publishing an empty, malformed, oversized, wrong-parent, or unknown-schema
  generation leaves the previous foreign session available.
- Snapshot creation while quiescent produces a hash-valid immutable generation.
- Retention keeps 24 hourly, 14 daily, 12 weekly, and two protected known-good
  generations and never removes the last valid copy.
- A restore drill into a disposable profile checks counts and representative
  state, restarts a second time, and records success.
- Corrupt the newest local session, newest sync generation, and newest snapshot
  separately; in every case at least one independent recovery path succeeds.

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
| HLS/DASH test manifest | Plays only through the explicitly supported web/MSE path |
| Widevine DRM fixture | Expected failure until CDM provisioning is deliberately implemented |

Run the matrix on an upstream Chromium control APK and Helium Sync APK from the
same Chromium commit.

## Gate 6: Streaming Responses

For each HTTP/1.1 chunked, HTTP/2, HTTP/3, SSE, Fetch `ReadableStream`, gzip,
and Brotli fixture:

- headers arrive within the fixture timeout;
- at least three numbered chunks become visible before response completion;
- chunk order and final payload are correct;
- the page remains interactive during the stream;
- background/foreground and network handoff have a recorded result; and
- the upstream-control and patched-APK comparison identifies any regression.

After deterministic gates pass, run ChatGPT as a manual end-to-end scenario and
record only timing/status observations, never conversation content or tokens.

## Gate 7: Device Matrix

| Device | Desktop browser | Android browser | Required manual checks |
| --- | --- | --- | --- |
| `d` | Linux x86_64 | N/A | Password lifecycle, daemon restart, tab snapshot/restore |
| `da` | Confirm OS/arch in artifact manifest | N/A | Password convergence, foreign tabs, source/replica cookie role |
| `oneplus` | Linux ARM64 chroot Helium | Android arm64 Helium Sync | Native Android password store, background sync, codecs, streaming, tab restore |

An artifact is releasable only when every applicable gate has a linked result
and every expected failure is explicit.
