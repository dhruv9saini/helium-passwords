# Nine independent recovery paths

Helium counts one mechanism only when its producer, stored representation, and
restore path are materially different. A second copy of the same archive is a
replica, not another mechanism. The fixed inventory is therefore exactly
three password mechanisms, three cookie mechanisms, and three tab mechanisms.
No password path uses Bitwarden, an extension vault, `passwordsPrivate`, CDP,
or direct access to Chromium's `Login Data` database.

This document defines the runtime gate. Source presence is not a pass. Every
row needs a restore receipt from the returned browser artifact on its named
disposable profile before fleet completion can be issued.

| ID | Data | Producer and representation | Restore path | Schedule and retention | Exact private location / failure domain |
| --- | --- | --- | --- | --- | --- |
| P1 | Passwords | The Chromium `PasswordStoreInterface` sync bridge publishes complete `PasswordSpecificsData` records into the append-only Tailnet server journal and its verified latest-state snapshots. | A newly enrolled disposable browser pulls the journal through the authenticated revision protocol; the bridge writes through `PasswordStoreInterface`, restarts, and proves native fill/readback. | Continuous on mutation and every 30 seconds; the stopped server archive job captures immutable journal/snapshot generations. No generation is silently purged. | lm's separately mounted NAS, `/srv/nas/helium-sync-server-disposable`; the server process and its archive/restore drill are the authority failure domain. |
| P2 | Passwords | A stopped, checksum-stable compressed archive of the complete Chromium profile. Password bytes remain in Chromium's own profile representation. | Verify one archive generation, extract only into a new marked `drill-*` directory, launch that whole disposable profile, and prove native fill after two starts. | Before every install/enrollment/profile mutation and on the deployed profile-backup timer; keep at least three admitted generations and quarantine corrupt generations. | `/srv/nas/helium-profile-backups/DEVICE/default` on lm NAS plus `/home/d/.local/share/helium-profile-backups/DEVICE/default` on the fixed peer. The pair is one mechanism with two replicas. |
| P3 | Passwords | Chromium independently reads `PasswordStoreInterface` every two minutes and on store changes, serializes canonical password specifics into `passwords.current.json`, and atomically replaces a mode-0600 file outside the profile. | Restore a selected off-device neutral generation, pass its password snapshot to `--helium-restore-disposable-native-passwords`, require an initially empty marked profile, import through `PasswordStoreInterface::AddLogins`, and compare native readback before accepting the content-free receipt. | Browser-native capture every two minutes; off-device snapshot archive at least every six hours and after a mutation-sensitive acceptance run; keep twelve generations. Hash conflict or a changing source aborts and later retries. | Source: `/home/d/.local/share/helium-native-recovery/DEVICE/default` on d/da or the app-private `.../files/helium-native-recovery/oneplus/default` on OnePlus. Replicas: `/srv/nas/helium-profile-backups/DEVICE/native-recovery-default` and the fixed peer's `/home/d/.local/share/helium-profile-backups/DEVICE/native-recovery-default`. |
| C1 | Cookies | Chromium's complete partition-aware `CookieManager` bridge publishes canonical cookie records and tombstones into the same revision journal, with rollback metadata and readback fingerprints. | A disposable browser pulls over the Tailnet; `CookieManager` applies the complete transaction, rejects lossy partition identities, rolls back a failed batch, and proves browser/site readback. | Continuous reconciliation every minute; captured by the stopped server archive generations. No generation is silently purged. | lm's separately mounted NAS, `/srv/nas/helium-sync-server-disposable`; shared physical storage with P1 does not turn it into another password or cookie mechanism. |
| C2 | Cookies | The stopped full-profile archive preserves Chromium's cookie store and all profile-coupled state as one filesystem generation. | Extract only into a new marked `drill-*` profile and prove exact cookie/site behavior after two browser starts. | Same full-profile install/mutation boundary and retention of at least three generations as P2. | The same two full-profile replica namespaces as P2. P2 and C2 are separate data restores from one whole-profile mechanism family; replicas never increase either count. |
| C3 | Cookies | Chromium independently calls `network::mojom::CookieManager::GetAllCookies`, retains partition keys and full canonical attributes, and atomically writes `cookies.current.json` outside the profile. | Restore a selected neutral generation, pass its cookie snapshot to `--helium-restore-disposable-native-cookies`, require an empty marked profile, import each item through `SetCanonicalCookie`, and compare complete native readback before accepting the receipt. | Browser-native capture every two minutes; off-device archive at least every six hours; keep twelve generations. Nonce partition keys, duplicate identities, extra fields, checksum changes, rejected sets, and mismatched readback all fail closed. | The same source and two neutral-recovery replica namespaces as P3. The password and cookie snapshots are distinct files and distinct browser APIs; a copied file is not a second path. |
| T1 | Tabs | Chromium's normal session service writes its local clean-exit/crash session representation in the active profile. | Launch the same disposable profile after both clean close and forced crash and require Chromium's native restore to reproduce the exact synthetic window/tab topology. | Chromium's normal local session cadence; lifecycle is bounded by the profile generation. | The source device's marked disposable/current profile. This intentionally covers device-local crash recovery, not source-device loss. |
| T2 | Tabs | Helium's native tab API exporter writes a neutral topology model; `helium-tabs` creates immutable content-addressed generations. | Fetch and validate one NAS and one peer generation, prepare new disposable browser profiles, import through the dedicated native tab restore bridge, and compare window/tab/group state and applied receipts. | Native refresh every five minutes; full off-device cycle every fifteen minutes; newest plus 24 hourly, 14 daily, and 12 weekly buckets. Invalid bytes go to quarantine. | `/srv/nas/helium-tab-backups/DEVICE/default` on lm NAS and `/home/d/.local/share/helium-tab-backups/DEVICE/default` on the fixed peer. |
| T3 | Tabs | The stopped compressed full-profile archive independently preserves Chromium's session files together with the rest of the profile. | Extract two selected replicas into distinct `drill-*` profiles and prove the exact synthetic topology on first and second start. | Same full-profile boundary and retention as P2/C2; the restore drill protects its admitted generation from deletion. | The same two full-profile namespaces as P2/C2. The producer/format/restore are materially different from T1's live session lifecycle and T2's neutral topology model. |

