# Profile-safe browser installation

This is the executable boundary between a returned browser artifact and a
personal Helium profile. The tools do not inspect profile contents for the
audit, do not launch a browser, and do not deploy by themselves.

## Build artifact admission

Every install consumes the artifact and its separate strict receipt. The
receipt has exactly these fields:

```text
schema_version=2
artifact_sha256=<64 lowercase hex>
artifact_size=<bytes>
target=linux-x86_64|linux-arm64|linux-arm64-chroot|android-arm64
helium_sync_commit=<40 lowercase hex>
helium_passwords_commit=<40 lowercase hex>
helium_core_commit=<40 lowercase hex>
chromium_commit=<40 lowercase hex>
build_job_id=<stable chromiumer job id>
provenance_sha256=<64 lowercase hex>
full_graph_receipt_sha256=<64 lowercase hex>
full_graph_inventory_sha256=<64 lowercase hex>
created_at=<UTC YYYY-MM-DDTHH:MM:SSZ>
```

`scripts/verify-deployment-artifact-receipt.sh` rejects unknown or duplicate
fields, a target mismatch, abbreviated commits, size drift, and artifact hash
drift. The two full-graph hashes bind the deployment to the private concrete
graph evidence copied into `provenance/full-graph/`; the internal schema-4
manifest repeats both hashes and binds the packaging tool source and commit.
There is one accepted schema and no legacy verifier fallback.
`linux-product.conf` binds desktop Sync to `helium-sync-linux-x86_64` and
`linux-x86_64`, and binds the cross-built OnePlus chroot artifact to
`helium-sync-linux-arm64` and `linux-arm64-chroot`. It also records the exact
public Passwords ancestor and requires the private Sync commit to come from
this repository. Installers require the recorded private source commit in
their normal Git ancestry. Only `scripts/package-linux-runtime.sh` may create
the post-build receipt through `scripts/write-deployment-artifact-receipt.sh`;
an operator must not hand-author one.

## Full-profile backup

Create a mode-0600 configuration beside the backup producer. It names exactly
one NAS destination on lm and one required peer-device destination. d and da
run the producer locally and reach both destinations through SSH. The OnePlus
app-profile producer runs on lm, uses the NAS mount locally, and reaches da
through SSH. The source hostname is an admission invariant: a d config runs
only on d, a da config only on da, and a oneplus app-profile stream only on lm.
Destination roots must already exist.

```text
version=3
source_device=d
profile_id=default
source_path=/home/d/.config/net.imput.helium
ssh_user=d
ssh_identity=/home/d/.ssh/helium_profile_backup_ed25519
ssh_known_hosts=/home/d/.ssh/helium_profile_backup_known_hosts
retention_keep=3
destination_reserve_bytes=10737418240
destination=nas-on-lm|nas|ssh|lm|lm|/srv/nas/helium-profile-backups
destination=da-copy|device|ssh|da|da|/home/d/.local/share/helium-profile-backups
```

The SSH identity and pinned known-hosts file must be source-user-owned,
nonempty, regular, non-symlink mode-0600 files. The transport ignores user SSH
configuration, uses BatchMode and `-F none`, offers only that key, pins the
destination host key, and disables forwarding and TTY allocation. Tailscale
and SSH are the confidentiality boundary; the backup format does not add an
inner encryption layer.

The enforced topology is the same as tab disaster recovery:

| Source | NAS copy | Peer copy |
| --- | --- | --- |
| d | `/srv/nas/helium-profile-backups` on lm | `/home/d/.local/share/helium-profile-backups` on da |
| da | `/srv/nas/helium-profile-backups` on lm | `/home/d/.local/share/helium-profile-backups` on d |
| oneplus | `/srv/nas/helium-profile-backups` on lm | `/home/d/.local/share/helium-profile-backups` on da |

With the browser stopped:

```sh
scripts/profile-backup/helium-profile-backup.sh preflight /secure/d-profile.conf
scripts/profile-backup/helium-profile-backup.sh backup /secure/d-profile.conf
scripts/profile-backup/helium-profile-backup.sh status /secure/d-profile.conf GENERATION
scripts/profile-backup/helium-profile-backup.sh receipt-export \
  /secure/d-profile.conf nas-on-lm GENERATION \
  /secure/receipts/d-default-GENERATION.env
scripts/profile-backup/helium-profile-backup.sh verify-receipt \
  /secure/d-profile.conf \
  /secure/receipts/d-default-GENERATION.env
```

Preflight refuses an open profile, insufficient destination capacity, a
destination on the source device, a wrong authenticated host, a system-disk
directory masquerading as lm's NAS, or any topology other than the fixed NAS
plus peer. Backup records a deterministic content fingerprint immediately
before and after the compressed stream; any concurrent change aborts the
generation. Admission later refuses a running or byte-changed local profile,
so an old but otherwise healthy copy cannot authorize installation after the
profile changes.

The producer compresses once, then fans the archive through pipes directly
into private per-destination incoming directories. No source-local archive is
created. Both incoming archives must match the producer's stream hash and size
before the same schema-3 receipt is copied with rsync. The receipt binds the
source path and source fingerprint, its explicit `normalized-tree-v1` or
`tar-stream-v1` method, generation, archive hash and size, and exact
destination topology. The method distinction is required because an
Android `adb exec-out` producer admits the exact root tar stream, while a local
desktop producer can fingerprint the stopped filesystem tree directly. Each
destination atomically renames its complete incoming directory into
`generations/GENERATION`; `status` downloads only the small receipts, rehashes
both remote archives in place, and requires the copies to agree. A damaged
destination generation is preserved outside the active set:

```text
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE_ID/generations/GENERATION/profile.tar.zst
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE_ID/generations/GENERATION/receipt.env
```

```sh
scripts/profile-backup/helium-profile-backup.sh quarantine \
  /secure/d-profile.conf nas-on-lm GENERATION checksum-failed
```

`retention-apply` keeps the configured newest count in `generations/` and
moves older, fully verified generation directories to `retired/` on both
hosts. It does not delete them.

## Disposable restore drill

The restore parent must be a real mode-0700 directory with the literal marker
`.helium-disposable-profile-restore-root`. The child must not exist and its
name must start with `drill-`:

```sh
install -d -m0700 /secure/profile-restore-drills
touch /secure/profile-restore-drills/.helium-disposable-profile-restore-root
scripts/profile-backup/helium-profile-backup.sh restore-to-disposable \
  /secure/d-profile.conf da-copy GENERATION \
  /secure/profile-restore-drills/drill-d-GENERATION
```

Restore verifies the selected authenticated destination's complete inventory,
receipt, hash, and size independently, then streams that archive through zstd
without staging a source-local archive. This permits a healthy replica to
recover while its damaged sibling is quarantined; the normal pre-fault gate
still restores and proves both destinations separately. Extraction is confined
to a new child of the marked
disposable root. A local backup's restored normalized tree, or an Android
backup's decrypted tar stream, must equal the corresponding admitted
fingerprint before the atomic publish and secret-free restore receipt. The
command never launches Helium, changes a launcher, overwrites an existing
profile, imports a copy on another device, or opens tabs. A full-profile
backup contains that source device's local session files only as
disaster-recovery data; it is not tab synchronization.

The browser-native password/cookie neutral mechanism uses the same authenticated
backup format for its independent API-produced snapshot directory, then uses
`scripts/native-recovery/runtime-drill.sh` for exact browser readback. That
runner admits only a fresh marked desktop profile or the checksum-admitted
`computer.helium.sync.test` sandbox; it cannot target the production Android
package. See [nine-path-recovery.md](nine-path-recovery.md) for its two-replica
drill and terminal fleet receipt.

After restoring the same synthetic generation independently from both
destinations, use the authenticated first/second-start gate in
[tab-runtime-proof.md](tab-runtime-proof.md). It consumes each restore's
source-bound receipt and requires the two evidence records to name distinct
destinations with the same archive before `full-profile.status` can be
emitted.

