# Helium Sync Architecture

## Product boundary

Helium Sync has one native browser path. Chromium's password store is the
password authority and Chromium's `CookieManager` is the cookie authority.
The old CDP password writer, CookieCloud bridge, phone-local sync daemon, and
raw SQLite/profile copying are not installed or started by normal launch or
installation scripts. Their source remains only as isolated historical test
material.

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
root has critical name constraints for lm's exact `.ts.net` name and Tailscale
IPv4 address, and every client explicitly enrolls the authenticated public root
before receiving a URL or bearer credential. d recovery uses an age-encrypted
generation containing d's complete validated client state and credential. One
generation is encrypted to at least two dedicated recovery identities and
copied to two off-d locations; no recipient identity is stored with the
ciphertext. None of this recovery material belongs in the server data
directory, its NAS backup, a repository, or chromiumer.

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
3. lm registers only the device ID and credential hash with `pull` scope.
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

The build-independent disposable model exercises the same identity dimensions,
exact set/delete preview, successful target verification, and a partial apply
followed by verified rollback. That is executable synthetic proof, not
browser-runtime proof: the C++ bridge still needs the bounded chromiumer
compile and a new disposable-profile run before deployment.

Chromium device-bound sessions are observed through its device-bound-session
manager. A cookie proven device-bound, or a cookie rejected on the destination,
is marked non-clonable for that exact session; the last local session is
preserved and a reauthentication request is recorded. Automatic password-based
reauthentication is not browser-integrated yet. The metadata-only origin-state
audit binds controlled cookie/auth/DBSC outcomes and storage requirements to an
exact target and synthetic or disposable artifact hash, rejects secret-bearing
fields, and prevents synthetic evidence from creating a concrete portability
claim. It does not collect or transfer localStorage, IndexedDB, service-worker
storage, Cache Storage, or other per-origin state. Those stores require
site-specific disposable-profile evidence and an origin-scoped export/import
adapter; arbitrary application databases will never be live-merged.

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
directory.

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
SSH transport, encryption/copy logic, health proof, retention, quarantine, and
disposable restore are implemented and synthetic-tested. The native tab
producer is source-complete but not yet compile/runtime validated. da currently
has only a disabled user timer; oneplus has only source tools and a disabled
runner template. No source can be enabled until its fresh browser export, two
offline public recovery recipients, and both exact destination routes pass
preflight.

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
| Transport | Opaque v2 E2EE, direct TLS 1.3 server, offline constrained CA issuance/verification, authenticated device identity, scopes, CAS revisions, int64 string counters, tombstones, journal recovery; synthetic rootless endpoint and scheduled NAS restore proof live on lm | Restore root authorization, install the dedicated-account service, and enroll the public root on disposable browser clients |
| Enrollment | d-only seed, signed X25519 join wrapping, pending pull-only phase, dual bridge cursor gate, revocation and rotations; consolidated TLS-backed three-device protocol lifecycle passes | Execute native bridge promotion on disposable profiles, then provision personal d/da/oneplus only after backups |
| Passwords | Pull/apply/readback before observe/publish; full native specifics; conflict stop | Built-browser prompts, save/update/delete/autofill and three-device restart tests |
| Cookies | Whole-profile canonical identity, E2EE, preview/apply/readback/rollback, DBSC/rejection classification | Built-browser destination session tests and automatic password reauth integration |
| Origin state | Strict metadata-only, artifact-bound synthetic/disposable classifier; no state values accepted | Disposable-browser evidence collector and safe origin-scoped adapters only where observed necessary |
| Tabs | Local exporter/store, atomic checked generations, standalone content-bound disposable-restore validator, two-destination encrypted operations, corruption/retention/restore tests | Compile exporter; authorize da's dedicated key on d; provision independent recovery recipients; enable schedules only after two-route preflight; disposable browser restore on every device |
| Media/streaming | Reproducible fixtures, strict codec GN provenance, separate no-patch upstream-control builder, and explicit codec-versus-Widevine evidence | Same-commit control/Sync APK A/B on oneplus, HTTP/2+HTTP/3, video/audio/ChatGPT timing; CDM provisioning remains separate |
| Android source/build | Shared one-request immutable source helper; exact-HEAD, depot pin, cache-disable, and private single-entry contracts | Fresh isolated chromiumer source preparation, 292-patch apply, GN generation, focused compile, then APK |
| Deployment | Executable d recovery export/import, credential cutover, direct-TLS generation install/start gates, source unit/install gate, and rollback-preserving installers | Create off-device recovery identities/copies and offline TLS CA, enroll its public root, prove live tailnet TLS, d SSH/auth route, artifacts, profile backups, sequential enrollment |

No personal profile, credential, cookie, or tab content is read by source tests.
