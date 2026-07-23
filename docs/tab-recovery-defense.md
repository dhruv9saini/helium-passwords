# Device-local tab recovery defense

Tabs never enter Helium Sync transport. Recovery is device-namespaced and a
copy from one device is never applied to, merged into, or automatically opened
by another device. Replicas do not count as different recovery mechanisms.

## Five independent mechanisms

| Mechanism | Producer and format | Cadence and retention | Recovery path | Current evidence |
| --- | --- | --- | --- | --- |
| Chromium native recovery | Chromium session service; native `Sessions` command files | Browser-owned clean/crash checkpoints | Chromium normal same-device recovery | Existing browser behavior; disposable clean/crash and monthly drills still require built artifacts |
| Neutral topology generations | `HeliumTabSnapshotBridge`; schema-2 JSON | Five-minute export, checked generations, hourly/daily/weekly retention | Explicit native topology importer in a marked disposable profile | Export/store/prepare/import source and synthetic checks complete; pinned compile, first/second launch and device drills open |
| Full-profile generations | stopped-profile streaming archive | At least before installation and every seven days; independent profile retention | Restore a complete profile only into a marked disposable root | Source and synthetic two-copy drills complete; personal device provisioning open |
| Native Sessions capsule | `helium-session-capsule`; byte-exact stopped-only Chromium `Session_*` and `Tabs_*` files | Opportunistic only after a verified browser stop; keep newest eight plus protected/invalid; drill within 30 days | New `drill-native-*` user-data directory, then explicit `--restore-last-session` | Separate package/CLI, guard, pinned v150 cleartext parser, checksums, retention, quarantine and unopened restore tests complete; launcher guard, pinned parser comparison and browser drill open |
| Event journal | `HeliumTabJournalBridge`; direct tab/navigation observers plus two-second topology reconciliation writing append-only SQLite epochs with an SHA-256 chain | Event-debounced plus five-minute heartbeat; 15-minute online backup generations; newest 96 plus protected/invalid; drill within 30 days | Standalone escaped HTML/URL catalog in a marked `drill-journal-*` directory; never a neutral import | Native producer, independent SQLite online-backup store, hash-chain validation, retention and catalog restore tests complete; pinned compile and source-device schedule/keys open |

The last two mechanisms do not call the neutral exporter and do not read or
derive from its JSON. The capsule intentionally reads Chromium's native format
only while the browser lifetime guard is exclusively held. The journal
observes live tab and navigation events and never reads Chromium `Sessions`.
A bug in the neutral JSON transform therefore does not corrupt either source.
A bug in the raw command parser does not alter the journal catalog.

## Native Sessions capsule

Every normal browser launch must eventually be supervised by:

```sh
helium-session-capsule guard-run \
  --guard /run/user/UID/helium-default.session.guard -- \
  /path/to/helium --user-data-dir=/path/to/profile
```

The browser holds a shared lock for its complete lifetime. Capture requests an
exclusive nonblocking lock and therefore refuses while any supervised browser
process is alive. A timer may attempt capture after shutdown, but it must never
stop the browser.

```sh
helium-session-capsule capture \
  --store /var/lib/helium-native-session-capsules/default \
  --profile-root /path/to/user-data \
  --guard /run/user/UID/helium-default.session.guard \
  --device d --profile default
helium-session-capsule validate --store STORE --generation GENERATION
helium-session-capsule retention-plan --store STORE
helium-session-capsule retention-apply --store STORE
```

The parser is pinned to Chromium
`24b04c927b23c39cf9c5227cc8dc6f64a744c8e9`. It validates the `SSNS`
signature, cleartext format version 3, every command frame, and at least one
complete initial-state marker in both the `Session_*` and `Tabs_*` families.
Pinned Chromium also supports OS-crypt format version 5. The capsule rejects
version 5 because copying ciphertext without the source device's OS key would
not be an independently recoverable mechanism. A built target emitting version
5 therefore keeps the other four mechanisms but blocks counting the raw
capsule until a separately recoverable key design and matching Chromium parser
drill exist.

Restore never targets an existing directory and never launches Chromium:

```sh
install -d -m0700 /secure/native-session-drills
printf '%s\n' helium-native-session-disposable-root-v1 \
  > /secure/native-session-drills/.helium-native-session-disposable-root-v1
chmod 600 /secure/native-session-drills/.helium-native-session-disposable-root-v1
helium-session-capsule restore --store STORE --generation GENERATION \
  --disposable-root /secure/native-session-drills \
  --profile drill-native-d
helium-session-capsule validate-restore \
  --destination /secure/native-session-drills/drill-native-d
```

Only after validation may a disposable artifact run with the printed explicit
`--restore-last-session` command. Runtime acceptance must compare the result
with Chromium's pinned session parser, restart it, and retain the capsule if
that drill fails.

## Event journal

`tab_journal_root` in `<profile>/helium-sync/` names an existing absolute
mode-0700 leaf outside—and not above—the browser profile. Before launch, admit
that leaf explicitly:

```sh
install -d -m0700 /home/d/.local/share/helium-tab-journal/default
printf 'helium-tab-journal-root-v1\n' \
  > /home/d/.local/share/helium-tab-journal/default/.helium-tab-journal-root-v1
chmod 600 \
  /home/d/.local/share/helium-tab-journal/default/.helium-tab-journal-root-v1
```

The bridge will not create, chmod, or use an unmarked root, a symlink, or an
ancestor of the profile. It starts before enrollment and therefore does not
depend on a server URL, token, or content key. It discovers normal windows,
directly observes tab add/remove/move/activation and WebContents page/title
changes, and reconciles the full topology every two seconds to catch
pin/group/visual changes for which the public observer has no dedicated
callback. Identical topology is not appended twice. Checkpoints preserve every
valid absolute browser URL scheme plus group membership, title, color, and
collapsed state. A transient incomplete browser model defers one checkpoint
instead of permanently disabling the journal; reconciliation retries it.

Each epoch begins with `initial-checkpoint`. SQLite uses WAL and
`synchronous=FULL`; every row contains an int64 sequence, previous hash, and
hash over the exact epoch/sequence/time/kind/payload tuple. Graceful shutdown
adds `final-checkpoint`, checkpoints SQLite, and closes the epoch under
`closed/`. An interrupted `active.sqlite` resumes its existing hash chain and
immediately restarts the heartbeat. At 100,000 records, the bridge durably
closes the epoch and creates a new independently chained epoch; the bound
cannot permanently brick the producer. Append or schema failure stops this
mechanism without modifying other recovery sources. External capture refuses
to mint a fresh generation unless the newest native checkpoint is no more
than ten minutes old.

The independent store uses SQLite's online backup API through the standard
`sqlite3` command, so it never copies live WAL files:

```sh
helium-tab-journal capture \
  --journal-root /var/lib/helium-tab-journal/default \
  --store /var/lib/helium-tab-journal-generations/default \
  --device d --profile default
helium-tab-journal validate --store STORE --generation GENERATION
helium-tab-journal retention-plan --store STORE
helium-tab-journal retention-apply --store STORE
```

Recovery is deliberately independent from the neutral importer:

```sh
install -d -m0700 /secure/journal-drills
printf '%s\n' helium-tab-journal-disposable-root-v1 \
  > /secure/journal-drills/.helium-tab-journal-disposable-root-v1
chmod 600 /secure/journal-drills/.helium-tab-journal-disposable-root-v1
helium-tab-journal restore-catalog --store STORE --generation GENERATION \
  --disposable-root /secure/journal-drills \
  --profile drill-journal-d
helium-tab-journal validate-catalog \
  --destination /secure/journal-drills/drill-journal-d
```

The output is an escaped, checksum-bound HTML link catalog. It does not contain
scripts, launch a browser, create a Chromium profile, or auto-open any tab.

## Independent encrypted copy commands

The new mechanisms use different programs, formats, configs, encryption
recipients, status roots, and timers:

```sh
scripts/tabs/native-session-capsule-backup.sh cycle /private/capsule.conf
scripts/tabs/native-session-capsule-backup.sh status /private/capsule.conf
scripts/tabs/native-session-capsule-backup.sh restore-drill \
  /private/capsule.conf a GENERATION /marked/root drill-native-proof

scripts/tabs/tab-journal-backup.sh cycle /private/journal.conf
scripts/tabs/tab-journal-backup.sh status /private/journal.conf
scripts/tabs/tab-journal-backup.sh restore-drill \
  /private/journal.conf b GENERATION /marked/root drill-journal-proof
```

