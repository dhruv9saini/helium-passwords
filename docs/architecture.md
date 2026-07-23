# Helium Sync Architecture

## Product boundary

Helium Sync has one native browser path. Chromium's password store is the
password authority and Chromium's `CookieManager` is the cookie authority.
There is no alternate password/cookie writer, CookieCloud bridge,
phone-local sync daemon, domain-policy replica model, or raw SQLite/profile
copy path in the product repository. Normal launch, installation, shutdown,
and CI composition tests fail if one is reintroduced. The Android media CDP
probe is read-only acceptance instrumentation and is outside sync composition.

Tabs are not sync data. The wire kinds are exactly `passwords` and `cookies`;
the server rejects every other kind. No endpoint, credential, or record schema
can carry a tab. Each device keeps its own Chromium session recovery and local
tab snapshot repository. A restore can target only a new disposable directory
and can never auto-open a tab.

## Trust and data flow

```text
d / da / oneplus browser
  Chromium PasswordStore + CookieManager
       |
       | plaintext exists only in this browser process
       v
  profile-local Helium bridge
  AES-256-GCM, metadata-bound ciphertext
       |
       | TLS 1.3 over Tailscale; per-device bearer credential
       v
  helium-syncd lm-tailnet-ip:44719
  offline-CA-signed, endpoint-constrained leaf
       |
       +-- /var/lib/helium-sync/devices.json
       |     device IDs, roles, scopes, revocation, credential hashes
       +-- /var/lib/helium-sync/records.jsonl
       |     kind/key/revision/device/key-id/nonce/ciphertext
       +-- /var/lib/helium-sync/snapshots/
             atomic opaque journal generations
```

lm terminates transport TLS and therefore sees device bearer credentials,
record identity metadata, and ciphertext. It has no E2EE content key and
cannot decrypt passwords or cookies. All enrolled browser profiles with a live
content key can decrypt the shared records. The TLS CA private key remains on
independently held offline media; lm receives only its endpoint leaf key. The
path-zero root has Android-compatible critical DNS-only name constraints for
lm's exact `.ts.net` name. The server-auth leaf and every issuance, install,
start, and live-health gate separately require lm's exact current Tailscale
IPv4 SAN and bind address. Keeping IP GeneralSubtrees out of the root avoids a
known Android BoringSSL rejection without weakening the exact leaf admission
gate. Every client explicitly enrolls the authenticated public root before
receiving a URL or bearer credential. d recovery uses an age-encrypted
generation containing d's complete validated client state and credential. One
generation is encrypted to at least two dedicated recovery identities and
copied to two off-d locations; no recipient identity is stored with the
ciphertext. None of this recovery material belongs in the server data
directory, its NAS backup, a repository, or chromiumer.

Certificate compatibility is independently proven without trusting or
deploying a test root. A temporary source-built DNS-constrained CA and exact
DNS/IP leaf served TLS 1.3 on an unused lm tailnet port; OnePlus's Android
BoringSSL curl accepted the explicit public root with verification result zero
and rejected a substituted root. The temporary listener, CA/private key, leaf
key, and phone public-certificate copy were removed after the probe. Permanent
tests reject the formerly emitted IP GeneralSubtree and any email, URI, or
unhandled critical constraint before a leaf can be issued or installed. This
is certificate-profile evidence, not production service deployment or client
root enrollment.

The browser reads exactly one enrollment directory:

```text
<profile>/Default/helium-sync/
  base_url
  token
  client.json
  password-state.json
  cookie-state.json
  cookie-rollback.json
  cookie-reauth-required.json
```

`base_url` must be HTTPS and must not contain user information. `token` and
`client.json` are per-profile secrets. The two bridge state files contain
fingerprints, revisions, and a global `verified_sequence`; they do not contain
plaintext password or cookie values. Cookie rollback plaintext is sealed with
a device-local key that is not shared through enrollment.

## Bounded record transport

Record reads use one mandatory versioned pagination protocol; there is no
unpaged compatibility path. An initial pull sends its durable `since` cursor,
an initial latest-inventory read omits `since`, and every request asks for 128
records. The server freezes its current journal sequence as `next_seq`, binds
an opaque continuation cursor to the operation and kind filters, scans only
that immutable range in ascending sequence order, and keeps the same
`next_seq` on every page. Writes arriving during the read are therefore left
for the next pull rather than leaking into the current snapshot.

