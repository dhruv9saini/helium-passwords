# Retired mixed-kind three-client acceptance

> This gate is retained only to audit historical synthetic evidence. It is not
> a current Helium Passwords execution path. The password-only server rejects
> every cookie push and excludes legacy cookie records from pull/latest, so the
> mixed password/cookie receipt described below cannot pass against the current
> product. Current acceptance uses per-artifact native password receipts and a
> common password-only journal as specified in `acceptance.md`.

This gate joins the existing artifact-bound native password protocol, the
canonical Helium Sync protocol, the native cookie manager, and the metadata-only
origin-state audit into one fail-closed receipt. It does not implement a second
password or cookie writer. It never uses CDP, CookieCloud, a personal profile,
tabs, or plaintext credential/cookie evidence.

The source tests have two deliberately separate responsibilities:

- `scripts/tests/three-client-acceptance.test.mjs` tests receipt admission and
  rejection with fake files. It also runs the existing native password
  acceptance and Sync receipt code instead of recreating their state machines.
- `go test ./internal/syncstore ./cmd/helium-sync-synthetic-client` exercises
  the real `syncstore.Client`, authenticated `Handler`, readable schema-2
  records, d seed, pull-only enrollment, no-op publication suppression, CAS
  conflict, tombstones, bearer rotation, cookie records, and 64-bit counters.
  The fake receipt test is not presented as protocol proof.

Runtime completion still requires one returned Linux runtime executed
independently on d and da, one independently admitted Android APK, and the
marker-gated private-Tailnet HTTP service. The gate
validates the resulting evidence; it does not invent browser UI or server
observations.

## Initialize

Use the exact artifact for each execution environment:

- `d` and `da`: separate verifications and executions of the same returned
  Linux x86_64 archive and build-produced deployment receipt; and
- `oneplus`: `Browser-test.apk` from the prepared
  `computer.helium.passwords.test` directory. Its `acceptance.env`,
  `PACKAGE_SHA256SUMS`, and every inventoried runtime/provenance member are the
  Android admission.

The initializer calls the existing native password admission independently for
all three devices. It creates mode-0700 browser profiles only for the two Linux
targets, retains the existing mode-0600 synthetic marker, and adds distinct
mode-0600 `d` and `da` identity markers. It does not create a filesystem
browser profile for OnePlus: the exact test package, APK hash, acceptance
metadata, complete prepared-directory inventory, and captured physical-USB
OnePlus identity are its boundary. The initializer also requires independently
captured d and da host receipts; it rejects the wrong hostname, shared
machine-id, non-x86_64 host, network ADB transport, emulator, wrong OnePlus
model, or a second phone.

All three admissions must report the same private source commit, Helium core
commit, Chromium commit, and four-component Chromium version. Both Linux runs
must additionally bind the same archive, Passwords commit, build-produced
deployment receipt, extracted schema-4 internal manifest, complete concrete
full-graph inventory, build job, and pinned depot_tools commit. Their locally
generated runtime receipts may differ
in paths and verification time. Mixing source trains, using two Linux
artifacts, or substituting a non-x86_64 runtime fails during initialization.
The output directory must not exist. Run the first identity capture on d, the
second on da, and the USB capture on the machine physically attached to the
OnePlus; transfer only those private receipts to the initializer.

```sh
(umask 077; node scripts/sync-runtime/execution-identity.mjs capture \
  --expected-host d > /secure/d-execution-identity.env)
(umask 077; node scripts/sync-runtime/execution-identity.mjs capture \
  --expected-host da > /secure/da-execution-identity.env)
(umask 077; node scripts/android-acceptance/physical-device-identity.mjs capture \
  --adb-serial "$oneplus_usb_serial" > /secure/oneplus-execution-identity.env)

node scripts/sync-runtime/three-client-acceptance.mjs init \
  --d-artifact "$d_verified_linux/helium-passwords-linux-x86_64/runtime/helium-wrapper" \
  --d-artifact-receipt "$d_verified_linux/artifact-receipt.env" \
  --d-execution-identity /secure/d-execution-identity.env \
  --da-artifact "$da_verified_linux/helium-passwords-linux-x86_64/runtime/helium-wrapper" \
  --da-artifact-receipt "$da_verified_linux/artifact-receipt.env" \
  --da-execution-identity /secure/da-execution-identity.env \
  --oneplus-artifact /absolute/oneplus-prepared/Browser-test.apk \
  --oneplus-execution-identity /secure/oneplus-execution-identity.env \
  --output /absolute/new/three-client-run
```

The returned `devices` map names `native-d`, `native-da`, and
`native-oneplus`. Complete
[`password-runtime-acceptance.md`](password-runtime-acceptance.md) and
[`password-runtime-sync-acceptance.md`](password-runtime-sync-acceptance.md)
in each sub-run with its exact admitted artifact. Launch the Android lifecycle
only through the prepared package's artifact-carried disposable-browser
boundary; never synthesize a OnePlus profile path.

## Required runtime flow

Use only the browser's native password store and CookieManager plus the normal
Helium Sync bridge.

1. Enroll `d` as the explicit seed. Create the synthetic password and complete
   the native save/update/generation/autofill/settings/delete protocol. Seed the
   complete controlled cookie fixture.
2. Enroll `da`, then `oneplus`, each pending and pull-only. Verify native
   password-store and CookieManager application/readback before promotion.
   Each joiner's initial password and cookie publication count must be zero.
