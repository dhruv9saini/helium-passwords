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

A copied backup never opens a browser.

## 3. Prepare lm without activating it

```sh
scripts/install-lm-sync-service.sh install-source
```

This installs `helium-syncd.service` but does not initialize, enable, or start
it. The service listens only on `127.0.0.1:44719`.

Tailscale HTTPS must first be enabled for the tailnet. That admin-console action
publishes lm's certificate name to Certificate Transparency and is therefore a
real external gate. After it is enabled:

```sh
sudo tailscale serve --bg --yes --https=443 http://127.0.0.1:44719
tailscale serve status --json | jq .
```

Do not use Funnel. Verify the resulting `https://lm.<tailnet>.ts.net` name
from disposable d, da, and oneplus clients and confirm the backend port is not
reachable from non-loopback lm interfaces.

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

Before initializing lm, create two encrypted backups of d's complete seed
state and token, to two off-d destinations, using two separately held recovery
recipients. Restore one copy into a new disposable directory, load it with
`helium-sync seed-public`, and compare only the public output. Record hashes
and the drill; then remove the disposable plaintext. This proof is mandatory
and is not satisfied by a copy inside d, lm's server directory, or Git.

On lm:

```sh
scripts/install-lm-sync-service.sh initialize /secure/incoming/lm-bootstrap.json
# Back up and restore /var/lib/helium-sync into a disposable directory here.
# The copy contains only credential hashes and opaque ciphertext.
scripts/install-lm-sync-service.sh enable
scripts/install-lm-sync-service.sh status
```

Activation refuses unless Tailscale Serve already forwards to the loopback
service. Delete neither the bootstrap nor any recovery copy until the recorded
restore drill passes; move them to their documented secure locations.

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
printf '%s\n' 'https://lm.TAILNET.ts.net' \
  > PROFILE/Default/helium-sync/base_url
```

Start the disposable browser. It remains pull-only. Verify applied passwords
and cookies, then stop it and promote only with:

```sh
helium-sync enrollment-complete \
  --url https://lm.TAILNET.ts.net \
  --profile-dir PROFILE \
  --state-file PROFILE/Default/helium-sync/client.json \
  --password-state PROFILE/Default/helium-sync/password-state.json \
  --cookie-state PROFILE/Default/helium-sync/cookie-state.json \
  --token-file PROFILE/Default/helium-sync/token
```

The command rejects a profile lock, wrong schema, unequal cursor, stale server
cursor, bad token, or non-join state. Restart and prove zero unchanged writes.
Only then repeat the sequence for oneplus.

## 6. Rotation and revocation

Content-key rotation order is fixed:

1. d: `key-stage`.
2. da/oneplus: `key-update-request`; d: `seed-wrap`; join:
   `key-update-install`; then `key-ack-install`.
3. d: `key-activate`, then every join: `key-adopt`.
4. d: `key-rekey`; every device pulls/applies/verifies; joins:
   `key-ack-rekey`.
5. d: `key-retire`.

Never retire while a device is offline or before every acknowledgement.

Credential rotation uses `credential-stage --new-token-file NEW`, then tests
the new credential with `credential-confirm --token-file NEW`. Atomically
install NEW into the stopped profile, restart and verify, then run
`credential-retire` using the new token. If any step fails, both credentials
remain valid and the build/data result is unchanged.

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