The server accepts at most 256 requested records per page, emits at most 4 MiB
of encoded JSON, and rejects an opaque mutation larger than 1 MiB so every
accepted record can fit in a page. Go and Chromium clients request 128 records,
allow at most 512 pages, 65,536 aggregate records, 128 MiB aggregate encoded
responses, and 5 MiB for any one HTTP response. They require pagination
version 1, all response fields, one fixed snapshot cursor, globally increasing
record sequences within that snapshot, and a never-repeated continuation
cursor. All pages are validated and assembled before decryption reaches a
bridge callback; browser application and durable acknowledgement therefore
cannot occur after only a prefix of the snapshot.

The rootless synthetic lm service runs this protocol through direct TLS. Its
deployed regression crosses the page boundary, verifies ordered unique
records at one snapshot, rejects a retiring content epoch, rejects a stale
join promotion before accepting the current cursor, tombstones every fixture,
revokes the fixture client, and finishes with a checksum-verified NAS restore.
This is service/protocol evidence. The same native client still requires a
Chromium compile and disposable browser execution before personal enrollment.

## Enrollment and authorization

d is the only seed. `helium-sync seed-init` creates d's content/signing state
and bearer credential on d, plus a bootstrap document containing only the
active key ID and credential hash. lm initializes its opaque registry from that
document.

A join is explicit:

1. On da or oneplus, `join-request` creates a device-local X25519 private key,
   a public request, a new bearer credential, and a separate hash-only server
   authorization request.
2. d verifies the device ID and wraps the current content-key bundle to that
   public key, then signs the envelope with d's Ed25519 seed identity.
3. lm's supervised operator stops the daemon, registers only the device ID and
   credential hash with `pull` scope, validates the complete registry, restarts
   the daemon, and waits for direct-TLS health. Offline registry commands are
   never run against the active daemon because it keeps a validated in-memory
   registry.
4. The joining device authenticates d's signature, unwraps locally, and writes
   `client.json` in `pending` phase.
5. The native password and cookie bridges pull, validate, apply, read back, and
   persist the same global verified cursor. Pending bridges baseline unrelated
   local data and cannot publish.
6. The native profile coordinator accepts readiness only after both bridges
   have durably acknowledged the same global cursor. It then completes that
   exact server cursor once and requires both bridge clients to reload the
   activated state before either resumes. A missing password store, failed
   readback, cursor mismatch, stale server cursor, or reload failure leaves the
   flow fail-closed. The offline `enrollment-complete` command performs the
   same schema/cursor gate with a stopped profile for recovery and diagnosis.
7. An unchanged active restart emits no records.

The synthetic-only protocol client follows the same global-cursor boundary by
requesting the unfiltered password-and-cookie inventory and verifying the
complete expected set before acknowledgement. Kind-filtered fixture admission
is forbidden: page filters affect returned records but not the global snapshot
cursor, so acknowledging a cookie-only response could otherwise advance past
an unseen password record. Its schema-2 receipt binds every hashed key to its
record kind. This is fixture protocol evidence and never substitutes for the
native two-bridge readback gate.

Credentials are per-device, hash-verified, scoped, independently rotatable with
an overlap/confirm/retire sequence, and revocable. d cannot be revoked because
it is the sole recovery authority; loss of d must be handled from separately
proven recovery material, not by giving lm a content key.

Content-key rotation is staged. d creates and distributes a signed encrypted
keyring update, every active device acknowledges installation, d activates the
new epoch, latest records and tombstones are CAS-re-encrypted, every device
acknowledges the verified rekey cursor, and only then can d retire the old key.
Before the CAS pass, `key-rekey` imports password and cookie revisions from
their native bridge state only when both schema versions and verified cursors
equal d's `client.json`; it cannot infer readiness from server ciphertext.
After the stopped-browser client-state cutover, the native cookie bridge accepts
a higher CAS revision under the new active epoch and updates its established
epoch after verified apply. A same-revision epoch substitution, a higher
revision still using the retiring epoch, or an epoch absent from the local
keyring fails closed. This distinction permits the planned re-encryption pass
without treating an arbitrary key change as authoritative.

## Password convergence

Startup always requests the latest remote password inventory before installing
a store observer. Remote writes use Chromium's complete serialized
`PasswordSpecificsData`, are applied through `PasswordStoreInterface`, and
are read back before the cursor advances. Joiners baseline local-only entries
while pending rather than bulk-publishing them. Active local changes use
expected revisions; a stale mutation receives a conflict. If both the verified
local baseline and remote revision changed, the bridge preserves local state,
leaves the cursor unchanged, and stops that batch for explicit resolution.
Tombstones are retained in latest inventory so a new or stale client cannot
resurrect a deletion.

