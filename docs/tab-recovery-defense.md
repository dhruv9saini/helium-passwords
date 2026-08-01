# Device-local tab recovery defense

Tabs never enter Helium Sync transport. Recovery is device-namespaced and a
copy from one device is never applied to, merged into, or automatically opened
by another device. Multiple destinations containing the same generation are
replicas of one mechanism, not additional mechanisms.

## Three independent mechanisms

| Mechanism | Producer and format | Recovery path | Current evidence |
| --- | --- | --- | --- |
| Chromium native recovery | Chromium SessionService clean/crash checkpoints in its native profile format | Chromium normal same-device recovery | Normal launch preserves Chromium recovery state; disposable clean/crash and restart drills require built artifacts |
| Neutral topology generations | `HeliumTabSnapshotBridge` schema-2 JSON, committed by `helium-tabs` | Explicit native topology importer in a marked disposable profile | Export/store/retention/prepare/import source and synthetic checks complete; pinned compile plus first/second-launch device drills remain |
| Compressed full-profile generations | A stopped-profile tar stream compressed directly to two private off-device stores | Restore a complete profile only into a new marked disposable root | Source and synthetic two-copy restore/retention/corruption drills complete; source-device provisioning remains |

The mechanisms do not share one exporter, format, restore command, schedule, or
retention policy:

- Chromium owns its SessionService checkpoints and recovery UI. No Helium
  exporter, backup timer, recovery key, or network destination participates.
- The neutral bridge reads only Chromium tab/window APIs and atomically
  refreshes one schema-2 JSON file outside the profile. `helium-tabs` owns the
  immutable generation store and its hourly/daily/weekly retention.
- The full-profile producer runs only while the browser is stopped and streams
  the complete profile through its own configuration, receipt,
  retention, and restore tool. It does not consume neutral JSON or
  `helium-tabs`.

A failure in one mechanism must not mutate or retire either sibling. Native
recovery remains available when an exporter, private route, or off-device
store fails. A malformed neutral generation leaves the previous valid neutral
generation and the stopped full-profile archives untouched. Full-profile
retention refuses destination disagreement and cannot delete Chromium session
files or neutral generations.

## Neutral topology generations

The profile-local `helium-sync/tab_snapshot_export_path` names a dedicated file
outside the profile. The native bridge refreshes it every five minutes with
create-new, fsync, and atomic rename. The source-local adapter rejects a
missing, empty, oversized, symlinked, wrong-owner, non-0600, future-dated,
stale, or replaced export.

One source-local scheduler then:

1. commits and validates an immutable `helium-tabs` generation;
2. packages it as a checksum-bound archive;
3. verifies copies on the lm NAS and the required peer host;
4. records a content- and topology-bound health proof; and
5. applies retention only when the selected generation has both verified
   off-device copies.

Restore is always explicit. `validate-restore` checks the generation before
`prepare-browser-profile` may create a new `drill-*` child below an exact
mode-0700 marked root. Preparation writes empty Preferences and never launches
Chromium or configures startup pages. The disposable-only native importer must
read back exact supported topology, record its terminal receipt, and survive a
second launch without the import switch.

See [tab-backup-operations.md](tab-backup-operations.md) and
[tab-snapshots.md](tab-snapshots.md) for commands.

## Compressed full-profile generations

The full-profile producer refuses an active profile, streams without a
source-local archive, and publishes only after the
source fingerprint and both destination receipts agree. Restore accepts one
verified off-device copy and only creates a nonexistent child of a marked
mode-0700 disposable root. It never replaces a live profile or launches a
browser.

This mechanism has its own configuration and retention state. Do not reuse
the neutral snapshot retention state. See
[profile-deployment.md](profile-deployment.md).

## Physical topology

Every source device owns its schedules; lm is not the only scheduler or key
authority. The two off-device locations are replicas within the neutral or
full-profile mechanism:

| Source | Off-device replica 1 | Off-device replica 2 |
| --- | --- | --- |
| d | lm NAS | da local storage |
| da | lm NAS | d local storage |
| oneplus | lm NAS | da local storage |

Namespaces include source device, profile, and mechanism. SSH transport keys
stay on their source devices and out of Git. Local Chromium
recovery and local neutral generations are additional local layers; neither
counts as an off-device replica.

## Health and production gate

`tab-recovery-health.sh STATUS_ROOT SOURCE_DEVICE PROFILE` reports exactly:

```text
chromium-native-session.status
neutral-topology.status
full-profile.status
```

Each proof is a strict private `key=value` file. Missing, stale, future,
wrong-device, symlinked, group-readable, malformed, or duplicated fields make
only that mechanism unhealthy. Freshness ceilings are 30 days for a tested
native clean/crash recovery, 30 minutes for neutral topology, and seven days
for a full-profile generation. Backup replicas never receive separate health
records. `tab-runtime-proof.mjs` performs the disposable desktop and admitted
Android `.test` CDP drills, and `tab-proof-status.mjs` authenticates their strict evidence before
atomically emitting these files. Neutral and full-profile health each require
two authenticated runs from different source destinations. See
[tab-runtime-proof.md](tab-runtime-proof.md).

Before personal enrollment, every source device must independently pass:

1. Chromium clean-exit, crash, and second-restart recovery;
2. neutral restore from each off-device replica through a first import and
   second restart in a disposable profile; and
3. full-profile restore from each off-device replica into disposable state.

Fault injection corrupts one source, newest generation, retention plan,
recipient, or destination at a time. Acceptance fails if one injected fault
damages a sibling mechanism or if any restore tool targets a live profile.
The orchestration and evidence path supports desktop plus the exact
checksum-admitted `computer.helium.sync.test` Android package. Android stages
only round-trip-verified synthetic drill profiles below real, fully resolved
package paths and binds the exact local marker or restore receipt before any
admitted removal. It launches through the sole disposable boundary and binds
clean CDP close or same-UID crash evidence to the exact APK and sandbox path.
Runtime health requires one Android package, APK hash, and source-archive
generation across every mechanism and remains closed until that real returned
APK passes all three mechanisms and both restore destinations.
