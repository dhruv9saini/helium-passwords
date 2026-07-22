# Durable Tab Snapshot Operations

This layer schedules and copies the neutral `helium-tabs` snapshot model. It
does not read Chromium `Sessions`, `Login Data`, cookies, a browser profile, or
the syncstore. Chromium's tab bridge calls only session/tab APIs and atomically
refreshes one neutral export outside the profile every five minutes, including
when tabs are unchanged. `helium-tab-exporter.sh` is the narrow boundary from
that fixed file to a new scheduler-owned input. Until the native producer has
compiled and passed a disposable-profile test, use this workflow only with
synthetic exports.

## Source-local scheduler

Copy `scripts/tabs/tab-ops.conf.example` outside the repository, make it mode
`0600`, and set one source device/profile namespace. Configuration version 3
accepts only `d`, `da`, or `oneplus`; `key_id` must be the corresponding
`DEVICE-tabs-v1`. One configuration owns one store. The store and operation
state must remain outside the browser profile.

Set `browser_export` to a dedicated path outside the profile, and put the same
absolute path in the profile-local `helium-sync/tab_snapshot_export_path`
control file. `browser_export_max_age_seconds=420` gives the five-minute native
refresh one bounded scheduling margin; configuration rejects values outside
300 through 600 seconds. The adapter rejects a missing, empty,
oversized, symlinked, wrong-owner, non-0600, future-dated, or older export. It
also refuses an existing output and detects a source replacement during copy.
Consequently a stopped browser ages out and cannot create a healthy snapshot
cycle from an old export.

```sh
scripts/tabs/tab-snapshot-scheduler.sh run-once "$config"
scripts/tabs/tab-snapshot-scheduler.sh status "$config"
scripts/tabs/tab-snapshot-scheduler.sh schedule "$config"
```

`run-once` is the local-capture diagnostic. `cycle` and `schedule` are the
durability paths:

```sh
scripts/tabs/tab-snapshot-scheduler.sh cycle "$config"
```

`run-once` takes a nonblocking namespace lock, gives the adapter a new mode
`0600` temporary file, commits through `helium-tabs`, validates the committed
generation, discards exporter output, and atomically records a status without
URLs. `cycle` continues through encryption, both off-device transfers, health,
and safe retention. `schedule` repeats the full cycle at `interval_seconds`.
`status` fails unless the snapshot is fresh and both copies of its generation
match the local ciphertext and manifest hashes. A successful full cycle also
atomically writes `health-proof.env`. The proof binds the generation, source,
profile, key namespace, exact destination topology, configuration hash, and
the verified backup-status hash. `status` rechecks the remote copies and fails
if this proof is missing, stale, or no longer matches configuration.

Every command verifies that short `uname -n` equals `source_device`. A config
for d cannot capture, copy, restore, or apply retention on da, oneplus, or lm.
This is a deployment gate for oneplus: measure or set its hostname before
enabling the service rather than weakening the check.
`preflight` also runs the adapter's freshness check, so enabling a timer fails
while the browser export is absent or stale.

For d and da, `scripts/tabs/install-linux-tab-scheduler.sh install CONFIG`
installs the scripts, config, and constrained systemd user service/timer but
leaves the timer disabled. `enable` first runs the full tool/exporter/two-host
preflight and only then enables it. The timer runs one full cycle every 15
minutes; failed conditions skip the service rather than running a partial
backup.

Oneplus/Android has no running systemd manager and the Arch chroot may have no
mounted `/proc`. Neither is a scheduler dependency. The source installer places
only non-overwriting tools, a config template, and a mode-0600 disabled runner
under the chroot root user's home:

```sh
HOME=/root scripts/tabs/install-oneplus-tab-scheduler.sh install \
  scripts/tabs/tab-ops.oneplus.conf.example
```

It does not install `helium-tabs`, `age`, keys, recipients, an active
`tab-ops.conf`, an Android `service.d` file, or an enable marker. Re-running it
against any existing target fails instead of overwriting device work.

`scripts/tabs/oneplus-tab-cycle-service.sh` is the eventual Magisk runner. Even
if it is copied into `service.d`, its default service command exits without
doing work unless `/data/adb/helium-tab-ops/enabled-v1` is a root-owned mode-0600
regular file containing exactly `enabled-v1`. The source installer never
creates that file.

