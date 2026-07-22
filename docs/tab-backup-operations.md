# Durable Tab Snapshot Operations

This layer schedules and copies the neutral `helium-tabs` snapshot model. It
does not read Chromium `Sessions`, `Login Data`, cookies, a browser profile, or
the syncstore. The missing browser integration is a narrow exporter that calls
Chromium's session/tab APIs and accepts only `--output NEW-FILE`. Until that
producer has compiled and passed a disposable-profile test, use these commands
only with synthetic exporters.

## Source-local scheduler

Copy `scripts/tabs/tab-ops.conf.example` outside the repository, make it mode
`0600`, and set one source device/profile namespace. One configuration owns
one store. The store and operation state must remain outside the browser
profile.

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
match the local ciphertext and manifest hashes.

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
copies that exact file to exactly two distinct destination hosts. It refuses
fewer than two distinct, syntactically valid age/SSH recipients, so losing one
recovery identity does not make every snapshot unreadable. Private identities
are needed only for an explicit restore: hold them on separate recovery media
or recovery workstations, not on the source device, lm/NAS destination, d
destination, or in the repository. `age_identity` may point to a path that is
intentionally absent during capture/backup and made available only for a
restore drill.

Destination data is namespaced as:

```text
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE/generations/GENERATION.tar.age
DESTINATION_ROOT/SOURCE_DEVICE/PROFILE/generations/GENERATION.backup.env
```

The clear manifest contains only source/profile IDs, generation, ciphertext
hash/size, snapshot-manifest hash, and time. URLs and tab titles exist only in
the age ciphertext. Each transfer keeps a configurable free-space reserve,
lands in `incoming`, verifies SHA-256, and then renames into place. Existing
bytes are never overwritten. A collision or mismatch fails until it is moved
to quarantine explicitly.

```sh
scripts/tabs/tab-backup.sh backup "$config"
scripts/tabs/tab-backup.sh status "$config"
scripts/tabs/tab-backup.sh quarantine "$config" d-copy GENERATION bad-hash
scripts/tabs/tab-backup.sh quarantine "$config" local-spool GENERATION bad-hash
```

The configuration parser never evaluates shell. It requires exactly two
different destination host IDs, and rejects either host when it equals the
source device. Therefore a da configuration cannot count da as either backup;
the example uses lm/NAS and d. Two directories on lm also cannot masquerade as
two hosts.

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
the exact revalidated local snapshot retention plan. It refuses the entire
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
can promote a restore into a live browser profile.

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