Password identity is schema 2 and exactly follows Chromium's pinned login-table
unique key: origin URL, username element, username value, password element, and
signon realm. Each field is length-framed, UTF-16 fields retain their code units,
and the SHA-256 key uses the `credential/v2/` namespace. State schema 4 preserves
every schema-3 entry under `legacy_credentials`. A live legacy entry migrates
only when exactly one current `PasswordForm` has its old key and fingerprint;
two forms that collided under the old realm/URL/username tuple fail closed
instead of collapsing. Canonical publication starts at revision zero while the
legacy metadata remains preserved for audit.

Observer events write only fingerprints and deletion intent into atomic state.
Exactly one mutation receives an expected revision and durable
`pending_publication` record before one HTTP push; later rapid events remain a
separate `queued_mutation`. A push response never advances state directly.
Every success, failure, malformed response, or restart resolves the pending
intent against a new authenticated latest-record pull. An exact target revision
is accepted, an unchanged baseline is retried, and any other remote revision
fails as a real conflict. Enrollment completion and content-key rekey refuse
legacy, queued, or pending password state.

The TLS-backed synthetic three-device integration test exercises one complete
password lifecycle with d, da, and oneplus identities: both joins remain
pull-only through verified application, an unchanged restart performs no HTTP
publication, da updates and deletes the fixture while stale oneplus writes are
rejected, revoking da leaves oneplus usable, oneplus rotates its credential,
and d rotates and retires the shared content epoch only after oneplus verifies
the CAS-rekeyed tombstone. It also proves that fixture plaintext never reaches
the server journal. This is protocol and service proof; native prompts,
settings, suggestions, and autofill still require the returned browser
artifact and disposable profiles.

The same flow has also run through lm's supervised synthetic TLS endpoint with
the seed hosted on da and an isolated CLI on the real oneplus Android shell.
It proved seed create/tombstone, stale create/resurrection rejection, identical
no-op restart reads with an unchanged journal, pending pull-only joins, exact
per-device revocation isolation, TLS root enforcement, and a post-mutation NAS
backup/restore drill. The phone run additionally exposed and verified the
Android enrollment file-publish requirement: Android uses atomic
`renameat2(RENAME_NOREPLACE)` because its shell SELinux domain rejects hard
links in `/data/local/tmp`. This is transport/protocol/CLI evidence, not native
password UI evidence.

The remaining native UI gate now has a public browser-generic protocol and a
private Sync extension. The public gate creates or admits only a disposable
Linux profile or metadata-proven Android `.test` package and binds an ordered
loopback fixture to visually inspected native UI screenshots. The private
extension binds its secret-free bridge state and opaque-journal metadata to
those exact screenshot hashes. It requires one save revision, one changed
update revision, the next tombstone revision, and byte-identical state and
journal hashes across unchanged restarts. Neither layer contains a
password-store writer, extension, `chrome.passwordsPrivate`, or raw database
reader. Both are source-tested and ready when an artifact exists; no runtime
receipt exists yet.

## Cookie and login-session convergence

Every live, structurally valid, non-expired cookie returned by
`CookieManager::GetAllCookies` participates by default. There is no guessed
authentication-cookie list and no default domain allowlist. Identity is a
length-framed hash over name, path, exact host/domain form, source scheme,
source port, and the complete partition key including top-level site and
cross-site-ancestor bit. Payloads preserve session/no-expiry state, Secure,
HttpOnly, SameSite, priority, source type, timestamps, and partitioning.

Before any remote apply, the bridge builds a complete target preview, seals the
destination snapshot with the device-local key, writes a pending rollback
journal, applies through `SetCanonicalCookie`/`DeleteCanonicalCookie`, reads
the complete cookie store back, and commits only on an exact validated match.
A rejection restores the saved destination state. Expected revisions,
authenticated source device IDs, durable pending-publication state, and
fingerprints stop token-rotation ping-pong and stale overwrites.
During pending pull-only enrollment, a remote cookie with the same canonical
identity as a different joiner-local cookie is the seed-authoritative value:
it follows the same sealed preview/apply/readback/rollback transaction instead
of blocking enrollment. Active devices retain the stricter concurrent-change
stop. Joiner-only cookies are recorded as local baselines and are not bulk
published after promotion. Publications are deterministic batches of at most
32 cookie records, and the native HTTP client refuses a serialized request
above 4 MiB before network I/O; this keeps the matching encrypted response
below its 5 MiB per-response ceiling.

