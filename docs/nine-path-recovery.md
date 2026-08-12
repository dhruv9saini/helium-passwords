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

| ID | Data | Producer and representation | Restore path | Schedule and retention | Encryption and integrity | Exact private location / failure domain |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | Passwords | Chromium's `PasswordStoreInterface` bridge publishes complete `PasswordSpecificsData` records into the append-only password-only server journal and verified latest-state snapshots. | A newly enrolled disposable browser pulls through the authenticated revision protocol; the bridge writes through `PasswordStoreInterface`, restarts, and proves native fill/readback. | On mutation and every 30 seconds; stopped-server archive generations are retained until an explicit reviewed retention run. | Tailscale supplies WireGuard transport encryption. The mode-0600 server journal is not independently encrypted at rest; revision hashes, payload hashes, archive SHA-256 inventories, and a returned restore drill detect corruption. | lm's separately mounted NAS, `/srv/nas/helium-passwords-server-disposable`; the server process and its archive/restore drill are the authority failure domain. |
| P2 | Passwords | A stopped, checksum-stable Zstandard-compressed archive of the complete Chromium profile. Password bytes remain in Chromium's native profile representation. | Verify one archive generation, extract only into a new marked `drill-*` directory, launch that whole disposable profile, and prove native fill after two starts. | Before every install, enrollment, or profile mutation and on the profile-backup timer; keep at least three admitted generations and quarantine corrupt generations. | SSH over the Tailnet encrypts transport. `profile.tar.zst` is not independently encrypted; per-file tree hashes, archive SHA-256, immutable receipts, and post-extract tree verification provide integrity. | `/srv/nas/helium-profile-backups/DEVICE/default` on lm NAS plus `/home/d/.local/share/helium-profile-backups/DEVICE/default` on the fixed peer. The pair is one mechanism with two replicas. |
| P3 | Passwords | Chromium independently reads `PasswordStoreInterface`, serializes canonical password specifics into `passwords.current.json`, and atomically replaces a mode-0600 file outside the profile. | Restore a selected off-device neutral generation, pass it to `--helium-restore-disposable-native-passwords`, require an empty marked profile, import through `PasswordStoreInterface::AddLogins`, and compare native readback before accepting the content-free receipt. | Capture every two minutes and on store changes; archive at least every six hours and after mutation acceptance; keep twelve generations. | Snapshot and archive transport uses SSH over Tailscale. The neutral JSON is not independently encrypted at rest; strict mode/owner checks, source and archive SHA-256, schema validation, and exact browser readback protect integrity. | Source: `/home/d/.local/share/helium-native-recovery/DEVICE/default` on d/da or app-private `.../files/helium-native-recovery/oneplus/default` on OnePlus. Replicas: `/srv/nas/helium-profile-backups/DEVICE/native-recovery-default` and the fixed peer's `/home/d/.local/share/helium-profile-backups/DEVICE/native-recovery-default`. |
| C1 | Cookies | Chromium calls `network::mojom::CookieManager::GetAllCookies`, retains full canonical attributes and partition keys, and atomically writes `cookies.current.json` outside the disposable profile. | Restore one neutral generation into an empty marked disposable profile through `SetCanonicalCookie`; require exact native readback, and restore the pre-apply snapshot after any rejected batch. | Capture every two minutes; archive at least every six hours; keep twelve generations. | SSH over Tailscale encrypts transport. The mode-0600 JSON is not independently encrypted; canonical identity validation, schema and SHA-256 checks, rollback fingerprints, and exact CookieManager readback provide integrity. | The same source and replica namespaces as P3, but a distinct cookie file, producer API, validator, restore switch, and browser readback receipt. |
| C2 | Cookies | The stopped Zstandard-compressed full-profile archive preserves Chromium's cookie store and profile-coupled state as one filesystem generation. | Extract only into a new marked `drill-*` profile and prove exact synthetic cookie behavior after two starts. | Same mutation boundary and minimum three-generation retention as P2. | SSH over Tailscale encrypts transport. The archive is not independently encrypted; archive/tree SHA-256 inventories and post-restore verification provide integrity. | The same two full-profile replica namespaces as P2. This is one whole-profile mechanism shared across data classes, not an extra replica-derived mechanism. |
| C3 | Cookies | A stopped, marked disposable profile is independently ingested into a restic content-addressed repository by `helium-encrypted-cookie-backup.sh`; it does not reuse the C2 archive or C1 JSON. | Select an exact full restic snapshot ID, run repository integrity verification, restore into a new marked drill root, then launch twice and prove the synthetic cookie set. | Backup after cookie mutation acceptance and every six hours; keep the last 12 plus 14 daily and 12 weekly snapshots, then prune and re-check. | Restic independently encrypts and authenticates repository objects with a private mode-0600 password file stored outside the repository. Each backup runs a 10% data read check; periodic `check` reads all data; restore is followed by another check. | da owns `/home/d/.local/share/helium-encrypted-profile-backups/DEVICE/default`; the repository, restic password, and da filesystem form a failure domain distinct from lm NAS and the peer archive replicas. |
| T1 | Tabs | Chromium's normal session service writes its local clean-exit/crash session representation in the active profile. | Launch the same disposable profile after both clean close and forced crash and require native restore to reproduce the exact synthetic window/tab topology. | Chromium's normal local session cadence; lifecycle is bounded by the profile generation. | Chromium owns format integrity. No independent encryption layer is added; profile filesystem access controls are the at-rest boundary. | The source device's marked disposable/current profile. This covers local crash recovery, not source-device loss. |
| T2 | Tabs | Helium's native tab API exporter writes a neutral topology model; `helium-tabs` creates immutable content-addressed generations. | Fetch and validate one NAS and one peer generation, prepare new disposable profiles, import through the native tab restore bridge, and compare window/tab/group state and receipts. | Refresh every five minutes; off-device cycle every fifteen minutes; newest plus 24 hourly, 14 daily, and 12 weekly buckets. | SSH over Tailscale encrypts transport. Neutral snapshots are not independently encrypted; content hashes, immutable receipts, and quarantine-on-invalid-input protect integrity. | `/srv/nas/helium-tab-backups/DEVICE/default` on lm NAS and `/home/d/.local/share/helium-tab-backups/DEVICE/default` on the fixed peer. |
| T3 | Tabs | The stopped compressed full-profile archive independently preserves Chromium's session files with the rest of the profile. | Extract selected replicas into new `drill-*` profiles and prove exact synthetic topology on first and second start. | Same full-profile boundary and retention as P2/C2; the selected restore generation is protected from deletion. | Same transport encryption and archive/tree SHA-256 integrity as P2/C2; the archive has no independent at-rest encryption. | The same two full-profile namespaces as P2/C2. Producer, format, and restore differ from T1's live session lifecycle and T2's neutral model. |

