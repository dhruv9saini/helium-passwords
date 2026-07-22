# Durable Tab Snapshot Operations

This layer schedules and copies the neutral `helium-tabs` snapshot model. It
does not read Chromium `Sessions`, `Login Data`, cookies, a browser profile, or
the syncstore. The missing browser integration is a narrow exporter that calls
Chromium's session/tab APIs and accepts only `--output NEW-FILE`. Until that
producer has compiled and passed a disposable-profile test, use these commands
only with synthetic exporters.

## Source-local scheduler

Copy `scripts/tabs/tab-ops.conf.example` outside the repository, make it mode
`0600`, and set one source device/profile namespace. Configuration version 2
accepts only `d`, `da`, or `oneplus`; `key_id` must be the corresponding
`DEVICE-tabs-v1`. One configuration owns one store. The store and operation
state must remain outside the browser profile.

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

`run-once` takes a nonblocking namespace lock, gives the exporter a new mode
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

For d and da, `scripts/tabs/install-linux-tab-scheduler.sh install CONFIG`
installs the scripts, config, and constrained systemd user service/timer but
leaves the timer disabled. `enable` first runs the full tool/exporter/two-host
preflight and only then enables it. The timer runs one full cycle every 15
minutes; failed conditions skip the service rather than running a partial
backup.

Oneplus/Android has no running systemd manager: the current Arch chroot has a
`systemctl` binary but reports `offline`. `scripts/tabs/oneplus-tab-cycle-service.sh`
is therefore the disabled source template for the existing Magisk `service.d`
mechanism. If it is eventually deployed, it exits without starting unless the
config, `helium-tabs`, exporter, age, and jq already exist inside the chroot.
No installer or service was deployed or enabled by this repository change. Do
not create a second profile reader to work around the exporter.

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
`helium-tabs`, and uses its atomic disposable restore. Nothing in this layer
can promote a restore into a live browser profile. The wrapper must run on the
snapshot's source device and cannot open or merge the result into another
device's browser.

If a local generation itself is corrupt, preserve it explicitly before
unblocking retention:

```sh
helium-tabs quarantine --store "$snapshot_store" \
  --generation GENERATION --reason checksum-mismatch
```

This atomically moves the entire generation under the store's `quarantine/`
directory. It never deletes bytes and it never happens automatically.

## Live readiness audit (2026-07-21)

- lm has about 18.8 GiB free. `/srv/nas` is mounted read-write on a separate
  ext4 disk with about 1.3 TiB free.
- chromiumer has 105.7 GiB available, but it is a build executor and is not a
  tab-backup destination.
- da and d are online in Tailscale. Dedicated BatchMode SSH from lm now works
  for da; d still rejects lm's available keys, so the example's second copy is
  not deployable yet.
- da has about 208 GiB free, a running systemd user manager, `jq`, `rsync`, and
  the standard integrity tools, but no `age`/`age-keygen` yet.
- oneplus is online and reachable through authorized ADB, with roughly 410 GiB
  free under `/data`. Port 22 is closed. Its Android shell lacks both `age` and
  `jq`; its Arch chroot has `jq`, `rsync`, and the integrity tools but lacks
  `age` and has no running systemd manager. No scheduler or backup service
  should be deployed until age and two noninteractive destination routes are
  present.

These are deployment gates, not reasons to weaken destination independence or
copy unencrypted tab data through an intermediary.