Both parsers reject unknown config keys, unsafe paths, a wrong source hostname,
the wrong lm-plus-peer topology, unpinned SSH host keys, and a system-disk
directory pretending to be the NAS. Each cycle creates different ciphertext
for the NAS and peer recovery identity, copies a SHA-256 sidecar, verifies the
remote host/filesystem/hash/size before publishing healthy state, then removes
only the successful local ciphertext spool. Raw capsules use two distinct
exact GPG fingerprints. Journals use two distinct CMS certificates and
authenticated AES-256-GCM. Recovery private keys remain outside the source
device and repositories; a restore drill temporarily supplies only the
selected destination identity.

The checked-in user units are
`helium-native-session-capsule@.service/.timer` (six-hour stopped-only
attempts) and `helium-tab-journal-backup@.service/.timer` (15-minute online
copies). They are source-device units, not lm scheduling. They are not
installed or enabled by this change. OnePlus still requires a separately
tested device-local Magisk schedule and native lifetime guard before either
path can be counted healthy there.

## Failure domains and production gate

Each source device schedules its own work. lm must not be the only scheduler or
key authority. Every mechanism's ciphertext namespace, encryption recipients,
retention and restore receipt are distinct. Recipient material is never stored
with ciphertext or in Git. The required physical topology is:

| Source | Off-device copy 1 | Off-device copy 2 |
| --- | --- | --- |
| d | lm NAS | da local storage |
| da | lm NAS | d local storage |
| oneplus | lm NAS | da local storage |

The same destination pair may hold replicas of several mechanisms, but every
path includes both the source device and mechanism name. Raw-capsule recipient
sets must not overlap neutral, journal, or full-profile recipient sets.
Journal recipients must also be unique. Loss of a source-device key must not
remove both recovery identities for any one mechanism.

Local cleartext generation retention is automatic and validation-gated. The
copy wrappers deliberately do not delete remote ciphertext generations:
off-device pruning needs a separate capacity policy that proves both
destinations retain the required hourly/daily/weekly and protected restore
points before deleting any exact namespace. Until that policy is implemented
and tested, remote growth is conservative and production capacity monitoring
is an explicit deployment gate.

Production scheduling remains gated until those dedicated keys/routes exist.
Required freshness is: neutral export at most 420 seconds old and remote copy
at most 30 minutes; profile generation at most seven days; stopped native
capsule at most 24 hours after a verified stop; journal heartbeat at most five
minutes and remote generation at most 15 minutes. All four independently
managed backup mechanisms require a disposable restore from both destinations
within 30 days.

`tab-recovery-health.sh STATUS_ROOT SOURCE_DEVICE PROFILE` is the single
five-path health surface. `STATUS_ROOT` contains exactly one private,
source-owned proof named after each row:

```text
chromium-native-session.status
neutral-topology.status
full-profile.status
native-session-capsule.status
tab-event-journal.status
```

Each proof is a strict `key=value` file with `version=1`, its filename's
`mechanism`, `state=healthy`, the exact `source_device` and `profile`,
`completed_unix`, and either `generation` or `evidence`. Unknown, duplicated,
empty, future, stale, wrong-device, group-readable, symlinked, or missing
proofs make only that mechanism unhealthy. The report always contains exactly
five distinct mechanism records and exits nonzero if any one is unhealthy.
Freshness ceilings are 30 days for a tested Chromium native clean/crash
recovery, 30 minutes for neutral topology, seven days for a full-profile
generation, 24 hours for a stopped native capsule, and 15 minutes for the
journal copy. Backup replicas never receive their own record.

Fault injection marks only the affected mechanism red: corrupt one exporter,
scheduler, recipient key, destination, newest generation, and retention plan
at a time. Acceptance fails if one injected fault invalidates another
mechanism's source or restore tool. No production profile may be enrolled
until five source-device restore paths—including the browser's native
clean/crash path—have passed on that device.
