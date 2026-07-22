# Helium Sync Deployment Runbook

Do not use this runbook on a personal profile until every disposable gate in
`acceptance.md` is recorded against the exact returned artifact. Commands are
shown with placeholders and never print a token, content key, cookie, password,
or tab URL.

## 1. Build and return artifacts

Run from the clean private checkout on lm. The active native compile uses the
same form:

```sh
job=hs-android-148-native-sync-N
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$job" 80
scripts/chromiumer-job.sh start "$job" \
  --summary "Chromium 148 Android native Helium sync compile" \
  --next "Fetch and verify the compile proof, then start the bounded APK job." -- \
  scripts/chromiumer-nix.sh run -- env \
    HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
    CHROMIUM_ANDROID_PHASE=all \
    CHROMIUM_TARGET=chrome/browser/helium_sync:helium_sync \
    CHROMIUM_ANDROID_PROVENANCE_ONLY=true \
    USE_CCACHE=false CHROMIUM_ANDROID_SKIP_SYSTEM_DEPS=true \
    CHROMIUM_ANDROID_USE_SISO=false AUTONINJA_JOBS=2 GCLIENT_JOBS=2 \
    bash scripts/chromium/build-android-ci.sh

scripts/chromiumer-job.sh status "$job"
scripts/chromiumer-job.sh logs "$job" 120
# One cancellation command:
scripts/chromiumer-job.sh cancel "$job"
```

After success, fetch the named compile tarball to the NAS, verify its automatic
receipt, then clean the remote workspace. Use a new job ID for
`chrome_public_apk`; never mutate or resume a terminal job.

## 2. Prove disposable behavior

Use synthetic credentials, fixture cookies, and new disposable profiles on d,
da, and oneplus. Record:

- d seed, da pending join, oneplus pending join;
- zero records published by either initial join;
- equal password/cookie/client verified cursors before explicit promotion;
- zero records after an unchanged restart;
- save prompt, autofill, update, deletion/tombstone, stale conflict;
- whole-cookie identity, session cookies, partition keys, two rotations,
  destination rollback, DBSC/rejection handling, and imported-session outcome;
- streaming and codec fixtures; and
- local tab capture, both off-source hashes, corruption quarantine, retention,
  and restore into a new disposable browser state.

The oneplus disposable APK must use the parallel package identity; it may not
replace the installed personal package:

```sh
CHROMIUM_ANDROID_MANIFEST_PACKAGE=computer.helium.sync.test
```

Confirm the returned APK manifest and `build-provenance/gn-args-resolved.txt`
both name `computer.helium.sync.test` before installation. Android then gives
the fixture browser an independent app-data directory. The later production
artifact is a separate clean build with the default `computer.helium.sync`;
back up that app's complete existing data before installing it.

Make that check executable on lm (the current SDK tool path is explicit):

```sh
AAPT2="$HOME/Android/Sdk/build-tools/36.0.0/aapt2" \
  scripts/chromium/verify-android-artifact.sh \
  /srv/nas/helium-builds/JOB/chrome_public_apk-arm64.tar.xz \
  computer.helium.sync.test HELIUM_SYNC_COMMIT
```

The verifier also checks the relocatable provenance manifest, pinned Chromium
commit, clean tracked source status, exactly one `HeliumSync.apk`, and the
artifact-carried runtime acceptance kit. It prints the APK and runtime-kit
SHA-256 values. Prepare a new, immutable disposable test directory from that
verified archive:

```sh
AAPT2="$HOME/Android/Sdk/build-tools/36.0.0/aapt2" \
  scripts/android-media/prepare-disposable-acceptance.sh \
  /srv/nas/helium-builds/JOB/chrome_public_apk-arm64.tar.xz \
  HELIUM_SYNC_COMMIT \
  /srv/nas/helium-acceptance/JOB

(cd /srv/nas/helium-acceptance/JOB && sha256sum -c PACKAGE_SHA256SUMS)
```

The preparer refuses an existing destination. It copies the exact test APK,
build provenance, and artifact-carried probe scripts, generates deterministic
synthetic media with those scripts, and records hashes for the archive, APK,
runtime kit, and complete prepared directory. It does not install or launch
the APK.

After the test package is explicitly installed and launched on disposable
oneplus state, run the carried probe from the host connected to that device.
Use a new evidence filename for each APK and never use `--remove-all`, which
could disrupt unrelated ADB work:

```sh
set -euo pipefail
acceptance=/srv/nas/helium-acceptance/JOB
serial=ONEPLUS_ADB_SERIAL
evidence_root=/srv/nas/helium-acceptance-evidence/JOB
mkdir -p "$evidence_root"
evidence="$evidence_root/result-oneplus.json"
fixture_log="$evidence.fixture-server.log"
[[ ! -e "$evidence" && ! -e "$fixture_log" && ! -e "$evidence.receipt.sha256" ]]
fixture_pid=
reverse_created=false
forward_created=false
cleanup_probe() {
  if [[ "$forward_created" == true ]]; then
    adb -s "$serial" forward --remove tcp:9222 || true
  fi
  if [[ "$reverse_created" == true ]]; then
    adb -s "$serial" reverse --remove tcp:44721 || true
  fi
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
}
trap cleanup_probe EXIT INT TERM

(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS)
node "$acceptance/runtime-acceptance/fixture-server.mjs" \
  --host 127.0.0.1 --port 44721 --media-dir "$acceptance/media" \
  > "$fixture_log" 2>&1 &
fixture_pid=$!

adb -s "$serial" reverse --no-rebind tcp:44721 tcp:44721
reverse_created=true
adb -s "$serial" forward --no-rebind tcp:9222 localabstract:chrome_devtools_remote
forward_created=true
node "$acceptance/runtime-acceptance/run-cdp-probe.mjs" \
  --cdp http://127.0.0.1:9222 \
  --fixture http://127.0.0.1:44721/probe \
  --output "$evidence"

sha256sum "$evidence" "$acceptance/acceptance.env" \
  > "$evidence.receipt.sha256"
```

The test app must already be the hash-verified `computer.helium.sync.test` APK;
the fixture and CDP endpoints stay on loopback. The runner refuses non-loopback
origins and existing evidence. A passing result requires three observable
numbered-chunk milestones for identity, gzip, and Brotli Fetch responses,
ordered SSE, verified MP4/WebM/MSE fixtures, completed playback, video
dimensions, decoded-audio evidence, required codec capabilities, and browser
product/protocol provenance. HTTP/2, HTTP/3, background/foreground, network
handoff, upstream-control A/B, and ChatGPT timing remain separate device gates.

A copied backup never opens a browser.

## 3. Prepare lm without activating it

```sh
scripts/install-lm-sync-service.sh install-source
```

This installs `helium-syncd.service` but does not initialize, enable, or start
it. Production has no cleartext listener and does not use Tailscale Serve.
Record lm's current identity without changing Tailscale state:

```sh
tailscale status --json \
  | jq -r '.Self.DNSName, (.Self.TailscaleIPs[] | select(test("^[0-9]+\\.")))'
```

The current expected values are `lm.tail0168aa.ts.net.` and
`100.100.105.47`; re-read them before issuance rather than assuming they have
not changed. On an independently held offline recovery device, create the
dedicated endpoint-constrained CA once and issue lm's one-year leaf:

```sh
umask 077
helium-sync tls-ca-init \
  --hostname lm.tail0168aa.ts.net \
  --ip 100.100.105.47 \
  --output-dir /MOUNTED/OFFLINE/helium-sync-tls-ca

helium-sync tls-server-issue \
  --ca-cert /MOUNTED/OFFLINE/helium-sync-tls-ca/ca-cert.pem \
  --ca-key /MOUNTED/OFFLINE/helium-sync-tls-ca/ca-key.pem \
  --hostname lm.tail0168aa.ts.net \
  --ip 100.100.105.47 \
  --output-dir /secure/export/lm-tls-GENERATION
```

The root is ECDSA P-256, path length zero, and has critical name constraints
for exactly that `.ts.net` name and Tailscale IPv4 address. The leaf is
server-auth-only, covers exactly the same DNS/IP pair, and lasts 365 days.
Keep `ca-key.pem` offline. Transfer only `ca-cert.pem`, `server-cert.pem`, and
`server-key.pem` to lm through an authenticated route, then install while the
service is inactive:

```sh
scripts/install-lm-sync-service.sh install-endpoint \
  /secure/incoming/ca-cert.pem \
  /secure/incoming/server-cert.pem \
  /secure/incoming/server-key.pem
scripts/install-lm-sync-service.sh verify-endpoint
```

