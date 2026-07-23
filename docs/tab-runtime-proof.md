# Disposable tab runtime proofs

This gate drives one explicitly supplied, pinned desktop Helium executable
through the three device-local tab recovery mechanisms. It never discovers a
browser, accepts a normal profile, changes a launcher, opens another device's
snapshot automatically, or communicates with the Helium Sync service.

The runtime uses Chromium's DevTools pipe, not a listening debugging port. CDP
is limited to synthetic tab creation and read-only window/URL topology
observation. It does not read or mutate cookies, passwords, storage, or
personal profile data. The neutral import itself remains the native
`--helium-restore-disposable-tabs` bridge.

## Local evidence authority

Create new private roots outside Git. The parent of each new root must already
be a mode-0700 directory:

```sh
node scripts/tabs/tab-proof-status.mjs init-evidence-root \
  --evidence-root /secure/helium-tab-proof/evidence
node scripts/tabs/tab-proof-status.mjs init-key \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key
node scripts/tabs/tab-proof-status.mjs init-status-root \
  --status-root /secure/helium-tab-proof/status
```

The 32-byte local key authenticates successful evidence. Keep it on the source
device, outside repositories and backup ciphertext stores, with mode 0600.
The runner never logs it. Evidence directories are immutable `proof-*`
children containing only an exact marker, `evidence.json`, and
`evidence.hmac`.

The status adapter verifies the HMAC and strict evidence schema before it can
atomically replace a health file. Hand-written status files are not acceptable
runtime proof.

## Common artifact arguments

Calculate the returned artifact's browser hash and use the exact extracted
executable:

```sh
browser=/absolute/pinned-artifact/helium
browser_sha256=$(sha256sum "$browser" | awk '{print $1}')
```

Every command requires `--package-id desktop`, the exact hash, a logical
source device and profile, and an explicit display mode. `headless` is useful
for automation. Repeat the final gate in `headed` mode when validating normal
desktop window behavior.

The only recognized Android identity is `computer.helium.sync.test`. It
currently fails before reading a binary, package, or profile because a safe
Android app-sandbox CDP adapter is not implemented. Production
`computer.helium.sync` and every other package identity are rejected.

## 1. Chromium native recovery

Create a new mode-0700 root with the exact marker. The `drill-*` profile must
not exist:

```sh
install -d -m0700 /secure/helium-tab-proof/native
(umask 077; printf 'helium-tab-runtime-proof-root-v1\n' \
  >/secure/helium-tab-proof/native/.helium-tab-runtime-proof-root-v1)

node scripts/tabs/tab-runtime-proof.mjs native \
  --browser "$browser" --browser-sha256 "$browser_sha256" \
  --package-id desktop --display-mode headless \
  --profile-dir /secure/helium-tab-proof/native/drill-d-native \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-native \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key
```

The runner serves three inert pages on an ephemeral loopback HTTP origin,
creates them through CDP in the new profile, closes cleanly, verifies a clean
restart, sends SIGKILL, verifies crash recovery, and verifies one more clean
restart. Each readback must contain exactly the expected page targets and
window partition. It records the pinned executable hash and
`Browser.getVersion` result.

Emit native health only from that authenticated proof:

```sh
node scripts/tabs/tab-proof-status.mjs emit \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key \
  --status-root /secure/helium-tab-proof/status \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-native
```

## 2. Neutral topology restore

Restore the same generation independently from both configured off-device
destinations. `tab-backup.sh restore-to-disposable` now publishes a private
sibling receipt named
`RESTORE.helium-tab-offdevice-source.env`. It binds the destination ID,
ciphertext hash, backup-manifest hash, generation, namespace, and restored
session hash. The runtime refuses an operator-supplied destination label.

For each destination, prepare a different marked `drill-*` browser profile:

```sh
scripts/tabs/tab-backup.sh restore-to-disposable "$config" \
  nas-on-lm "$generation" /secure/restores/d-nas
scripts/tabs/tab-backup.sh restore-to-disposable "$config" \
  da-copy "$generation" /secure/restores/d-da

helium-tabs prepare-browser-profile \
  --restore /secure/restores/d-nas \
  --disposable-root /secure/neutral-browser-roots/nas \
  --profile drill-d-nas
helium-tabs prepare-browser-profile \
  --restore /secure/restores/d-da \
  --disposable-root /secure/neutral-browser-roots/da \
  --profile drill-d-da
```

