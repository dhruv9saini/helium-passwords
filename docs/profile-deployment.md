# Profile-safe browser installation

This is the executable boundary between a returned browser artifact and a
personal Helium profile. The tools do not inspect profile contents for the
audit, do not launch a browser, and do not deploy by themselves.

## Build artifact admission

Every install consumes the artifact and its separate strict receipt. The
receipt has exactly these fields:

```text
schema_version=1
artifact_sha256=<64 lowercase hex>
artifact_size=<bytes>
target=linux-x86_64|linux-arm64|linux-arm64-chroot|android-arm64
helium_sync_commit=<40 lowercase hex>
helium_passwords_commit=<40 lowercase hex>
helium_core_commit=<40 lowercase hex>
chromium_commit=<40 lowercase hex>
build_job_id=<stable chromiumer job id>
provenance_sha256=<64 lowercase hex>
created_at=<UTC YYYY-MM-DDTHH:MM:SSZ>
```

`scripts/deployment/verify-artifact-receipt.sh` rejects unknown or duplicate
fields, a target mismatch, abbreviated commits, size drift, and artifact hash
drift. Installers also require the recorded private source commit to exist in
their normal Git ancestry. The build pipeline still has to emit this receipt
from the returned provenance; an operator must not hand-author one.

## Full-profile backup

Create a mode-0600 configuration on the source device. The two destination
paths must already exist on filesystems distinct from the source and from one
another. They are storage roots, not browser profiles.

```text
version=1
source_device=d
profile_id=default
source_path=/home/d/.config/net.imput.helium
age_recipients=/secure/d-profile-recovery.recipients
age_identity=/MOUNTED/OFFLINE/d-profile-recovery-a.identity
retention_keep=3
destination_reserve_bytes=10737418240
destination=nas-on-lm|/MOUNTED/NAS
destination=da-copy|/MOUNTED/DA
```

Use at least two distinct age recipients whose private identities are held in
separate failure domains. The backup host needs only the recipient file. An
identity is needed for a restore drill and must not be placed in Git, lm server
state, the NAS server backup, or a Chromium artifact.

With the browser stopped:

```sh
scripts/profile-backup/helium-profile-backup.sh preflight /secure/d-profile.conf
scripts/profile-backup/helium-profile-backup.sh backup /secure/d-profile.conf
scripts/profile-backup/helium-profile-backup.sh status /secure/d-profile.conf GENERATION
scripts/profile-backup/helium-profile-backup.sh verify-receipt \
  /secure/d-profile.conf \
  /MOUNTED/NAS/helium-profile-backups/d/default/generations/GENERATION.receipt.env
```

Preflight refuses an open profile, insufficient destination capacity, a
destination on the source filesystem, or two destinations on the same
filesystem. Backup records a deterministic content fingerprint immediately
before and after the encrypted archive stream; any concurrent change aborts
the generation. Admission later refuses a running or byte-changed local
profile, so an old but otherwise healthy copy cannot authorize installation
after the profile changes.

Both destination copies carry the same ciphertext and receipt. `status`
rehashes both and requires them to agree. A damaged copy is preserved outside
the active set:

```sh
scripts/profile-backup/helium-profile-backup.sh quarantine \
  /secure/d-profile.conf nas-on-lm GENERATION checksum-failed
```

`retention-apply` keeps the configured newest count in `generations/` and
moves older, fully verified pairs to `retired/`; it does not delete them.

## Disposable restore drill

The restore parent must be a real mode-0700 directory with the literal marker
`.helium-disposable-profile-restore-root`. The child must not exist and its
name must start with `drill-`:

```sh
install -d -m0700 /secure/profile-restore-drills
touch /secure/profile-restore-drills/.helium-disposable-profile-restore-root
scripts/profile-backup/helium-profile-backup.sh restore-to-disposable \
  /secure/d-profile.conf GENERATION \
  /secure/profile-restore-drills/drill-d-GENERATION
```

Restore verifies both encrypted copies, rejects unsafe archive paths, decrypts
to a new directory, and matches the restored content fingerprint before it
writes a secret-free restore receipt. It never launches Helium, changes a
launcher, overwrites an existing profile, imports a copy on another device, or
opens tabs. A full-profile backup contains that source device's local session
files only as disaster-recovery data; it is not tab synchronization.

## Transactional desktop and chroot install

After disposable browser acceptance and the exact-profile backup gate:

```sh
scripts/laptop/install-laptop-sync.sh install \
  /artifacts/helium-linux.tar.xz /artifacts/helium-linux.receipt.env \
  /secure/d-profile.conf /MOUNTED/NAS/.../GENERATION.receipt.env
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
  /artifacts/helium-linux-arm64.tar.xz /artifacts/helium-linux-arm64.receipt.env \
  /secure/oneplus-chroot-profile.conf /MOUNTED/NAS/.../GENERATION.receipt.env
scripts/android-local/install-chroot-helium.sh rollback ARTIFACT_SHA256
```

The chroot installer refuses a running browser, retains releases under
`/opt/helium-sync-releases/<artifact-sha256>`, and atomically switches
`/opt/helium-sync` plus `/usr/local/bin/helium`. It never removes the previous
release.

## Android app enrollment boundary

`configure-android-chromium-sync.sh` accepts one explicit oneplus join
directory containing exactly `base_url`, `client.json`, and `token`. It
requires direct HTTPS, a pending or active oneplus join state, a path-bound
receipt, and two valid backup copies. It
force-stops the app, installs only
`<dataDir>/app_chrome/Default/helium-sync`, and preserves the old enrollment
under `helium-sync-rollbacks/`. It does not guess config paths, copy anything
from the phone chroot, create an HTTP loopback URL, or rewrite first-run state.

The current full-profile producer handles locally visible profile paths. A
streaming, root-mediated Android `app_chrome` producer that creates the same
content-bound receipt without staging plaintext on lm is still required before
this Android enrollment command can be used on personal data. Until that
producer and its disposable restore drill exist, OnePlus personal enrollment
is intentionally blocked.