Installation verifies the exact live Tailscale identity, CA constraints,
signature, certificate/key match, SANs, purpose, permissions, and at least 30
days of remaining lifetime. It writes a new immutable generation below
`/etc/helium-sync/tls/generations/`, atomically switches `current`, and keeps
older generations for rollback. It neither starts the service nor changes
Tailscale. Verification requires both Tailscale Serve and Funnel to remain
empty. The hardened unit re-verifies the generation at every start, binds only
`100.100.105.47:44719`, permits only tailnet IPv4 peers, and requires TLS 1.3.
No `:443` capability is needed.

Before a client receives a URL or credential, authenticate the printed
`ca_sha256` through a route independent of lm and explicitly enroll that exact
`ca-cert.pem` in its platform trust store. On Arch Linux d/da:

```sh
openssl x509 -in /secure/incoming/ca-cert.pem -outform DER \
  | sha256sum
sudo trust anchor --store /secure/incoming/ca-cert.pem
sudo update-ca-trust extract
```

On oneplus, copy the public certificate to a disposable location, verify the
same DER SHA-256, and import it as a user VPN/apps CA through Android's
credential installer. Chromium's Android verifier reads user-added roots; do
not install the CA private key or the server leaf key. Record the user-root
fingerprint and remove only the disposable public-file copy after enrollment.
The base URL is `https://lm.tail0168aa.ts.net:44719`. A disposable client must
show a valid chain to this private root; a missing, substituted, unconstrained,
wrong-IP, or expired root/leaf must fail before any bearer credential is sent.

Issue a replacement leaf from the same offline CA before 30 days remain. Use a
new output directory, authenticate its printed fingerprints, and transfer only
the new server certificate/key plus the unchanged public root. Then:

```sh
sudo systemctl stop helium-syncd.service
scripts/install-lm-sync-service.sh install-endpoint \
  /secure/incoming/ca-cert.pem \
  /secure/incoming/server-cert.pem \
  /secure/incoming/server-key.pem
sudo systemctl start helium-syncd.service
scripts/install-lm-sync-service.sh verify-live-endpoint
```

The installer retains every prior immutable generation. Do not remove the
previous generation until all three disposable clients have completed a new
TLS connection and the prior leaf has expired. Leaf renewal does not change the
enrolled root; a changed root is a separate, explicitly coordinated client
trust rotation.

## 4. Create d seed and recovery material

Run on d, not lm:

```sh
umask 077
helium-sync seed-init \
  --state-file /secure/device/helium-sync/client.json \
  --token-file /secure/device/helium-sync/token \
  --bootstrap-file /secure/export/lm-bootstrap.json
helium-sync seed-public \
  --state-file /secure/device/helium-sync/client.json \
  --output /secure/export/d-seed-signing-public
```

The bootstrap contains only d, the active key ID, and a token hash. Transfer
that bootstrap to lm. Do not transfer `client.json` or the token to lm.

Before initializing lm, create two dedicated recovery identities directly on
two independently held recovery media. Run each command on its recovery holder,
not on d, lm, the NAS, or chromiumer:

```sh
helium-sync recovery-keygen --output-dir /MOUNTED/RECOVERY-A/helium-sync-d
helium-sync recovery-keygen --output-dir /MOUNTED/RECOVERY-B/helium-sync-d
```

Transfer only each `recipient.txt` to d through authenticated routes. On d,
create one recipient set and export a new encrypted generation:

```sh
umask 077
cat /secure/incoming/recovery-A-recipient.txt \
    /secure/incoming/recovery-B-recipient.txt \
  > /secure/device/helium-sync/recovery-recipients.txt
helium-sync recovery-export \
  --state-file /secure/device/helium-sync/client.json \
  --token-file /secure/device/helium-sync/token \
  --recipients-file /secure/device/helium-sync/recovery-recipients.txt \
  --output /secure/export/d-recovery-GENERATION.age
sha256sum /secure/export/d-recovery-GENERATION.age
```

The export refuses fewer than two distinct native age recipients and never
writes a plaintext archive. Copy the exact encrypted generation to two
off-d destinations and verify the printed SHA-256 independently at each.
Neither destination may contain an identity file.

Restore each destination copy with a different identity into a nonexistent
disposable directory. The authenticated seed-public file must arrive through a
route independent of the ciphertext:

