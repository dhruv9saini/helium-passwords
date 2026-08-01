# Disposable tab runtime proofs

This gate drives one explicitly supplied, pinned desktop Helium executable or
prepared Android Sync `.test` APK through the three device-local tab recovery
mechanisms. It never discovers a browser, accepts a normal profile, changes a
launcher, opens another device's snapshot automatically, or communicates with
the Helium Sync service.

Desktop uses Chromium's DevTools pipe. Android uses only the exact test
package's fixed localabstract socket through a short-lived loopback ADB
forward; it never opens a device TCP listener. CDP is limited to synthetic tab
creation, lifecycle control, and read-only window/URL topology observation. It
does not read or mutate cookies, passwords, storage, or personal profile data.
The neutral import itself remains the native
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
device, outside repositories and backup archives, with mode 0600.
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

Every command requires the exact artifact hash, package identity, logical
source device/profile, and explicit display mode. Desktop uses
`--package-id desktop`; `headless` is useful for automation, and the final gate
must also run `headed` when validating normal desktop window behavior.

The only recognized Android identity is `computer.helium.sync.test`, with
`--source-device oneplus` and `--display-mode device`. `--browser` is the exact
prepared `Browser-test.apk`; `--acceptance-dir` and `--adb-serial` are also
required. The runner validates the local APK metadata before device access,
then `android-tab-profile.sh` revalidates the full prepared inventory and the
installed monolithic APK before touching a synthetic sandbox path. Production
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
creates them through CDP across two windows in the new profile, closes cleanly,
verifies a clean restart, sends SIGKILL, verifies crash recovery, and verifies
one more clean restart. Each readback must contain exactly the expected page
targets and window partition. It records the pinned executable hash and
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
archive hash, backup-manifest hash, generation, namespace, and restored
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
different destinations, and bind the same session and archive:

```sh
node scripts/tabs/tab-proof-status.mjs emit \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key \
  --status-root /secure/helium-tab-proof/status \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-nas \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-neutral-da
```

## 3. Compressed full-profile restore

Restore the same stopped compressed generation from each destination into two
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
the same archive generation:

```sh
node scripts/tabs/tab-proof-status.mjs emit \
  --key /secure/helium-tab-proof/evidence/runtime-proof.key \
  --status-root /secure/helium-tab-proof/status \
  --source-device d --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-nas \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-d-full-da
```

## Android app-sandbox execution

Install the prepared Sync `.test` APK only through the guarded boundary. The
package must be fresh: native staging refuses an existing `app_chrome` tree.
The native run creates that synthetic tree, and each launch temporarily owns
and restores Android's two Chromium command-line files plus debug-app selection.
In the single fleet E2E, Android freshness comes from the preceding
`password-sync` to `tab-recovery` receipt produced by the separate, `.test`-only
[`reset-disposable-package.sh`](../scripts/android-acceptance/reset-disposable-package.sh).
The tab adapter itself still never clears or uninstalls a package.

```sh
acceptance=/absolute/prepared-sync-acceptance
apk=$acceptance/Browser-test.apk
apk_sha256=$(sha256sum "$apk" | awk '{print $1}')
serial=ONEPLUS_ADB_SERIAL

scripts/android-media/disposable-browser.sh install "$acceptance" "$serial"

node scripts/tabs/tab-runtime-proof.mjs native \
  --browser "$apk" --browser-sha256 "$apk_sha256" \
  --acceptance-dir "$acceptance" --adb-serial "$serial" \
  --package-id computer.helium.sync.test --display-mode device \
  --profile-dir /secure/helium-tab-proof/native/drill-oneplus-native \
  --source-device oneplus --profile default \
  --evidence-dir /secure/helium-tab-proof/evidence/proof-oneplus-native \
  --signing-key /secure/helium-tab-proof/evidence/runtime-proof.key
```

The runner exposes the package's fixed localabstract DevTools socket through a
new exact ADB forward for each launch. It verifies CDP `Android-Package`, the
Chromium source revision, installed APK hash, effective socket, exact
user-data-dir, and the one admitted restore mode. `Browser.close` plus main-PID
exit is a clean step. The crash step sends `SIGKILL` only through `run-as` to
the exact test-package main PID. Each forward is removed before the next step.

After the native proof, stream the stopped synthetic `app_chrome` tree through
the existing two-destination Android producer. The config must name the test
package's exact resolved `<dataDir>/app_chrome`; selecting the `.test` package
does not weaken any topology, receipt, or restore rule.

```sh
ANDROID_SERIAL="$serial" CHROMIUM_ANDROID_PACKAGE=computer.helium.sync.test \
  scripts/android-local/backup-android-chromium-profile.sh \
    /secure/oneplus-test-app-profile.conf
```

Restore that one generation independently from `nas-on-lm` and `da-copy` into
new marked local `drill-*` roots. Run the full-profile command shown above for
each restore, replacing the common desktop arguments with the Android
arguments from the native command. Neutral topology likewise requires two
independent current-orchestrator restores, two prepared browser profiles, and
two Android neutral runs with `--helium-tabs` and the matching source receipt.
The adapter round-trips every prepared profile through the package sandbox
before launch. After first neutral import it fetches only the terminal marker
and native receipt into the retained local prepared profile, where
`helium-tabs validate-browser-state` independently authenticates the immutable
source binding before the second launch.

Android runtime evidence adds acceptance/source commits, APK/version identity,
ADB serial, fixed socket, sandbox path, staged profile fingerprint, exact local
marker-or-restore-receipt hash, adapter receipt hash, and the exact
runtime/profile-adapter/browser-boundary source hashes. Staging and removal
require the package parent and profile to resolve to their literal real paths;
removal also requires the device marker or receipt to match the retained local
binding byte for byte. Health emission still has exactly three mechanisms,
requires one platform/package/APK/source generation across all three, and keeps
the two distinct-source requirements for neutral and full-profile. Remove only
the exact marked synthetic paths with `android-tab-profile.sh remove` after all
backup, fault-injection, evidence, and status gates finish. The adapter never
clears or uninstalls a package.

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

Android health still requires real current-artifact execution: one native
clean/crash/second-restart proof plus two neutral and two full-profile proofs
from the independently restored destinations. Source presence or a single
package launch cannot emit a healthy status.

The terminal fleet gate in
[android-full-e2e-acceptance.md](android-full-e2e-acceptance.md) consumes the
five authenticated proofs and three emitted status receipts independently for
d and da, plus the corresponding Android proofs and status receipts. For each
desktop it also binds a previous-neutral-generation fallback, an independent
full-profile replica fallback, their four rejection/quarantine receipts, and the schema-3
full-profile backup receipt. A local status, unverified evidence directory, or
single-replica restore cannot satisfy that terminal receipt.