Each preflight and cycle uses Android's `unshare -u`, sets the isolated UTS
hostname to exactly `oneplus`, verifies it, and only then enters the chroot.
Android's global `localhost` hostname is unchanged. `preflight` deliberately
uses the Magisk path rather than `systemctl`; it reports whether `/proc` happens
to be mounted but does not require or mount it. Immediately before every
chroot entry, the runner verifies that Android `/dev/null` is a non-symlink
character device with major/minor `1:3`. It accepts the chroot only with the
same invariant; otherwise it makes exactly one `mount -o bind /dev CHROOT/dev`
and rechecks the device identity before continuing. A failed mount or invalid
post-mount identity fails closed without entering the chroot. The broader
desktop `android-bind-mounts.sh` helper also mounts `/proc`, `/sys`, and
`devpts`, so the headless runner intentionally does not invoke it or depend on
a desktop session having run. The nested backup preflight still requires
`age`, `jq`, `helium-tabs`, a fresh native export, and both authenticated
outbound SSH destinations. A future operator must run this preflight
successfully before separately installing the runner into `service.d` and
creating the enable marker. No installer or service was deployed or enabled by
this repository change. Do not create a second profile reader to work around
the exporter.

## Two encrypted off-device copies

The backup command makes one age ciphertext for the validated generation and
copies that exact file to exactly two distinct destination hosts. The topology
is code-enforced, not merely documented:

| Source | Copy 1 | Copy 2 |
| --- | --- | --- |
| d | separately mounted NAS filesystem on lm | da |
| da | separately mounted NAS filesystem on lm | d |
| oneplus | separately mounted NAS filesystem on lm | da |

All destinations use noninteractive SSH. The lm destination fails preflight
and backup if `findmnt` resolves its target to `/`; a directory on lm's system
disk cannot masquerade as the NAS. No source device or chromiumer can count as
one of its own copies.

Each source config names `ssh_user`, a source-local dedicated `ssh_identity`,
and a source-local `ssh_known_hosts` file. Both files must be owned by the
source user, mode `0600`, nonempty regular files, and not symlinks. The
transport ignores user SSH config, offers only that identity, requires a
matching pinned host key, disables forwarding and TTY allocation, and uses
BatchMode. Specifically, it uses OpenSSH `-F none`, whose defined meaning is
to read no client configuration files, and supplies the dedicated pinned-host
file as both the user and global host-key database. Do not replace either with
`/dev/null`: the OnePlus Arch chroot has had a non-device `/dev/null`, and an
unattended transport must not depend on that path being a valid character
device. Give the public half of this key a `restrict` authorization on each
destination. This makes the unattended route explicit without reusing a
general-purpose login key or trusting a first connection.

Each device has its own `key_id` and age-recipient file. The normalized
recipient-set fingerprint is bound into every backup manifest. At least two
distinct recovery recipients are required so losing one recovery identity does
not make every snapshot unreadable. Do not reuse recipient sets across source
devices. Private identities are needed only for an explicit restore: keep them
on separate recovery media, not persistently on the source, either destination,
or in the repository. Temporarily attach the matching source-device identity
only for a restore drill, then remove it. Destination devices hold ciphertext
only and cannot open or merge another device's tabs.

Before installation, stage the three public-recipient configs on lm and prove
exact topology and distinct key material without contacting a browser:

```sh
scripts/tabs/tab-fleet-audit.sh d.conf da.conf oneplus.conf
```

The audit outputs only device IDs, key IDs, recipient fingerprints, and
destination IDs; it never prints keys or tab content.

Destination data is namespaced as:

```text
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE/generations/GENERATION.tar.age
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE/generations/GENERATION.backup.env
```

The clear manifest contains only source/profile/key IDs, the normalized public
recipient fingerprint, generation, ciphertext hash/size, snapshot-manifest
hash, and time. URLs and tab titles exist only in the age ciphertext. Each
transfer keeps a configurable free-space reserve,
lands in `incoming`, verifies SHA-256, and then renames into place. Existing
bytes are never overwritten. A collision or mismatch fails until it is moved
to quarantine explicitly.

```sh
scripts/tabs/tab-backup.sh backup "$config"
scripts/tabs/tab-backup.sh status "$config"
scripts/tabs/tab-backup.sh quarantine "$config" d-copy GENERATION bad-hash
scripts/tabs/tab-backup.sh quarantine "$config" local-spool GENERATION bad-hash
```

The configuration parser never evaluates shell. It rejects topology aliases,
local destinations, the wrong replica device, and either host when it equals
the source device. Two directories on lm cannot masquerade as two hosts.

## Retention and recovery

Backup retention follows only generations that the underlying fail-closed
`helium-tabs retention-plan` considers deletable and that still have two
healthy off-device copies. It is two-step and revalidates the snapshot plan:

```sh
scripts/tabs/tab-backup.sh retention-plan "$config" /new/path/retention.plan
scripts/tabs/tab-backup.sh retention-apply "$config" /new/path/retention.plan
```

Apply moves both independently verified destination copies into namespaced
quarantine, then removes the now-redundant source-local ciphertext and applies
the exact revalidated local snapshot retention plan (newest plus 24 hourly,
14 daily, and 12 weekly buckets, protected snapshots, and invalid snapshots).
It refuses the entire
operation unless every local deletion candidate has two healthy copies. This
bounds the source device's snapshot store and encryption spool while keeping
two off-device quarantine copies. There is intentionally no automatic
off-device quarantine purge.