## Transactional desktop and chroot install

After disposable browser acceptance and the exact-profile backup gate:

```sh
scripts/laptop/install-laptop-sync.sh install \
  /artifacts/helium-sync-linux-x86_64.tar.xz \
  /artifacts/helium-sync-linux-x86_64.receipt.env \
  /secure/d-profile.conf /secure/receipts/d-default-GENERATION.env
```

The installer extracts to
`~/.local/opt/helium-sync-releases/browser/<artifact-sha256>`, validates the
runtime inventory, stores the receipt inside the immutable generation, and
atomically switches `~/.local/opt/helium-sync-app`. Existing browser and tool
generations are retained. Rollback changes only the symlink:

```sh
scripts/laptop/install-laptop-sync.sh rollback ARTIFACT_SHA256
```

For the OnePlus Arch chroot:

```sh
scripts/android-local/install-chroot-helium.sh install \
  /artifacts/helium-sync-linux-arm64.tar.xz \
  /artifacts/helium-sync-linux-arm64.receipt.env \
  /secure/oneplus-chroot-profile.conf /secure/receipts/oneplus-chroot-GENERATION.env
scripts/android-local/install-chroot-helium.sh rollback ARTIFACT_SHA256
```

The chroot installer refuses a running browser, retains releases under
`/opt/helium-sync-releases/<artifact-sha256>`, and atomically switches
`/opt/helium-sync` plus `/usr/local/bin/helium`. It never removes the previous
release.

## Android app enrollment boundary

Create the full app profile generation first:

```sh
scripts/android-local/backup-android-chromium-profile.sh \
  /secure/oneplus-app-profile.conf
```

The config's `source_path` must exactly match the installed package's resolved
`<dataDir>/app_chrome`. The producer force-stops the app, streams root tar over
`adb exec-out`, fingerprints one preflight stream, and accepts the compressed
stream only when its SHA-256 is identical. The plaintext tar is never written
on lm; it flows directly through zstd and fans out to the local NAS
incoming directory and authenticated da SSH incoming directory. Both copies
must match the local archive-stream hash before either generation becomes
active.

Disposable Android gates set
`CHROMIUM_ANDROID_PACKAGE=computer.helium.sync.test` and
`ANDROID_ADB_SERIAL=oneplus:5555`. For that exact debuggable package, both the
full-profile producer and enrollment installer reconnect and bind the fixed
serial, then use Android `run-as` instead of Magisk. The profile archive and
enrollment tar stream directly across ADB; the enrollment bundle is never
published under `/data/local/tmp`. This rootless path cannot name the
production package. The production `computer.helium.sync` boundary remains a
separate stopped-profile, rooted operation and still requires explicit review
of its admitted two-copy backup before any mutation.

`configure-android-chromium-sync.sh` accepts one explicit oneplus join
directory containing exactly `base_url`, `client.json`, and `token`. It
  requires direct private-Tailnet HTTP, a pending or active oneplus join state, a path-bound
receipt, and two valid backup copies. It
force-stops the app, installs only
`<dataDir>/app_chrome/Default/helium-sync`, and preserves the old enrollment
under `helium-sync-rollbacks/`. It also creates the marked app-private
`<dataDir>/files/helium-native-recovery/oneplus/default` directory and writes
that exact path to `native_recovery_root`; it never places neutral recovery
snapshots inside `app_chrome`. It does not guess config paths, copy anything
from the phone chroot, create an HTTP loopback URL, or rewrite first-run state.

Immediately before changing enrollment, the configurator streams and hashes
the stopped `app_chrome` tree again and requires it to match the admitted
backup. A stale or path-only receipt therefore cannot authorize a mutation.
The source and synthetic gates are complete; personal OnePlus use remains
blocked until this exact producer, two real private off-device destinations,
and restore into a disposable Android test profile pass on the actual device.