## Fixed topology

The replica topology is source-bound and private over Tailscale plus SSH:

| Source | NAS replica | Peer replica |
| --- | --- | --- |
| d | lm NAS | da |
| da | lm NAS | d |
| oneplus | lm NAS, streamed by lm over rooted ADB | da |

For neutral password/cookie capture, copy the matching example from
`scripts/native-recovery` to a mode-0600 path outside the repository. Desktop
launchers create and bind the exact native root. Android enrollment binds the
package-private root. The common profile backup boundary supplies immutable
two-replica generations; `backup-android-native-recovery.sh` supplies the
OnePlus stream without writing plaintext snapshots on lm.

Install one inactive source-bound timer on each of d, da, and lm/OnePlus, then
enable it only after the native artifact has created both current snapshots:

```sh
scripts/native-recovery/install-scheduler.sh install /secure/native-recovery.conf
scripts/native-recovery/install-scheduler.sh enable
scripts/native-recovery/install-scheduler.sh status
```

`enable` first creates and verifies a complete generation at both fixed
destinations. Only then does it enable the persistent six-hour timer. The
installer records one immutable source commit, keeps the config private, and
does not install a competing password manager or touch the profile databases.

## Neutral restore drill

For one desktop source, create a private marked restore parent and restore the
same generation once from each destination:

```sh
install -d -m0700 /secure/helium-native-restores
(umask 077; printf 'helium-disposable-profile-restore-root\n' \
  >/secure/helium-native-restores/.helium-disposable-profile-restore-root)

scripts/profile-backup/helium-profile-backup.sh restore-to-disposable \
  /secure/d-native-recovery.conf nas-on-lm GENERATION \
  /secure/helium-native-restores/drill-d-native-nas
scripts/profile-backup/helium-profile-backup.sh restore-to-disposable \
  /secure/d-native-recovery.conf da-copy GENERATION \
  /secure/helium-native-restores/drill-d-native-peer
```

For each restored copy and each kind, prepare a separate private runtime-drill
root and let the guarded runner create a new marked browser user-data directory.
The runner supplies exactly one native recovery switch, waits for Chromium's
native readback receipt, and closes that disposable process:

