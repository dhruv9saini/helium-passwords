# Helium Sync Architecture

This document is the target architecture. The audit in
`audit-2026-07-21.md` distinguishes implemented behavior from design work.

## Product and Repository Boundaries

Helium Passwords is the public browser backbone. It owns native Chromium
password-manager restoration, desktop platform preparation, and the shared
developer command. Helium Sync is a private downstream Git history for the
personal browsers on `oneplus`, `d`, and `da`.

The source flow is one-way:

```text
imputnet/helium + platform release train
                  |
                  v
dhruv9saini/helium-passwords (public native password backbone)
                  |
                  v  Git merge through the `passwords` remote
dhruv9saini/helium-sync (private sync + Android + device integration)
```

No script copies shared patches from one working tree to the other. The private
history contains the public commit, and `scripts/dev.sh check` verifies both
ancestry and byte identity of the password patches.

Desktop and Android artifacts must resolve one immutable source manifest:

- public and private repository commits;
- Helium core and platform commits;
- Chromium commit/version;
- ordered patch hashes;
- complete GN args and target;
- toolchain/container identity; and
- artifact hash.

Moving `main` is not a build input.

`lm` is the development control plane, not a Chromium executor. Large Linux
and Android jobs run on chromiumer through the shared fail-closed wrapper in
`docs/chromiumer-builds.md`. The lm-side wrapper is only the source-transfer and
control client; its installed chromiumer worker enforces cgroup limits, a
100 GiB total job-tree allowance, an independent 20 GiB free-space reserve,
root-filesystem protection, a watchdog, and an eight-hour deadline. That policy
is part of artifact provenance; a build outside the envelope is not accepted.
The NAS receives completed, hashed artifacts but is not a compiler workspace.

## Data Ownership

| Data | Authoritative local interface | Cross-device role | Deletion policy |
| --- | --- | --- | --- |
| Passwords | Chromium `PasswordStoreInterface` and native password UI | Encrypted API-level records using complete Chromium credential semantics | Add/update only until deletion is explicitly designed and tested |
| Cookies | Chromium `CookieManager` or CDP `Storage` with the complete cookie key | Best-effort, per-domain source-to-replica handoff | Expiry is local; replica loss never deletes source state |
| Open tabs | Chromium session/tab APIs | Per-device foreign-session catalog, not a global merged window | Remote deletion cannot remove local tabs or snapshots |
| Session snapshots | Immutable versioned snapshot store | Recovery only | Retention removes only validated old generations in the same store |

Raw `Login Data` and cookie databases are never sync inputs. Tests use fresh
profiles and fixture credentials. Session files may be snapshotted only by the
dedicated tab recovery layer and are never treated as a cross-version API.

## Implementation Boundary (2026-07-21)

| Area | Completed code | Still requires browser/device integration |
| --- | --- | --- |
| Password convergence (HS-001) | Native C++ and CDP bridges use atomic per-credential hash/server-sequence state, reconcile remote before local publication, and fail closed on corrupt state. Pure synthetic tests cover unchanged restart, stale-device conflict, offline edits, and migration. | Compile against the pinned Chromium tree on chromiumer and run native disposable-profile tests on Android and desktop. The payload remains incomplete under HS-008. |
| Cookie identity/authority (HS-002/HS-003) | CDP schema v2 preserves complete partition identity and explicit source-to-replica generations. Replicas cannot publish; device-bound policy yields reauthentication. Legacy records migrate only with an explicit source declaration. The local server atomically compare-and-swaps revisions so concurrent sources retry instead of losing an update. | Migrate device config, execute the fixture matrix against actual CDP versions, implement the Android native CookieManager path, and replace legacy CookieCloud encryption/backup storage under HS-011. |
| Independent tab snapshots (part of HS-004) | The Go snapshot store and `helium-tabs` command commit hashed generations by fsync+rename, validate bounded session models, plan hourly/daily/weekly retention, protect known-good/invalid copies, and restore only into a new disposable-state directory. | Export this model from Chromium session/tab APIs, schedule quiescent captures, load disposable profiles for a real browser drill, and implement local-session/foreign-session layers. No code promotes a snapshot into a real profile yet. |

These statuses describe source and synthetic tests only. They are not artifact
acceptance: no Chromium build or real profile was used for this work.

## Password Convergence

The append-only daemon remains a transport/store. HS-001 now persists
per-credential hashes and last-applied server sequences in the clients and
removes the export-before-pull startup race. Complete native credential merge
semantics remain HS-008.

The complete record design still needs:

- stable storage key derived with Chromium's password sync rules;
- schema version and complete `PasswordSpecificsData`-equivalent payload;
- content hash;
- source device and device-local mutation counter;
- server sequence and last-applied sequence per client; and
- explicit operation (`upsert` only initially).

Implemented startup ordering is reconcile-first:

1. Load durable last-applied metadata.
2. Pull the latest records and compare each record's server sequence with the
   durable per-credential sequence.
3. Validate and merge remote records through native password APIs.
4. Query the local store and publish only locally changed records.
5. Persist applied/published metadata atomically.

An unchanged device restart must emit zero credential updates. A local edit and
a remote edit of the same credential must be resolved using Chromium's native
password timestamps/merge semantics or surfaced as a conflict; wall-clock
arrival alone is insufficient.

The daemon token is separate from password encryption. Rotation uses token IDs,
current+next overlap for a bounded interval, atomic client config replacement,
explicit revocation, and a recovery token stored outside browser profiles.

## Cookies and Login Sessions

Cookie identity is at least:

```text
partitionKey(topLevelSite, hasCrossSiteAncestor) /
domain / path / name / sourceScheme / sourcePort
```

