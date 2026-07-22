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
       | HTTPS over Tailscale; per-device bearer credential
       v
  lm Tailscale Serve :443
       |
       v
  helium-syncd 127.0.0.1:44719
       |
       +-- /var/lib/helium-sync/devices.json
       |     device IDs, roles, scopes, revocation, credential hashes
       +-- /var/lib/helium-sync/records.jsonl
       |     kind/key/revision/device/key-id/nonce/ciphertext
       +-- /var/lib/helium-sync/snapshots/
             atomic opaque journal generations
```

lm sees record identity metadata and ciphertext. It has no content key and
cannot decrypt passwords or cookies. All enrolled browser profiles with a live
content key can decrypt the shared records. Recovery holders can decrypt only
if they possess a separately stored, d-signed encrypted key export and its
recipient private key. Neither belongs in the server data directory, NAS copy
of that directory, a repository, or chromiumer.

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
6. With the browser stopped, `enrollment-complete` requires both bridge
   schemas and cursors to equal `client.json`, then asks the server to promote
   that exact current cursor. The server atomically grants `push` only then.
7. The restarted browser reloads the now-active state. An unchanged restart
   emits no records.

Credentials are per-device, hash-verified, scoped, independently rotatable with
an overlap/confirm/retire sequence, and revocable. d cannot be revoked because
it is the sole recovery authority; loss of d must be handled from separately
proven recovery material, not by giving lm a content key.

Content-key rotation is staged. d creates and distributes a signed encrypted
keyring update, every active device acknowledges installation, d activates the
new epoch, latest records and tombstones are CAS-re-encrypted, every device
acknowledges the verified rekey cursor, and only then can d retire the old key.

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

Chromium device-bound sessions are observed through its device-bound-session
manager. A cookie proven device-bound, or a cookie rejected on the destination,
is marked non-clonable for that exact session; the last local session is
preserved and a reauthentication request is recorded. Automatic password-based
reauthentication is not browser-integrated yet. localStorage, IndexedDB,
service-worker storage, and other per-origin state are not transferred yet.
They require site-specific disposable-profile evidence and an export/import
adapter; arbitrary application databases will never be live-merged.

## Device-local durable tabs

The browser tab bridge exports a bounded neutral snapshot outside the profile
using create-new, fsync, and atomic rename. `helium-tabs` validates checksums,
commits immutable generations, explicitly quarantines corruption without
deletion, applies 24-hourly/14-daily/12-weekly retention without deleting the
last known-good copy, and restores only to a nonexistent disposable state
directory.

Every source device runs its own hostname-bound scheduler and device-specific
age key namespace. One validated generation is encrypted to at least two
distinct recovery recipients and copied to exactly two off-source hosts with
incoming-file verification and atomic promotion. The enforced topology is lm's
separately mounted NAS plus da for d and oneplus, and lm's NAS plus d for da.
A durable health proof binds the current generation, configuration, key
namespace, topology, and both verified remote hashes. A fleet audit rejects
recipient reuse across device configs. Repositories are namespaced by source
device and profile and are never opened or merged on a different device. Local
Chromium recovery and local generations are extra layers, not either
off-device copy. Recovery identities stay outside all source and destination
stores except while explicitly attached for a disposable restore drill.

## Runtime and build boundaries

lm is the control plane and hosts only the loopback opaque service. Tailscale
Serve terminates TLS and applies tailnet access control. The service unit is
`helium-syncd.service`, runs as the dedicated `helium-sync` account, and is
hardened by systemd. `scripts/install-lm-sync-service.sh` installs and
initializes it but refuses activation until Tailscale Serve is visibly
forwarding to `127.0.0.1:44719`.

Every Chromium compile runs on chromiumer through
`scripts/chromiumer-job.sh` and the pinned Nix environment. The wrapper
enforces two build jobs, CPU/memory/I/O/task/disk limits, an eight-hour stop,
watchdog, detached journald logs, one cancel command, provenance/artifact
receipts, and exactly-once completion notification to
`dhruv.codex@gmail.com`. lm and the NAS are never compiler workspaces.

## Verified source versus remaining gates

| Area | Implemented and source-tested | Still required before personal data |
| --- | --- | --- |
| Transport | Opaque v2 E2EE, authenticated device identity, scopes, CAS revisions, int64 string counters, tombstones, journal recovery | Native Chromium compile, TLS endpoint, supervised live recovery drill |
| Enrollment | d-only seed, signed X25519 join wrapping, pending pull-only phase, dual bridge cursor gate, revocation and rotations | Execute on disposable profiles, then provision d/da/oneplus |
| Passwords | Pull/apply/readback before observe/publish; full native specifics; conflict stop | Built-browser prompts, save/update/delete/autofill and three-device restart tests |
| Cookies | Whole-profile canonical identity, E2EE, preview/apply/readback/rollback, DBSC/rejection classification | Built-browser destination session tests and automatic password reauth integration |
| Origin state | Explicitly absent | Per-origin storage audit and safe adapters where observed necessary |
| Tabs | Local exporter/store, atomic generations, two-destination encrypted operations, corruption/retention/restore tests | Compile exporter; deploy independent schedules/routes; disposable browser restore on every device |
| Media/streaming | Reproducible fixtures and strict codec GN provenance checks | Control/Sync APK A/B on oneplus, HTTP/2+HTTP/3, video/audio/ChatGPT timing |
| Deployment | Source unit/install gate and rollback-preserving installers | Tailscale HTTPS enablement, d SSH/auth route, artifacts, profile backups, sequential enrollment |

No personal profile, credential, cookie, or tab content is read by source tests.