Destination exceptions are exact and temporary. The record-state map scopes
one exception to the canonical cookie record key, rejected remote revision,
and authenticated payload fingerprint. The DBSC manager exposes schemeful-site
and session-ID keys but no authoritative cookie-to-session mapping, so its
inventory is recorded only as same-site evidence in the local reauthentication
signal; it never marks every cookie on a site non-clonable and never enters the
synced cookie payload. After verified rollback, the rejected revision is not
retried unchanged. A later active-epoch remote revision is eligible for a new
transaction. A local cookie change alone is not proof that a password login
succeeded: while the exception remains, the bridge records that change as
unverified, holds it locally, and excludes it from publication. This prevents a
background token rotation from becoming a cross-device ping-pong loop.
Verified destination readback of a later authoritative revision clears the old
exception. A future browser flow may clear it only after exact-origin,
user-visible native password reauthentication is independently verified. This
is source/model behavior, not evidence that a destination authenticated
successfully.

Cookie bridge state schemas 2 and 3 migrate to schema 4 on first load. The
bridge first writes an atomic mode-0600 `schema-v2.bak` or `schema-v3.bak` copy
of the pre-migration document, then atomically rewrites the active state. The
rewrite keeps authority revisions, payload and local fingerprints, deletion
state, and pending CAS publications. The old site-wide `non_clonable` marker,
reason, and site are deliberately not carried forward from schema 2. Schema 3
exceptions retain their exact record/revision/payload scope but rename `site`
to `schemeful_site` and start with no observed unverified local change.

The build-independent disposable model exercises the same identity dimensions,
exact set/delete preview, successful target verification, and a partial apply
followed by verified rollback. That is executable synthetic proof, not
browser-runtime proof: the C++ bridge still needs the bounded chromiumer
compile and a new disposable-profile run before deployment.

The same protocol has run through lm's supervised synthetic TLS endpoint using
the real da host and oneplus Arch chroot. Four fixture records proved distinct
host/domain and two partition-key identities, pending pull-only authorization,
E2EE readback on both architectures, authenticated source metadata, two token
rotations, stale-CAS rejection, zero-publication restarts, tombstone
convergence, resurrection rejection, revoked-credential rejection, and an
opaque journal with no fixture plaintext. A synthetic-only reconciler requests
the complete unfiltered password-and-cookie inventory and advances the applied
cursor only after exact kind, metadata, and payload-hash verification. It
requires an explicit private `synthetic-only-v1` marker. All test clients were
revoked, all live fixture cookies were tombstoned, remote temporary credentials
were removed, and the post-test NAS restore drill passed. This is still not
CookieManager or authenticated-site portability evidence.

Chromium device-bound sessions are observed through its device-bound-session
manager. Only an actual exact-cookie destination rejection creates a
revision-scoped local exception and fail-closed reauthentication intent;
observed same-site session keys are supporting evidence, not a portability or
authentication claim. The cookie supplies a schemeful site, not a verified
exact origin or login entry, and Chromium's password manager operates on a
concrete tab and discovered form. The intent therefore forbids guessed
navigation and automatic submission until disposable evidence supplies those
missing inputs. The metadata-only origin-state audit binds controlled
cookie/auth/DBSC outcomes and storage requirements to an exact target and
synthetic or disposable artifact hash, rejects secret-bearing fields, and
prevents synthetic evidence from creating a concrete portability claim. Its
schema-2 transfer contract requires separate preview, apply, readback, and
rollback results, but its source-registered adapter set is empty. It does not
collect or transfer localStorage, IndexedDB, service-worker storage, Cache
Storage, or other per-origin state. Those stores require site-specific
disposable-profile evidence and an origin-scoped adapter; arbitrary
application databases will never be live-merged.

## Device-local durable tabs

The browser tab bridge exports a bounded neutral snapshot outside the profile
using create-new, fsync, and atomic rename. It refreshes the file every five
minutes even when content is unchanged. A source-local adapter rejects exports
older than a bounded margin, with unsafe permissions or ownership, through a
symlink, or replaced during capture; a stopped browser therefore cannot turn a
stale file into a healthy generation. `helium-tabs` validates checksums,
commits immutable generations, explicitly quarantines corruption without
deletion, applies 24-hourly/14-daily/12-weekly retention without deleting the
last known-good copy, and restores only to a nonexistent disposable state
directory. A separate consumer converts a validated neutral restore into a
new `drill-*` browser profile only under an explicitly marked private
disposable root. It retains the neutral receipt, writes current URLs as
Chromium startup URLs, validates staging, and atomically publishes without
launching a browser, mutating clean-exit state, or accepting an existing
profile.