3. Restart both unchanged Linux profiles and the unchanged Android test
   package. Hash each bridge state before and after and record zero password and
   cookie publications.
4. Update the password from `da`. Attempt the stale prior revision from
   `oneplus`; require a revision conflict and preservation of the newer value.
   Apply/read back the update on all three devices, then delete it from `da`,
   publish a tombstone, and verify the tombstone on all three.
5. Import the complete canonical cookie set into each joiner under a sealed
   destination snapshot. Read it back exactly, then issue a real HTTPS request
   to the controlled fixture and verify its authenticated response. Cover
   session/persistent, HttpOnly, Secure, SameSite, host-only/domain, and
   partitioned/unpartitioned identities.
6. Rotate one cookie twice from its authenticated source `d`. Both replicas
   must apply each newer revision exactly and publish no echo. A concurrent
   `oneplus` mutation against a further newer `d` revision must stop, retain the
   sealed rollback and last-good local session, and publish nothing. A repeated
   cycle must neither reapply nor echo.
7. A non-clonable classification is permitted only for one exact canonical
   record, revision, payload hash, and destination with content-free evidence
   of an observed destination rejection and exact rollback. An assumption or
   site-wide classification fails.
8. Record the origin-state observation for the exact authenticated origin on
   both joiners. Because no adapter is currently registered, local storage,
   IndexedDB, service-worker, cache, and other origin state must be reported as
   observed-not-required, not transferred. Tabs are absent from every input.

Browser evidence is a reviewed, content-free index over separately captured
raw runtime bundles. It must name
`native-password-store-and-cookie-manager` and, for each device, bind its
platform, target, package, artifact SHA-256, admission hashes, native
`sync-receipt.json` SHA-256, and Linux profile marker or Android null marker.
For each device,
`scripts/sync-runtime/fleet-runtime-evidence.mjs capture-device` copies the
actual client state, initial/restart/terminal PasswordStore bridge state,
CookieManager bridge state, initial/restart server journals, authenticated
request receipts, browser log, and exact execution identity into a private
checksum bundle. Browser claims must derive from those files.

Server evidence must come from the canonical marker-gated service at the exact
literal private-Tailnet IPv4 HTTP endpoint on port 44719. It names the shared
source/core/Chromium train, per-device bearer authentication, readable private
schema-2 journal, and content-free log scans. Evidence records only device,
cursor, revision, count, result, and journal-hash metadata; it never records a
password value or bearer token. Tabs must be absent from the journal. Capture
the exact endpoint rather than relying on a fixed lm address. Authenticated
request and HTTP-409 conflict receipts record the literal endpoint, the
`Bearer` scheme, and only the SHA-256 of the authorization value. The verifier
reconstructs the exact conflict error from the kind, key, rejected revision,
and current revision:

```sh
node scripts/sync-runtime/fleet-runtime-evidence.mjs capture-server \
  --endpoint "$tailnet_sync_endpoint" \
  --records-jsonl /private/server/records.jsonl \
  --server-log /private/server/server.log \
  --password-conflict-json /private/server/password-conflict.json \
  --cookie-conflict-json /private/server/cookie-conflict.json \
  --output /private/evidence/runtime-server
```

`capture-device` captures its own current d/da machine identity, or its own
physical OnePlus identity when `--device oneplus --adb-serial SERIAL` is used;
it never accepts a caller-supplied identity file. It uses the exact
`--client-{initial,restart,terminal}-json`,
`--password-{initial,restart,terminal}-json`,
`--cookie-{initial,restart,terminal}-json`,
`--journal-{initial,restart}-jsonl`, `--authenticated-requests-jsonl`, and
`--browser-log` inputs, plus `--device d|da|oneplus` and `--output`.

## Verify

```sh
node scripts/sync-runtime/three-client-acceptance.mjs verify \
  --run /absolute/three-client-run \
  --browser-evidence /absolute/browser-evidence.json \
  --server-evidence /absolute/server-evidence.json \
  --d-runtime-evidence /private/evidence/runtime-d \
  --da-runtime-evidence /private/evidence/runtime-da \
  --oneplus-runtime-evidence /private/evidence/runtime-oneplus \
  --server-runtime-evidence /private/evidence/runtime-server \
  --da-origin-audit /absolute/da-origin-audit.json \
  --oneplus-origin-audit /absolute/oneplus-origin-audit.json

node scripts/sync-runtime/three-client-acceptance.mjs status \
  --run /absolute/three-client-run
```

Verification rehashes all three executions, the returned Linux archive,
runtime and deployment receipts, internal provenance manifest and concrete
full-graph bundle, the complete
prepared Android inventory, both Linux markers, all three native screenshot and
Sync state/journal evidence, browser receipt, server receipt, and both origin
audits. It copies the admitted indexes and four private raw runtime bundles,
then writes a mode-0600 receipt atomically into `verified/`; an existing result
is never replaced. `status`
reports `passed` only after repeating that audit and matching the receipt to
the copied evidence; corruption does not degrade to a stale success label.

A source-test pass means the gate and canonical protocol foundations are ready.
It does not mean any browser artifact passed. Personal enrollment remains
blocked until all three native runtime receipts and the consolidated
three-device receipt exist for the exact returned artifacts. The fleet
finalizer additionally binds the returned Linux full-graph receipt to the same
archive, deployment job, internal manifest, and both desktop executions.