```sh
helium-sync recovery-import \
  --input /OFFSOURCE-A/d-recovery-GENERATION.age \
  --identity-file /MOUNTED/RECOVERY-A/helium-sync-d/identity.txt \
  --expected-seed-public-file /secure/incoming/d-seed-signing-public \
  --output-dir /secure/disposable/d-recovery-drill-A
helium-sync seed-public \
  --state-file /secure/disposable/d-recovery-drill-A/client.json \
  --output /secure/disposable/d-recovery-drill-A/seed-public
cmp /secure/incoming/d-seed-signing-public \
  /secure/disposable/d-recovery-drill-A/seed-public
```

Repeat from off-source copy B with recovery identity B. Import authenticates
the age ciphertext, validates the complete d keypair/keyring/token, binds it to
the expected public trust anchor, and refuses an existing output directory.
Record the two hashes and restore receipts, then securely dispose of only the
disposable plaintext drill directories. This proof is not satisfied by a copy
inside d, lm's server directory, or Git.

On lm:

```sh
scripts/install-lm-sync-service.sh initialize /secure/incoming/lm-bootstrap.json
scripts/install-lm-sync-service.sh backup-drill
scripts/install-lm-sync-service.sh enable
scripts/install-lm-sync-service.sh status
```

Activation refuses unless the direct TLS generation matches lm's live
Tailscale identity and Serve and Funnel are empty. `enable` does not trust the
presence of an older receipt: immediately before activation it creates a fresh
backup generation from the current `/var/lib/helium-sync`, restores that exact
generation into disposable state, validates the restored registry and opaque
store, and atomically records the receipt. After start it makes an
authenticated health request through the tailnet address; a failure stops and
disables the service. Delete neither the bootstrap nor any recovery copy until
the recorded restore drill passes; move them to their documented secure
locations.

## 5. Join da, then oneplus

Run the following on one joining device at a time. The trust-anchor file must
arrive through an authenticated route distinct from lm's untrusted relay.

On the join device:

```sh
helium-sync join-request \
  --device da \
  --seed-public-file /secure/incoming/d-seed-signing-public \
  --pending-file /secure/device/helium-sync/join.pending.json \
  --request-file /secure/export/da-join-request.json \
  --auth-request-file /secure/export/da-auth-request.json \
  --token-file /secure/device/helium-sync/token
```

On d, after verifying the device ID and request fingerprint:

```sh
helium-sync seed-wrap \
  --state-file /secure/device/helium-sync/client.json \
  --request-file /secure/incoming/da-join-request.json \
  --wrapped-file /secure/export/da-wrapped-enrollment.json
```

On lm, register only the hash request:

```sh
sudo -u helium-sync /usr/local/libexec/helium-sync server-enroll \
  --devices-file /var/lib/helium-sync/devices.json \
  --auth-request-file /secure/incoming/da-auth-request.json
```

On the join device, use the active key ID recorded in the server bootstrap:

```sh
helium-sync join-install \
  --state-file PROFILE/Default/helium-sync/client.json \
  --pending-file /secure/device/helium-sync/join.pending.json \
  --wrapped-file /secure/incoming/da-wrapped-enrollment.json \
  --required-key-id ACTIVE_KEY_ID
install -m0600 /secure/device/helium-sync/token \
  PROFILE/Default/helium-sync/token
printf '%s\n' 'https://lm.TAILNET.ts.net:44719' \
  > PROFILE/Default/helium-sync/base_url
```

Start the disposable browser. It remains pull-only until both native bridges
have applied, read back, and durably acknowledged the same current cursor. The
profile coordinator then completes that one joint cursor and reloads both
bridge clients before resuming. Verify `client.json` became `active`, verify
the applied passwords and cookies, restart, and prove zero unchanged writes.

If a disposable join remains pending after both bridge states are present,
stop the browser and use the offline equivalent below. It is intentionally the
same joint schema/cursor/server gate, not a bypass:

```sh
helium-sync enrollment-complete \
  --url https://lm.TAILNET.ts.net:44719 \
  --profile-dir /ABSOLUTE/PROFILE \
  --state-file /ABSOLUTE/PROFILE/Default/helium-sync/client.json \
  --password-state /ABSOLUTE/PROFILE/Default/helium-sync/password-state.json \
  --cookie-state /ABSOLUTE/PROFILE/Default/helium-sync/cookie-state.json \
  --token-file /ABSOLUTE/PROFILE/Default/helium-sync/token
```