The operations design assigns every source device its own hostname-bound
scheduler and device-specific age key namespace. One validated generation is
encrypted to at least two distinct recovery recipients and copied to exactly
two off-source hosts with
incoming-file verification and atomic promotion. The enforced topology is lm's
separately mounted NAS plus da for d and oneplus, and lm's NAS plus d for da.
A durable health proof binds the current generation, configuration, key
namespace, topology, and both verified remote hashes. A fleet audit rejects
recipient reuse across device configs. Repositories are namespaced by source
device and profile and are never opened or merged on a different device. Local
Chromium recovery and local generations are extra layers, not either
off-device copy. Recovery identities stay outside all source and destination
stores except while explicitly attached for a disposable restore drill.

The independent store, stale-export boundary, fixed topology, pinned dedicated
SSH transport, encryption/copy logic, health proof, retention, quarantine,
neutral restore, and atomic disposable current-URL browser consumer are
implemented and synthetic-tested. The native tab producer is source-complete
but not yet compile/runtime validated. Full window, pin, group, navigation
history, and unloaded-tab reconstruction plus first/second browser-start proof
remain open. da currently has only a disabled user timer; oneplus has only
source tools and a disabled runner template. No source can be enabled until its
fresh browser export, two offline public recovery recipients, and both exact
destination routes pass preflight.

## Runtime and build boundaries

lm is the control plane and hosts only the opaque service. `helium-syncd`
terminates TLS 1.3 directly and binds the exact Tailscale IPv4 address on the
unprivileged port 44719; it never listens on a wildcard, LAN/public address, or
cleartext non-loopback socket. Tailscale access control still limits network
reachability. Tailscale Serve and Funnel remain empty, so endpoint activation
does not require the tailnet HTTPS feature, publish lm's name to Certificate
Transparency, give the service access to the Tailscale LocalAPI, or grant a
low-port capability.

The service unit is `helium-syncd.service`, runs as the dedicated
`helium-sync` account, and is hardened by systemd. A start-time verifier
requires the exact offline root, leaf signature, key match, SANs, purpose,
live Tailscale identity, and 30-day lifetime floor. The cgroup denies every IP
outside `100.64.0.0/10`, capabilities, writable system/home paths, host process
visibility, and device access; only `/var/lib/helium-sync` is writable. The
versioned TLS identity under `/etc/helium-sync/tls` is read-only to the service
and excluded from opaque server backups. lm's leaf key can authenticate lm and
decrypt the outer TLS channel, but it cannot issue another endpoint certificate
or decrypt an E2EE record.

lm also has a deliberately separate `helium-syncd-disposable.service` for
synthetic testing while root authorization is unavailable. It is a lingering
user service with a mandatory `SYNTHETIC_ONLY` marker, direct TLS, the same
tailnet-only BPF rule, no capabilities, strict system and process isolation,
and `ProtectHome=tmpfs`; only its executable directory, endpoint/TLS state,
and one writable opaque server directory are bound into the mount namespace.
Its independent user timer stops the service, writes an opaque generation to
`/srv/nas/helium-sync-server-disposable`, and restarts it. Activation always
performs a fresh disposable restore drill and waits for the TLS listener.
`scripts/install-lm-disposable-sync-service.sh disable` is the complete
rollback command and preserves every generation.

This rootless service may never receive personal device credentials or browser
content. Other processes running as user d remain able to read d-owned state,
which user-service sandboxing cannot change; the dedicated `helium-sync`
system account and root-owned TLS/state paths remain mandatory before personal
rollout. Disable the disposable unit before activating the production unit so
only one process can own port 44719.

Every Chromium compile runs on chromiumer through
`scripts/chromiumer-job.sh` and the pinned Nix environment. The wrapper
enforces two build jobs, CPU/memory/I/O/task/disk limits, an eight-hour stop,
watchdog, detached journald logs, one cancel command, provenance/artifact
receipts, and exactly-once completion notification to
`dhruv.codex@gmail.com`. lm and the NAS are never compiler workspaces.

