# Helium Passwords Architecture

## Product boundary

Helium Passwords has one native password path. Chromium's password store is
the password authority. Chromium's `CookieManager` is used only for guarded
cookie backup and restore.
There is no alternate password/cookie writer, CookieCloud bridge,
phone-local sync daemon, domain-policy replica model, or raw SQLite/profile
copy path in the product repository. Normal launch, installation, shutdown,
and CI composition tests fail if one is reintroduced. The Android media CDP
probe is read-only acceptance instrumentation and is outside sync composition.

Cookies and tabs are not sync data. The server accepts and returns only
`passwords`. No endpoint, credential, or record schema can carry cookies or
tabs. Each device keeps its own Chromium session recovery and local
tab snapshot repository. The neutral snapshot preserves bounded local
window/tab/group/navigation topology, but preparation writes no startup URLs
and can target only a new, explicitly marked disposable directory. No sync
record, backup copy, normal launch, or preparation command can auto-open a tab.
Three independently recoverable mechanisms protect tabs: Chromium's native
session recovery, neutral topology generations, and stopped compressed
full-profile generations. Replicated copies do not increase that count. The
three paths have separate producers, formats, schedules, retention and restore
tools; [tab-recovery-defense.md](tab-recovery-defense.md) defines the exact
boundaries and current runtime gates.

Helium has no assistant or messaging data path. The retired OpenBubbles,
assistant activation-payload, Mailbridge, work-queue, email, and personal-relay
integrations may not be reintroduced. The build monitor polls Chromiumer and
records a mode-private terminal result locally on da; it does not dispatch
work or contact an account. Browser enrollment activation below is only a
profile-local Sync authorization transition and never produces an assistant
payload.

## Trust and data flow

```text
d / da / oneplus browser
  Chromium PasswordStore
       |
       | readable JSON record payload
       v
  profile-local Helium bridge
       |
       | HTTP over private Tailscale; per-device bearer credential
       v
  helium-syncd lm-tailnet-ip:44719
       |
       +-- /var/lib/helium-sync/devices.json
       |     device IDs, roles, scopes, revocation, credential hashes
       +-- /var/lib/helium-sync/records.jsonl
       |     password-key/revision/device/payload
       +-- /var/lib/helium-sync/snapshots/
             atomic readable journal generations
```

The Tailnet is the confidentiality boundary. Tailscale authenticates peers and
encrypts transport, so lm intentionally sees record identity metadata and
readable password payloads. Do not add a second content-encryption
protocol, encrypted recovery wrappers, or an inner TLS CA. The daemon binds
only lm's literal Tailscale IPv4 address, accepts hashed per-device bearer
credentials, and must not be exposed with Tailscale Serve or Funnel. Private
filesystem modes, checksums, atomic publication, SSH for backup transport, and
source/destination topology checks provide the remaining operational boundary.

The browser reads exactly one enrollment directory:

```text
<profile>/Default/helium-sync/
  base_url
  token
  client.json
  native_recovery_root
  tab_snapshot_export_path
  password-state.json
```

`base_url` must be exact HTTP on loopback or a literal Tailscale IPv4 address
on port 44719 and must not contain user information. `token` and
`client.json` are per-profile secrets. The password state file contains
fingerprints, revisions, and a global `verified_sequence`; it does not contain
password payloads.
`native_recovery_root` points outside the profile at one marked private
directory where Chromium atomically publishes the independent
PasswordStore/CookieManager neutral snapshots described in
[`nine-path-recovery.md`](nine-path-recovery.md).
`tab_snapshot_export_path` points outside the profile at the independently
scheduled neutral tab export.

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
of encoded JSON, and rejects a mutation larger than 1 MiB so every
accepted record can fit in a page. Go and Chromium clients request 128 records,
allow at most 512 pages, 65,536 aggregate records, 128 MiB aggregate encoded
responses, and 5 MiB for any one HTTP response. They require pagination
version 1, all response fields, one fixed snapshot cursor, globally increasing
record sequences within that snapshot, and a never-repeated continuation
cursor. All pages are validated and assembled before reaching a bridge
callback; browser application and durable acknowledgement therefore
cannot occur after only a prefix of the snapshot.