```sh
install -d -m0700 /secure/helium-native-runtime-drills
(umask 077; printf 'helium-native-recovery-drill-root-v1\n' \
  >/secure/helium-native-runtime-drills/.helium-native-recovery-drill-root-v1)

scripts/native-recovery/runtime-drill.sh desktop /.../helium d passwords \
  /secure/helium-native-restores/drill-d-native-nas/passwords.current.json \
  /secure/helium-native-runtime-drills/drill-d-passwords-nas headless
```

Internally, the new `Default` gets the mode-0600
`.helium-native-recovery-disposable-profile-v1` marker and the exact admitted
browser receives one of these switches:

```text
--helium-restore-disposable-native-passwords=/.../drill-d-native-nas/passwords.current.json
--helium-restore-disposable-native-cookies=/.../drill-d-native-nas/cookies.current.json
```

The dedicated process returns before tab export or Tailnet enrollment, refuses
a nonempty destination store, and writes only
`Default/helium-sync/native-recovery-receipt-v1.json`. Validate each browser
receipt together with the snapshot and its off-device profile-restore receipt:

```sh
node scripts/native-recovery/acceptance.mjs verify-restore \
  --kind passwords --device d --destination nas-on-lm \
  --snapshot /.../drill-d-native-nas/passwords.current.json \
  --browser-receipt /secure/helium-native-runtime-drills/drill-d-passwords-nas/Default/helium-sync/native-recovery-receipt-v1.json \
  --profile-receipt /.../drill-d-native-nas/.helium-profile-restore-receipt.env \
  --artifact /.../helium \
  --output /secure/evidence/d-passwords-native-nas.json
```

For OnePlus, restore the selected generation on lm, then stage and launch only
the checksum-admitted disposable Sync APK. The runner creates sibling input and
profile namespaces under `computer.helium.sync.test`, verifies the staged
snapshot hash, delegates temporary command-line ownership to the disposable
browser boundary, fetches the private browser receipt, and force-stops the test
package. It never names or opens `computer.helium.sync`:

```sh
scripts/native-recovery/runtime-drill.sh android "$sync_acceptance" \
  oneplus:5555 passwords \
  /secure/oneplus-native-restores/drill-oneplus-native-nas/passwords.current.json \
  drill-oneplus-passwords-nas \
  /secure/evidence/oneplus-passwords-nas.browser.json
```

Repeat for passwords/cookies and NAS/peer, then run `finalize-device`. It
requires both destinations to restore the same archive, snapshot, record set,
and native state. This double-replica proof strengthens one neutral mechanism;
it never counts as two mechanisms.

## Fleet completion rule

Fleet completion requires 27 mechanism/device results: all nine rows on d, da,
and OnePlus, on exact returned and checksum-admitted artifacts. A row stays
open when only its source exists, its archive exists without a readback, only
one replica restored, the receipt belongs to a different artifact or device,
or any personal profile was used for the drill.

## Live deployment state (2026-08-08)

The fixed backup topology and its fail-closed schedulers are installed, but the
nine-path runtime gate is not being reported as complete prematurely:

- lm's disposable Tailnet journal service is live only on
  `100.100.105.47:44719`; its stopped archive/restore drill passes against
  `/srv/nas/helium-sync-server-disposable`.
- The P3/C3 six-hour native-recovery schedulers are installed on d, da, and lm
  for OnePlus, but remain disabled until the returned browser artifacts create
  both fresh neutral snapshots. Enabling a scheduler first requires one
  checksum-verified generation at both of its fixed destinations.
- The T2 scheduler and current `helium-tabs` producer are staged on all three
  sources. d and da use inactive systemd user timers. OnePlus has only the
  disabled Arch-chroot source, config template, and Magisk-runner template: no
  active config, enable marker, or `service.d` runner exists.
- OnePlus is reachable through its Tailnet address and authorized rooted ADB.
  Its installed production packages are outside this disposable gate and have
  not been opened or changed. Device execution must use a newly built,
  checksum-admitted `computer.helium.sync.test` package.

These installed-but-disabled states are deliberate. The timers become active
only after the current Linux and Android test artifacts pass native
password/cookie/tab capture and restore on newly marked disposable profiles;
production profiles and the production Android package are not gate inputs.