## Fixed topology

The replica topology is source-bound and private over Tailscale plus SSH:

| Source | NAS replica | Peer replica |
| --- | --- | --- |
| d | lm NAS | da |
| da | lm NAS | d |
| oneplus | lm NAS; P3/C1 stream through fixed ADB plus the debuggable `.test` app sandbox, while the disabled T2 source runs in an isolated Magisk chroot | da |

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
profile namespaces under `computer.helium.passwords.test`, verifies the staged
snapshot hash, delegates temporary command-line ownership to the disposable
browser boundary, fetches the private browser receipt, and force-stops the test
package. It never names or opens `computer.helium.passwords`:

```sh
scripts/native-recovery/runtime-drill.sh android "$sync_acceptance" \
  oneplus:5555 passwords \
  /secure/oneplus-native-restores/drill-oneplus-native-nas/passwords.current.json \
  drill-oneplus-passwords-nas \
  /secure/evidence/oneplus-passwords-nas.browser.json
```

Repeat for P3/C1 and NAS/peer, then run `finalize-device`. It
requires both destinations to restore the same archive, snapshot, record set,
and native state. This double-replica proof strengthens one neutral mechanism;
it never counts as two mechanisms.

## Fleet completion rule

Completion requires nine mechanism results: every row above must have an exact
restore receipt on a returned, checksum-admitted Linux or Android artifact,
and both artifact families must exercise passwords, cookies, and tabs. A row
stays open when only source exists, an archive exists without browser readback,
only one required replica restored, the receipt belongs to another artifact,
or any non-disposable profile or personal Google cookie was used.

## Live deployment state (2026-08-08)

The fixed backup topology and its fail-closed schedulers are installed, but the
nine-path runtime gate is not being reported as complete prematurely:

- lm's disposable Tailnet journal service is live only on
  `100.100.105.47:44719`; its stopped archive/restore drill passes against
  `/srv/nas/helium-sync-server-disposable`.
- The P3/C1 six-hour native-recovery schedulers are installed on d, da, and lm
  for OnePlus, but remain disabled until the returned browser artifacts create
  both fresh neutral snapshots. Enabling a scheduler first requires one
  checksum-verified generation at both of its fixed destinations.
- The T2 scheduler and current `helium-tabs` producer are staged on all three
  sources. d and da use inactive systemd user timers. OnePlus has only the
  disabled Arch-chroot source, config template, and Magisk-runner template: no
  active config, enable marker, or `service.d` runner exists.
- OnePlus is reachable through its Tailnet address and authorized ADB. The
  P3/C1 producer reconnects only `oneplus:5555`, binds every command to that
  serial, and reads only the debuggable `computer.helium.passwords.test` sandbox
  through Android `run-as`; it does not need Magisk root or an unlocked screen.
  Its installed production packages are outside this disposable gate and have
  not been opened or changed. Device execution must use a newly built,
  checksum-admitted `computer.helium.passwords.test` package. The separate T2
  Arch-chroot runner remains disabled and root-gated until its native export
  and live route preflight both pass.

These installed-but-disabled states are deliberate. The timers become active
only after the current Linux and Android test artifacts pass native
password/cookie/tab capture and restore on newly marked disposable profiles;
production profiles and the production Android package are not gate inputs.