Restore is explicit and may target only a nonexistent disposable directory:

```sh
scripts/tabs/tab-backup.sh restore-to-disposable "$config" \
  d-copy GENERATION /new/disposable/tab-restore
```

The command fetches one copy, verifies the ciphertext, decrypts to a temporary
directory, rejects any unexpected tar member, revalidates the snapshot through
`helium-tabs`, and uses its atomic disposable restore. It then invokes the
standalone `validate-restore` gate and verifies that the receipt names the
requested source generation, device, and profile. Nothing in this layer can
promote a restore into a live browser profile. The wrapper must run on the
snapshot's source device and cannot open or merge the result into another
device's browser.

After that neutral restore succeeds, `helium-tabs prepare-browser-profile`
may prepare a browser-readable copy only as a new `drill-*` child of an
operator-created mode-0700 root containing the exact
`.helium-tabs-disposable-root-v1` marker. The command revalidates the neutral
receipt, retains its source files, writes only current URLs as startup URLs,
validates staging, and atomically publishes the unopened profile. It never
launches a browser or accepts an existing target. Run
`validate-browser-profile --profile-dir PATH` before first launch; the exact
commands and current reconstruction limits are in `tab-snapshots.md`.

If a local generation itself is corrupt, preserve it explicitly before
unblocking retention:

```sh
helium-tabs quarantine --store "$snapshot_store" \
  --generation GENERATION --reason checksum-mismatch
```

This atomically moves the entire generation under the store's `quarantine/`
directory. It never deletes bytes and it never happens automatically.

## Live readiness audit (2026-07-22)

- lm has about 18.8 GiB free. `/srv/nas` is mounted read-write on a separate
  ext4 disk with about 1.3 TiB free. Mode-0700 destination namespaces now exist
  for d, da, and oneplus under `/srv/nas/helium-tab-backups`.
- chromiumer has 105.7 GiB available, but it is a build executor and is not a
  tab-backup destination.
- da and d are online in Tailscale. d answers TCP/22 but rejects lm's available
  BatchMode identities; da's new backup identity is likewise not authorized on
  d. Therefore da's required d replica is not deployable and da must not be
  enabled.
- da has about 208 GiB free, a running systemd user manager, `jq`, `rsync`, the
  standard integrity tools, and age 1.3.1. Its source tools, commit-provenance
  `helium-tabs`, config, service, and user timer are staged. The timer is both
  disabled and inactive. Preflight fails closed because the independent public
  recovery-recipient file has not been provisioned; the native export and d
  route also remain unsatisfied.
- oneplus is online and reachable through authorized ADB, with roughly 410 GiB
  free under `/data`. Its Android shell is not the backup runtime. The Arch
  chroot has `jq`, `rsync`, the integrity tools, and age 1.3.1, but no running
  systemd manager. Source tools, the ARM64 `helium-tabs` binary, config template,
  and disabled Magisk runner template are staged. There is no active config,
  installed Magisk service, or enable marker.
- Its Android and chroot hostname is currently `localhost`. The disabled
  Magisk runner's isolated UTS namespace supplies `oneplus` only to the backup
  process, avoiding any global hostname change. The chroot's dedicated key now
  reaches lm and da noninteractively with strict pinned-host-key verification.
  OpenSSH 10.3p1 on lm and in the chroot both parse `-F none`; a synthetic
  command-only route proof also reaches both destinations without reading a
  client config or relying on the chroot's malformed `/dev/null`. The
  underlying unmounted chroot path is still a mode-0666, 43-byte regular file;
  the source runner now binds only Android `/dev` and verifies `1:3` before any
  headless chroot entry. This invariant is synthetic-tested but has not mounted
  the live chroot in this audit. The source remains disabled until offline
  public recovery recipients and the native browser export exist.
- da's dedicated public-key fingerprint is
  `SHA256:AxzKZUs3u5vVOxzhrHKRXMShn5amwgQxE/zemOtVPV4`; oneplus's is
  `SHA256:HyHqmUFOnyo5rNWP+OYTq6QM36Sbr+pYc2dd1n7nhCM`. Destinations authorize
  these dedicated backup keys with OpenSSH `restrict`. The pinned lm and da
  host-key fingerprints match the servers' own ED25519 public keys. Private
  keys remain only on their source devices; no age recovery identity was
  created or copied.
- The source adapter and native five-minute refresh contract are implemented
  and synthetic-tested. The native bridge still requires a chromiumer compile
  and disposable-profile run before any scheduler is enabled or source is
  promoted beyond disabled staging.

These are deployment gates, not reasons to weaken destination independence or
copy unencrypted tab data through an intermediary.