Android source acquisition is also shared rather than privately reimplemented.
`scripts/chromium/prepare-android-source.sh` owns the one pinned
`gclient sync --revision src@<locked SHA> --nohooks --no-history` request and
the exact Chromium `HEAD` postcondition. The private Android runner begins its
own work only after that boundary: pinned hooks, the public/core and private
patch series, GN, compilation, and packaging. Static and synthetic tests prove
that there is no moving-main sync, manual checkout, or second repair sync; a
fresh chromiumer source preparation and compile remain required runtime
evidence.

## Verified source versus remaining gates

| Area | Implemented and source-tested | Still required before personal data |
| --- | --- | --- |
| Transport | Opaque v2 E2EE, direct TLS 1.3 server, Android-compatible DNS-constrained offline CA issuance/verification, exact DNS/IP leaf admission, OnePlus BoringSSL chain/wrong-root proof, authenticated device identity, scopes, CAS revisions, int64 string counters, tombstones, journal recovery; synthetic rootless endpoint and scheduled NAS restore proof live on lm | Replace the pre-fix synthetic root/leaf, restore root authorization, install the dedicated-account service, and enroll the new public root on disposable browser clients |
| Enrollment | d-only seed, signed X25519 join wrapping, pending pull-only phase, dual bridge cursor gate, revocation and rotations; consolidated TLS-backed three-device protocol lifecycle passes | Execute native bridge promotion on disposable profiles, then provision personal d/da/oneplus only after backups |
| Passwords | Pull/apply/readback before observe/publish; full native specifics; complete `PasswordForm` unique-key identity; schema-3 preservation/collision stop; durable one-at-a-time publication and pull-verified ambiguous outcomes; artifact-bound native fixture/capture/receipt gate | Compile the bridge, then run the gate on returned browser artifacts for prompts, save/update/generation/settings/suggestions/autofill/delete, rapid observer events, ambiguous-success restarts, and three-device stale conflicts |
| Cookies | Whole-profile canonical identity, E2EE, active-epoch CAS rekey, authoritative pull-only join replacement under sealed rollback, bounded publication batches, preview/apply/readback/rollback, exact revision-scoped rejection evidence, unchanged-revision suppression, and unverified-local-rotation hold | Compile the bridge; prove colliding join replacement, multi-batch publication, destination rejection/readback/rollback, later-revision retry, DBSC evidence scope, and authenticated-site behavior in disposable browsers; collect exact origin/login-entry evidence before adding a native password reauth flow |
| Origin state | Strict metadata-only, artifact-bound synthetic/disposable classifier; explicit preview/apply/readback/rollback contract; empty source-registered adapter set; no state values accepted | Disposable-browser evidence collector and one reviewed exact-origin adapter only where observed necessary |
| Tabs | Local exporter/store, atomic checked generations, standalone content-bound restores from both destinations, atomic marked-root current-URL browser consumer, exact peer roots, fleet recipient non-overlap, two-destination encrypted operations, corruption/retention/restore tests | Compile exporter; authorize da's dedicated key on d; provision independent non-reused recovery recipients; enable schedules only after two-route preflight; implement full tab topology reconstruction and prove first/second disposable browser starts on every device |
| Media/streaming | Reproducible fixtures, strict codec GN provenance, separate no-patch upstream-control builder, progressive Fetch/SSE and Service Worker relay gates, explicit codec-versus-Widevine evidence, artifact-carried fail-closed device orchestration, source/fixture/media-bound A/B pair receipts, and live rootless tailnet-only H2/H3 origins with exact private-leaf SPKI admission | Resolve da's direct-HTTP/3 return/client failure, then run same-source control/Sync APK A/B on oneplus for negotiated protocols, lifecycle, video/audio, and content-free ChatGPT timing; CDM provisioning remains separate |
| Android source/build | Exact Chromium `150.0.7871.181`/Helium `0.14.8` lock; shared one-request immutable source helper; exact-HEAD, depot pin, cache-disable, monotonic version, and private single-entry contracts | Fresh isolated chromiumer source preparation, 312 selected patches (301 core + 2 Passwords + 9 Sync), GN generation, focused compile, then APK |
| Deployment | Executable d recovery export/import, credential cutover, direct-TLS generation install/start gates, source unit/install gate, rollback-preserving installers, and fixed-topology full-profile backup streaming to one NAS plus one authenticated peer without plaintext or local ciphertext staging | Create off-device recovery identities/copies and offline TLS CA, enroll its public root, prove live tailnet TLS, authorize the d SSH routes, build artifacts, run real two-copy profile backup/restore drills, then enroll sequentially |

No personal profile, credential, cookie, or tab content is read by source tests.