The rootless synthetic lm service runs this protocol through private-Tailnet HTTP. Its
deployed regression crosses the page boundary, verifies ordered unique
records at one snapshot, rejects a stale join promotion before accepting the
current cursor, tombstones every fixture,
revokes the fixture client, and finishes with a checksum-verified NAS restore.
This is service/protocol evidence. The same native client still requires a
Chromium compile and disposable browser execution before personal enrollment.

## Enrollment and authorization

d is the only seed. `helium-sync seed-init` creates d's device identity and
bearer credential locally, plus a bootstrap document containing only the
device ID, role, scopes, and credential hash. lm initializes its registry from
that hash-only document.

A join is explicit:

1. On da or oneplus, `join-init` creates a pending pull-only client with a new
   local bearer credential and a separate hash-only server authorization
   document.
2. lm's supervised operator stops the daemon, registers only the device ID and
   credential hash with `pull` scope, validates the complete registry, restarts
   the daemon, and waits for private-Tailnet HTTP health. Offline registry commands are
   never run against the active daemon because it keeps a validated in-memory
   registry.
3. The native password bridge pulls, validates, applies, reads back, and
   persists the verified cursor. Pending clients baseline unrelated local data
   and cannot publish.
4. The native profile coordinator accepts readiness only after the password
   bridge durably acknowledges that cursor. It completes the exact server
   cursor once and requires the bridge to reload activated state before it
   resumes. A missing password store, failed readback, stale server cursor, or
   reload failure leaves the flow fail-closed. The offline `enrollment-complete` command performs the
   same schema/cursor gate with a stopped profile for recovery and diagnosis.
5. An unchanged active restart emits no records.

The synthetic-only protocol client follows the same global-cursor boundary by
requesting the complete password inventory and verifying the expected set
before acknowledgement. A cookie filter is rejected. Its schema-2 receipt
binds every hashed password key to its record kind. This protocol evidence
never substitutes for native PasswordStore readback.

Credentials are per-device, hash-verified, scoped, independently rotatable
with an overlap/confirm/retire sequence, and revocable. Tokens exist only in
their client enrollment directories; lm and server backups contain only
hashes.

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

Password identity schema 2 exactly follows Chromium's pinned login-table
unique key: origin URL, username element, username value, password element, and
signon realm. Each field is length-framed, UTF-16 fields retain their code units,
and the SHA-256 key uses the `credential/v2/` namespace. State schema 6 accepts
only this canonical identity and intentionally has no legacy credential map or
migration path.

Observer events write only fingerprints and deletion intent into atomic state.
Exactly one mutation receives an expected revision and durable
`pending_publication` record before one HTTP push; later rapid events remain a
separate `queued_mutation`. A push response never advances state directly.
Every success, failure, malformed response, or restart resolves the pending
intent against a new authenticated latest-record pull. An exact target revision
is accepted, an unchanged baseline is retried, and any other remote revision
fails as a real conflict. Enrollment completion refuses queued or pending
password state.

The private-Tailnet synthetic three-device integration test exercises one complete
password lifecycle with d, da, and oneplus identities: both joins remain
pull-only through verified application, an unchanged restart performs no HTTP
publication, da updates and deletes the fixture while stale oneplus writes are
rejected, revoking da leaves oneplus usable, and oneplus rotates its
credential. It also proves that the server journal retains the expected
readable synthetic payload. This is protocol and service proof; native prompts,
settings, suggestions, and autofill still require the returned browser
artifact and disposable profiles.

The same flow has also run through lm's supervised synthetic Tailnet endpoint with
the seed hosted on da and an isolated CLI on the real oneplus Android shell.
It proved seed create/tombstone, stale create/resurrection rejection, identical
no-op restart reads with an unchanged journal, pending pull-only joins, exact
per-device revocation isolation and a post-mutation NAS
backup/restore drill. The phone run additionally exposed and verified the
Android enrollment file-publish requirement: Android uses atomic
`renameat2(RENAME_NOREPLACE)` because its shell SELinux domain rejects hard
links in `/data/local/tmp`. This is transport/protocol/CLI evidence, not native
password UI evidence.