The former three-field key was invalid for partitioned cookies. Schema v2 keeps
the partition key, domain, path, name, source scheme, and source port in the
identity. Host-only versus
domain cookies, `Secure`, `HttpOnly`, `SameSite`, priority, expiry, source
scheme/port, and the complete partition key must survive validation and
round-trip.

Authentication cookies are not symmetric multi-writer data. The CDP bridge
configuration now assigns one source device per domain and zero or more replicas:

- only the source uploads for that domain;
- replicas apply newer generations but never upload them;
- a source-observed rotation supersedes the old generation;
- expired records are ignored, not re-created;
- a rejected replica token marks the replica as requiring reauthentication;
- a replica failure or local deletion never propagates to the source.

The current bridge encrypts one schema-v2 payload for CookieCloud transport.
Every write includes the revision returned by the preceding read; the local
server atomically rejects a stale or unconditional update with HTTP 409/428.
The daemon retries on its next bounded interval, so concurrent domain sources
cannot silently overwrite one another. Authenticated encryption and independent
cookie backup generations remain HS-011.

Device Bound Session Credentials cannot be made portable by copying their
short-lived cookie. They rely on a private key held by the original device and
Chrome may refresh the cookie by proving possession. Such sites must retain
per-device login or use a site-supported transfer/login flow. DBSC currently
does not support partitioned cookies, which is another reason to model the two
features independently.

Android may suspend the browser and its DevTools socket while the desktop
browser remains continuously reachable. The stable Android endpoint should be
a native CookieManager bridge; CDP remains a diagnostic path with bounded
retries and an explicit unavailable state.

## Durable Tabs: Four Independent Layers

Tabs are durable user data. No layer may have permission to erase all other
layers.

### 1. Chromium local session restore

Keep Chromium's own session service and restore-last-session preference. Do not
mark a previously unclean profile clean before Chromium decides whether crash
recovery is needed. Local session restore is the fastest recovery path, but its
small rolling set of `Session_*`/`Tabs_*` files is not a backup.

### 2. Cross-device foreign-session catalog

Use Chromium's session/tab models where practical. Each device owns a namespace
and publishes immutable generations of windows, tabs, navigation entries,
pinned/group state, and activity timestamps. Other devices show these as
foreign sessions and copy selected tabs into local state; they do not replace
the local window automatically.

Remote tab records are schema-checked, size/count bounded, URL-scheme filtered,
and parent-generation checked before publication. A malformed update is
quarantined while the previous good generation remains available.

### 3. Independent versioned snapshots

`internal/tabsnapshot` now writes snapshots to a store that is not the live
profile and is not the sync database. It accepts only a validated browser-API
JSON model and commits by temp-write, file sync, manifest/hash verification,
directory sync, and atomic rename. Capturing that model from a quiescent browser
is still an integration requirement.

The manifest contains device/profile ID, browser/Chromium version, capture
time, reason, parent generation, file hashes, sizes, and validation status.
Snapshots never share a deletion namespace across devices.

Initial retention policy:

- 24 hourly generations;
- 14 daily generations;
- 12 weekly generations; and
- two protected known-good restore-drill generations.

Retention runs only after the newest snapshot validates and never deletes the
last valid generation.

### 4. Restore validation and drills

Restore always targets a new disposable profile first. The drill verifies
manifest hashes, parses/loads the snapshot with a compatible browser, counts
windows/tabs, checks representative URLs/pinned/group state, restarts again,
and records the result. Promotion to the real profile is a separate atomic,
backed-up operation performed only while the browser is stopped.

Quarterly drills and every browser-major update must validate at least one
recent and one protected snapshot on every device class.

## Android Media and Streaming

Media and response streaming are separate test dimensions.

`ffmpeg_branding = "Chrome"` plus `proprietary_codecs = true` enables relevant
compiled codec support, but does not prove decoder availability, MSE behavior,
DRM/Widevine, or that the installed APK contains those args. Every APK manifest
must capture GN args and use deterministic media fixtures. `chrome://media-internals`
and Android logcat identify demuxer, decoder, and pipeline failures.

ChatGPT is a useful manual scenario but not a reproducible streaming test. The
automated fixture emits numbered chunks at one-second intervals over HTTP/1.1
chunked transfer, HTTP/2, HTTP/3, SSE, and a Fetch `ReadableStream`. The driver
records headers, first byte, each visible chunk, completion, protocol, content
encoding, and renderer/network errors. Test a clean upstream Chromium APK and a
patched Helium Sync APK built from the same Chromium commit; if only the latter
fails, bisect the ordered private patches.

## Store Durability

`records.jsonl` remains an append-only journal, but it is not the only copy.
The daemon must periodically create authenticated snapshot generations with
the last sequence, journal hash, record counts, and key/schema inventory.
Startup validates from newest to oldest, quarantines a damaged tail instead of
discarding earlier valid records, and never logs decrypted payloads. Backup and
restore tests use synthetic records only.

## References

- Chromium password manager architecture:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/components/password_manager/README.md>
- Chromium password specifics schema:
  <https://chromium.googlesource.com/chromium/src/+/main/components/sync/protocol/password_specifics.proto>
- Chromium synced sessions component:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/components/sync_sessions/>
- Chromium session restore source:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/chrome/browser/sessions/session_restore.h>
- DevTools cookie types and partition keys:
  <https://chromedevtools.github.io/devtools-protocol/tot/Network/#type-CookiePartitionKey>
- Device Bound Session Credentials:
  <https://developer.chrome.com/docs/web-platform/device-bound-session-credentials>
- OAuth token rotation guidance: <https://www.rfc-editor.org/rfc/rfc9700.html>
- Chromium media architecture:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/media/README.md>