The two disposable roots must independently satisfy the exact marker and
mode rules in [tab-snapshots.md](tab-snapshots.md). Run the first native import
and second start for each:

```sh
node scripts/tabs/tab-runtime-proof.mjs neutral \
  --browser "$browser" --browser-sha256 "$browser_sha256" \
  --package-id desktop --display-mode headless \
  --profile-dir /secure/neutral-browser-roots/nas/drill-d-nas \
  --source-device d --profile default \
  --helium-tabs /absolute/bin/helium-tabs \
  --source-receipt \
    /secure/restores/d-nas.helium-tab-offdevice-source.env \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-nas \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key

node scripts/tabs/tab-runtime-proof.mjs neutral \
  --browser "$browser" --browser-sha256 "$browser_sha256" \
  --package-id desktop --display-mode headless \
  --profile-dir /secure/neutral-browser-roots/da/drill-d-da \
  --source-device d --profile default \
  --helium-tabs /absolute/bin/helium-tabs \
  --source-receipt \
    /secure/restores/d-da.helium-tab-offdevice-source.env \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-da \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key
```

The first start uses the explicit native importer. The runner requires a
terminal applied receipt from `helium-tabs validate-browser-state`, closes the
browser, starts the same profile without the import switch, and compares the
CDP window/URL topology again.

One restore cannot emit health. Both evidence files must authenticate, name
different destinations, and bind the same session and ciphertext:

```sh
node scripts/tabs/tab-proof-status.mjs emit \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key \
  --status-root /secure/helium-tab-proof/status \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-nas \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-da
```

## 3. Encrypted full-profile restore

Restore the same stopped encrypted generation from each destination into two
different new `drill-*` children of a marked full-profile restore root. Each
restored directory already carries the source-authenticated
`.helium-profile-restore-receipt.env`.

Use the matching native proof as the synthetic expected topology. The runner
verifies that proof's HMAC, source namespace, and browser hash:

```sh
node scripts/tabs/tab-runtime-proof.mjs full-profile \
  --browser "$browser" --browser-sha256 "$browser_sha256" \
  --package-id desktop --display-mode headless \
  --profile-dir /secure/profile-drills/drill-d-nas \
  --source-device d --profile default \
  --expected-evidence \
    /secure/helium-tab-proof/evidence/proof-d-native \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-nas \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key

node scripts/tabs/tab-runtime-proof.mjs full-profile \
  --browser "$browser" --browser-sha256 "$browser_sha256" \
  --package-id desktop --display-mode headless \
  --profile-dir /secure/profile-drills/drill-d-da \
  --source-device d --profile default \
  --expected-evidence \
    /secure/helium-tab-proof/evidence/proof-d-native \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-da \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key
```

Both first and second starts must restore the exact CDP window/URL topology.
The status adapter additionally requires different source destinations and
the same ciphertext generation:

```sh
node scripts/tabs/tab-proof-status.mjs emit \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key \
  --status-root /secure/helium-tab-proof/status \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-nas \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-da
```

## Final gate and evidence limits

```sh
scripts/tabs/tab-recovery-health.sh \
  /secure/helium-tab-proof/status d default
```

The report remains exactly three mechanisms. Its freshness timestamp is the
oldest proof in each required evidence set.

CDP exposes page targets, current URLs, and their browser-window identities;
it does not expose complete tab-strip order, pinned state, group visuals, or
back/forward entries. The neutral native import receipt separately proves
those supported fields through Chromium's tab APIs before CDP verifies first-
and second-start persistence. Native and full-profile CDP evidence therefore
claims exactly `cdp-window-url-multiset-v1`, not a stronger topology.

Android still needs an adapter that installs and starts only the admitted
`.test` APK, uses its package-specific DevTools socket, reads only its
disposable app sandbox, preserves any device command-line state, and performs
the equivalent first/second-start and SIGKILL drills. Until that adapter and
root/sandbox boundary pass tests, no Android health status can be emitted by
this workflow.