The remaining native UI gate now has a public browser-generic protocol and a
private Sync extension. The public gate creates or admits only a disposable
Linux profile or metadata-proven Android `.test` package and binds an ordered
loopback fixture to visually inspected native UI screenshots. The private
extension binds its secret-free bridge state and journal metadata to
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

Before any remote apply, the bridge builds a complete target preview, writes
the readable destination snapshot to a private pending rollback
journal, applies through `SetCanonicalCookie`/`DeleteCanonicalCookie`, reads
the complete cookie store back, and commits only on an exact validated match.
A rejection restores the saved destination state. Expected revisions,
authenticated source device IDs, durable pending-publication state, and
fingerprints stop token-rotation ping-pong and stale overwrites.
During pending pull-only enrollment, a remote cookie with the same canonical
identity as a different joiner-local cookie is the seed-authoritative value:
it follows the same preview/apply/readback/rollback transaction instead
of blocking enrollment. Active devices retain the stricter concurrent-change
stop. Joiner-only cookies are recorded as local baselines and are not bulk
published after promotion. Publications are deterministic batches of at most
32 cookie records, and the native HTTP client refuses a serialized request
above 4 MiB before network I/O; this keeps the matching response
below its 5 MiB per-response ceiling.

Destination exceptions are exact and temporary. The record-state map scopes
one exception to the canonical cookie record key, rejected remote revision,
and authenticated payload fingerprint. The DBSC manager exposes schemeful-site
and session-ID keys but no authoritative cookie-to-session mapping, so its
inventory is recorded only as same-site evidence in the local reauthentication
signal; it never marks every cookie on a site non-clonable and never enters the
synced cookie payload. After verified rollback, the rejected revision is not
retried unchanged. A later remote revision is eligible for a new
transaction. A local cookie change alone is not proof that a password login
succeeded: while the exception remains, the bridge records that change as
unverified, holds it locally, and excludes it from publication. This prevents a
background token rotation from becoming a cross-device ping-pong loop.
Verified destination readback of a later authoritative revision clears the old
exception. A future browser flow may clear it only after exact-origin,
user-visible native password reauthentication is independently verified. This
is source/model behavior, not evidence that a destination authenticated
successfully.

Cookie bridge state schema 5 is the single accepted schema. It keeps authority
revisions, payload and local fingerprints, deletion state, pending CAS
publications, and exact record/revision/payload-scoped destination exceptions.
There is no legacy state fallback or content-key metadata.

The build-independent disposable model exercises the same identity dimensions,
exact set/delete preview, successful target verification, and a partial apply
followed by verified rollback. That is executable synthetic proof, not
browser-runtime proof: the C++ bridge still needs the bounded chromiumer
compile and a new disposable-profile run before deployment.

The same protocol has run through lm's supervised synthetic Tailnet endpoint using
the real da host and oneplus Arch chroot. Four fixture records proved distinct
host/domain and two partition-key identities, pending pull-only authorization,
readable readback on both architectures, authenticated source metadata, two token
rotations, stale-CAS rejection, zero-publication restarts, tombstone
convergence, resurrection rejection, revoked-credential rejection, and a
readable journal containing the synthetic fixtures. A synthetic-only reconciler requests
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
disposable root. It retains the neutral receipt and complete topology,
validates staging, and atomically publishes without launch, startup URLs,
clean-exit mutation, or an existing-profile target. Only the explicit
disposable command-line importer reconstructs windows, bounded history,
pinned tabs, groups, visual state, and active tabs, then records exact live
readback.