The command rejects a profile lock, wrong schema, unequal cursor, stale server
cursor, bad token, or non-join state. Restart and prove zero unchanged writes.
Only then repeat the sequence for oneplus.

## 6. Rotation and revocation

Content-key rotation order is fixed. Every remote command also receives
`--url https://lm.TAILNET.ts.net:44719`, its device's `--state-file`, and its current
`--token-file`.

1. On d, run `key-stage` and record `staged_key_id`. Then run
   `key-ack-install` on d; d is an active device and its acknowledgement is
   required too.
2. On each join, run `key-update-request --pending-file NEW_PENDING
   --request-file NEW_REQUEST`. On d, wrap each request with `seed-wrap`. Back
   on that join, run `key-update-install --pending-file NEW_PENDING
   --wrapped-file WRAPPED --required-key-id OLD --required-key-id STAGED`, then
   run `key-ack-install`.
3. On d, run `key-activate`. On every join, run `key-adopt`. The server accepts
   both epochs during this interval.
4. Quiesce browser publication and let d's native bridges reach one current
   verified cursor. On d run:

   ```sh
   helium-sync key-rekey \
     --url https://lm.TAILNET.ts.net:44719 \
     --state-file /ABSOLUTE/D-PROFILE/Default/helium-sync/client.json \
     --password-state /ABSOLUTE/D-PROFILE/Default/helium-sync/password-state.json \
     --cookie-state /ABSOLUTE/D-PROFILE/Default/helium-sync/cookie-state.json \
     --token-file /ABSOLUTE/D-PROFILE/Default/helium-sync/token
   ```

   This refuses unless both native revision inventories use the expected
   schemas and their verified cursors equal `client.json`; only then does it
   CAS-rekey every latest record and tombstone and acknowledge d's rekey.
5. Let every join pull/apply/read back the rekey, then run `key-ack-rekey` on
   each join. Finally run `key-retire` on d. Retirement fails until every live
   active device has acknowledged.

Never retire while a device is offline or before every acknowledgement.

Credential rotation is per-device and crash-resumable. `NEW` and `OLD_BACKUP`
must be absolute paths on that device:

```sh
helium-sync credential-stage \
  --url https://lm.TAILNET.ts.net:44719 \
  --state-file /ABSOLUTE/PROFILE/Default/helium-sync/client.json \
  --token-file /ABSOLUTE/PROFILE/Default/helium-sync/token \
  --new-token-file /secure/device/helium-sync/token.new
# Stop the browser before the cutover.
helium-sync credential-activate \
  --url https://lm.TAILNET.ts.net:44719 \
  --profile-dir /ABSOLUTE/PROFILE \
  --state-file /ABSOLUTE/PROFILE/Default/helium-sync/client.json \
  --token-file /ABSOLUTE/PROFILE/Default/helium-sync/token \
  --new-token-file /secure/device/helium-sync/token.new \
  --old-token-file /secure/device/helium-sync/token.rollback
```

`credential-activate` first preserves or verifies the mode-0600 rollback copy,
authenticates and confirms with the staged new credential, and only then
atomically replaces the stopped profile's token. If confirmation or the local
rename fails, the old server credential remains valid. Restart and verify sync,
then run `credential-retire` with the newly installed token. Preserve the old
rollback file until the old credential is proven rejected and the new one has
survived a restart.

Revoke a lost join on lm with:

```sh
sudo -u helium-sync /usr/local/libexec/helium-sync server-revoke \
  --devices-file /var/lib/helium-sync/devices.json --device DEVICE
```

Rekey content after revocation so the revoked device cannot decrypt future
records.

## 7. Personal rollout

For each existing personal profile, stop the browser and make a checksum-
verified encrypted full-profile backup to two off-device destinations before
installing anything. Keep the prior browser artifact and untouched backup.

Roll out in this order only:

1. d: install exact artifact, verify backup, enroll as seed.
2. da: install exact artifact, join pending, verify, explicitly promote.
3. oneplus: back up app data, install exact APK, join pending, verify, promote.

At every stage, rollback means stopping the new browser, preserving its failed
state for diagnosis, restoring the untouched profile backup to a new path,
and reinstalling the prior artifact. Never apply a tab backup to a personal
profile and never copy a backup to another device as active state.
