# Chromium / Helium Integration Notes

This file describes integration intent. The audited target architecture is in
[`architecture.md`](architecture.md), known gaps are in [`../TODO.md`](../TODO.md),
and release evidence must satisfy [`acceptance.md`](acceptance.md).

## Do Not Sync Raw Files

Avoid syncing these directly:

- `Login Data`
- `Network/Cookies`
- session files under `Sessions/`

Those files are implementation details. They can contain platform-encrypted blobs, WAL state, and version-specific schema changes. Copying them also skips Chromium validation and deletion behavior.

## Record Payloads

The wire kinds are exactly `passwords` and `cookies`. Tabs are prohibited from
the transport, endpoint filters, server store, and client credentials. The
native tab exporter writes only to the device-local snapshot path.

The profile-local `tab_snapshot_export_path` value must equal the dedicated
absolute `browser_export` path in tab operations config and remain outside the
profile. The native bridge atomically refreshes it every five minutes even when
the payload is unchanged. `helium-tab-exporter.sh` admits only a recent,
same-user, mode-0600 regular file into `helium-tabs`; this freshness boundary
prevents a stopped browser's old export from satisfying backup health.

### Passwords

Canonical key material follows Chromium 150's complete login-table unique key:

```text
length(origin_url) || origin_url
length(username_element UTF-16 units) || username_element UTF-16BE
length(username_value UTF-16 units) || username_value UTF-16BE
length(password_element UTF-16 units) || password_element UTF-16BE
length(signon_realm) || signon_realm
```

The material has a versioned domain prefix and becomes
`credential/v2/<sha256>`. Length framing prevents delimiter ambiguity and raw
UTF-16 code units prevent replacement-character collisions. The encrypted
payload is Chromium's complete serialized `PasswordSpecificsData`, reconstructed
through `PasswordStoreInterface::AddLogin`, `UpdateLogin`, or `RemoveLogin`.

`password-state.json` schema 4 stores only fingerprints, revisions, deletion
state, key IDs, and publication intent. A schema-3 file is atomically rewritten
with all old entries preserved under `legacy_credentials`; only an unambiguous
local form/fingerprint match can seed a canonical record. One
`pending_publication` is durable before one push, and later observer intent is
kept separately. HTTP responses are not authoritative: a new latest-record pull
must verify the target revision and fingerprint, including after restart.

### Cookies

Implemented key identity:

```text
<partition-key including ancestor bit>/<exact domain form>/<path>/<name>/<source scheme>/<source port>
```

The length-framed identity is hashed for the record key. The v3 payload mirrors
the `net::CanonicalCookie` fields needed by
`network::mojom::CookieManager::SetCanonicalCookie`; DBSC site/session
inventory is local rejection evidence and is never put in the cookie payload.
A higher remote revision may change key epoch only to the client's active
epoch. Destination rejection is persisted for exactly that record/revision and
cleared by a later verified authoritative apply. The bridge restores the
complete last-good local snapshot and suppresses the rejected revision. A
later local cookie mutation is held locally as unverified rather than
published: Chromium exposes no signal that an arbitrary cookie rotation proves
a successful password login. `cookie-reauth-required.json` records only the
schemeful site and explicitly forbids navigation or form submission because a
cookie does not identify an exact origin or login entry. Browser-native
reauthentication remains blocked until disposable evidence provides both.

## Build Strategy

Desktop Helium builds go through this repo's platform wrapper:

```sh
bash scripts/build.sh linux x86_64
gh workflow run build.yml -f platform=linux -f arch=x86_64 -f run-build=true
```

`scripts/prepare-platform.sh` clones the official Helium platform repo, removes
Helium's upstream password-disable patch, injects the restored-password patches,
and then injects the desktop-safe sync patch subset as
`patches/helium/sync/`. The desktop subset keeps the native sync service and
profile service wiring, but excludes Android startup, OSCrypt, branding, and
password-store replacement files.

Android uses the same public/core backbone through a direct pinned Chromium
composition because Helium has no Android platform repository:

```sh
gh workflow run chromium-android.yml
```

`chromium/android-build.lock` is the single source for the exact Chromium tag,
Chromium commit, Helium core commit, and depot_tools commit.
`scripts/chromium/prepare-android-source.sh` is the sole source-acquisition
path for both repositories. It disables depot_tools' normal `gclient`
self-update, makes exactly one
`gclient sync --revision src@<locked SHA> --nohooks --no-history` request, and
requires Chromium `HEAD` to equal the lock. The private runner does not prepend
a moving-main sync, manually check out the commit, or run a repair sync. It
re-verifies the exact clean depot_tools checkout around the later `runhooks`
call and records the executing depot_tools commit plus update policy in
packaged provenance. A returned artifact is rejected if those records differ
from its lock.
`apply-android-backbone.sh` applies the ordered Helium core series while
omitting only the mandatory password-disable patch, then applies the two public
Passwords patches, nine private Sync patches and overlay, Helium
transformations/resources, and shared plus Android GN args.
The current plan contains 312 selected patches: 301 Helium core patches after
deliberately omitting its password-disable patch, two public Passwords
restorations, and nine private Sync patches. The single-acquisition contract is
source-tested, but the complete apply still needs a prepared checkout and
compilation on chromiumer.

After chromiumer production preflight passes, the first bounded job combines
strict source preparation, GN generation, and the smallest media-buildflag
compile. `CHROMIUM_ANDROID_PROVENANCE_ONLY=true` is explicit: without it, a
non-APK target fails packaging instead of pretending to be an APK artifact.

```sh
job=hs-android-150-media-flags-01
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$job" 80
scripts/chromiumer-job.sh start "$job" -- env \
  HELIUM_SYNC_REPO=. \
  GITHUB_WORKSPACE=.build \
  CHROMIUM_ANDROID_PHASE=all \
  CHROMIUM_TARGET=media:media_buildflags \
  CHROMIUM_ANDROID_PROVENANCE_ONLY=true \
  bash scripts/chromium/build-android-ci.sh

scripts/chromiumer-job.sh fetch "$job" \
  .build/android-artifacts/compile-media_media_buildflags-arm64.tar.xz
```

The returned proof contains resolved build provenance and `compile-proof.env`,
not an APK. Use separate unique jobs for `media`, the two Helium sync GN
targets, and finally `chrome_public_apk`; every job must pass the same admission
and isolation policy.

The Android runtime A/B uses `build-android-control-ci.sh` for the control. It
consumes the same immutable source helper and codec arguments but requires a
clean tracked Chromium tree after hooks, applies no Helium, Passwords, or Sync
patch, records composition `upstream-control`, and emits the distinct
`computer.helium.control.test` package. This is deliberately a separate entry
point so a hidden composition flag cannot accidentally label a patched APK as
the control.

GN generation uses `--fail-on-unused-args`. Media/provenance validation fails
unless the source lock resolves exactly and GN proves Android target,
`ffmpeg_branding = "Chrome"`, `proprietary_codecs = true`, and
`media_use_ffmpeg = true`. Packaged provenance records commits, resolved GN
args, composition order, and patch/overlay hashes. These flags do not prove a
device decoder and do not provision Widevine. Provenance also contains
`depot-tools-commit.txt` and `depot-tools-update-policy.txt`; the latter must be
exactly `DEPOT_TOOLS_UPDATE=0`.

Full Chromium builds run only through the isolated chromiumer workflow in
`chromiumer-builds.md`; lm and the NAS are not compiler workspaces. GitHub
workflows retain manual source/caching support, but private Actions are
independently blocked by billing and are not current validation evidence.