The operations design assigns every source device its own hostname-bound
scheduler. One validated generation is packaged as a checksum-bound archive
and copied to exactly two off-source hosts with
incoming-file verification and atomic promotion. The enforced topology is lm's
separately mounted NAS plus da for d and oneplus, and lm's NAS plus d for da.
A durable health proof binds the current generation, configuration, topology,
and both verified remote hashes. A fleet audit enforces the three fixed
topologies. Repositories are namespaced by source device and profile and are
never opened or merged on a different device. Local Chromium recovery and
local generations are extra layers, not either off-device copy.

The three mechanisms have distinct source formats and restore tools. Neutral
and full-profile operations are implemented and synthetic-tested with fixed
topology, pinned SSH, authenticated archives, hash/size checks, independent
retention, and disposable restore.
The native neutral exporter/importer remains compile/runtime unvalidated. d
and da have checked-in disabled neutral-snapshot user timers; OnePlus still
needs its tested device-local neutral schedule. No source can be enabled until
fresh exports, exact destination routes, and all three disposable drills pass.

## Runtime and build boundaries

da owns Helium source and orchestration; lm is a deployment endpoint and hosts
the readable service. `helium-syncd` binds
the exact Tailscale IPv4 address on the unprivileged port 44719 over HTTP; it
never listens on a wildcard, LAN/public address, or non-Tailnet non-loopback
socket. Tailscale access control still limits network
reachability. Helium has no public Funnel and port 44719 is absent from every
Tailscale Serve listener, Web proxy target, and TCP forward target after
numeric port parsing, so spellings such as `044719` cannot publish the service.
Malformed targets fail closed. Unrelated tailnet-only Serve routes
may coexist; Helium verifies but never resets or rewrites them. Disposable
acceptance captures their canonical configuration before and after the run and
admits only byte-identical hashes. The verifier recursively traverses optional
`Foreground` and `Services` trees, requiring each present container and every
descended config to be a non-null object.

The service unit is `helium-syncd.service`, runs as the dedicated
`helium-sync` account, and is hardened by systemd. Its start-time verifier
requires the exact live Tailscale IPv4 endpoint, no public Funnel, and no
Serve listener, Web proxy target, or TCP forward target whose parsed numeric
port is 44719.
The cgroup denies every IP outside `100.64.0.0/10`, capabilities, writable
system/home paths, host process visibility, and device access; only
`/var/lib/helium-sync` is writable.

lm also has a deliberately separate `helium-syncd-disposable.service` for
synthetic testing while production remains inactive. It is a lingering user
service with a mandatory `SYNTHETIC_ONLY` marker, private-Tailnet HTTP, the same
tailnet-only BPF rule, no capabilities, strict system and process isolation,
and `ProtectHome=tmpfs`; only its executable directory, endpoint state, and
one writable readable server directory are bound into the mount namespace.
Its independent user timer stops the service, writes a private generation to
`/srv/nas/helium-sync-server-disposable`, and restarts it. Activation always
performs a fresh disposable restore drill and waits for the Tailnet listener.
`scripts/install-lm-disposable-sync-service.sh disable` is the complete
rollback command and preserves every generation.

This rootless service may never receive personal device credentials or browser
content. Other processes running as user d remain able to read d-owned state,
which user-service sandboxing cannot change; the dedicated `helium-sync`
system account and root-owned state paths remain mandatory before personal
rollout. Disable the disposable unit before activating the production unit so
only one process can own port 44719.

Every Chromium compile runs on chromiumer through
`scripts/chromiumer-job.sh` and the pinned Nix environment. The wrapper
enforces two build jobs, CPU/memory/I/O/task/disk limits, an eight-hour stop,
watchdog, detached journald logs, one cancel command, provenance/artifact
receipts, and an exactly-once local terminal record on da. The monitor has no
assistant endpoint, activation payload, delivery adapter, account recipient,
or personal relay. lm and the NAS are never compiler workspaces.

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
| Transport | Readable schema-2 records, exact private-Tailnet HTTP endpoint, hashed bearer authentication, scopes, CAS revisions, int64 string counters, tombstones, and journal recovery | Redeploy and rerun the live synthetic service proof; keep production inactive until its dedicated-account restore drill passes |
| Enrollment | d-only seed, hash-only registry bootstrap, pending pull-only join phase, dual bridge cursor gate, revocation and bearer rotations; the per-device artifact-bound three-client receipt gate is source-ready | Execute the receipt gate with native bridge promotion on separate d, da, and OnePlus disposable clients, then provision personal d/da/oneplus only after backups and explicit approval |
| Passwords | Pull/apply/readback before observe/publish; full native specifics; complete `PasswordForm` unique-key identity; single schema-6 state; durable one-at-a-time publication and pull-verified ambiguous outcomes; artifact-bound native fixture/capture/receipt gate | Compile the bridge, then run the gate on returned browser artifacts for prompts, save/update/generation/settings/suggestions/autofill/delete, rapid observer events, ambiguous-success restarts, and three-device stale conflicts |
| Cookies | Whole-profile canonical identity, readable private rollback journal, authoritative pull-only join replacement, bounded publication batches, preview/apply/readback/rollback, exact revision-scoped rejection evidence, unchanged-revision suppression, unverified-local-rotation hold, and a fixed marker-gated native CookieManager transaction fixture restricted to an empty debuggable Sync test profile | Compile the bridge and fixture; pass native snapshot/import/apply/readback/rejection/rollback, then prove colliding join replacement, multi-batch publication, later-revision retry, DBSC evidence scope, and authenticated-site behavior in disposable browsers; collect exact origin/login-entry evidence before adding a native password reauth flow |
| Origin state | Strict metadata-only, artifact-bound synthetic/disposable classifier; explicit preview/apply/readback/rollback contract; empty source-registered adapter set; no state values accepted | Disposable-browser evidence collector and one reviewed exact-origin adapter only where observed necessary |
| Tabs | Three-mechanism architecture: native Chromium clean/crash recovery; schema-2 all-valid-URL neutral exporter/store with explicit marked-disposable full-topology importer, live readback, restart-state validation and verified-rollback fail closure; stopped compressed full-profile generations with independent two-copy receipts, retention and disposable restore; exact-three health report; desktop and checksum-bound `computer.helium.passwords.test` app-sandbox CDP orchestration plus HMAC-authenticated evidence/status adapters require both replica drills | Compile the neutral exporter/importer; provision source-local schedules; run exact returned desktop and Android artifacts through all three mechanisms and independent damaged-generation drills before any personal health claim |
| Media/streaming | Reproducible fixtures, strict codec GN provenance, separate no-patch upstream-control builder, progressive Fetch/SSE and Service Worker streaming gates, explicit codec-versus-Widevine evidence, automatic target-scoped CDP Media-domain events plus Android package-UID logcat, immutable failure bundles, artifact-carried fail-closed device orchestration, source/fixture/media-bound A/B pair receipts, and live rootless tailnet-only H2/H3 origins with exact private-leaf SPKI admission; pinned Caddy starts QUIC at a 1200-byte payload so the complete Initial flight fits Tailscale's 1280-byte interface MTU, with direct H3 proven from lm and da | Run same-source control/Sync APK A/B on oneplus for negotiated protocols, lifecycle, video/audio, and content-free ChatGPT timing; CDM provisioning remains separate |
| Android source/build | Exact Chromium `150.0.7871.181`/Helium `0.14.8` lock; shared one-request immutable source helper; exact-HEAD, depot pin, cache-disable, monotonic version, and private single-entry contracts | Fresh isolated chromiumer source preparation, 321 selected patches (301 core + 7 Passwords + 13 Sync), GN generation, focused compile, then APK |
| Deployment | Hash-only bearer credential cutover, exact Tailnet endpoint/start gates, source unit/install gate, rollback-preserving installers, and fixed-topology compressed full-profile backup streaming to one NAS plus one authenticated peer without source-local staging | Prove live Tailnet HTTP, authorize the d SSH routes, build artifacts, run real two-copy profile backup/restore drills, then enroll sequentially only after explicit approval |

No personal profile, credential, cookie, or tab content is read by source tests.
