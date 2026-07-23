# Three-client disposable password and session gate

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
  the real `syncstore.Client`, authenticated `Handler`, E2EE records, d seed,
  pull-only enrollment, no-op publication suppression, CAS conflict,
  tombstones, credential/content-key rotation, cookie records, and 64-bit
  counters. The fake receipt test is not presented as protocol proof.

Runtime completion still requires three compiled, independently admitted
browser artifacts and the existing disposable TLS service. The gate validates
the resulting evidence; it does not invent browser UI or server observations.

## Initialize

Use the exact artifact for each execution environment:

- `d`: the Linux arm64 chroot executable and its verified Linux runtime receipt;
- `da`: the Linux x86_64 executable and its verified Linux runtime receipt; and
- `oneplus`: `Browser-test.apk` from the prepared
  `computer.helium.sync.test` directory. Its `acceptance.env`,
  `PACKAGE_SHA256SUMS`, and every inventoried runtime/provenance member are the
  Android admission.

The initializer calls the existing native password admission independently for
all three devices. It creates mode-0700 browser profiles only for the two Linux
targets, retains the existing mode-0600 synthetic marker, and adds distinct
mode-0600 `d` and `da` identity markers. It does not create a filesystem
browser profile for OnePlus: the exact test package, APK hash, acceptance
metadata, and complete prepared-directory inventory are its boundary.

All three admissions must report the same private source commit, Helium core
commit, Chromium commit, and four-component Chromium version. Mixing artifacts
from different builds or swapping the two Linux architectures fails during
initialization. The output directory must not exist.

```sh
node scripts/sync-runtime/three-client-acceptance.mjs init \
  --d-artifact /absolute/d-arm64/runtime/helium-wrapper \
  --d-artifact-receipt /absolute/d-arm64/artifact-receipt.env \
  --da-artifact /absolute/da-x86_64/runtime/helium-wrapper \
  --da-artifact-receipt /absolute/da-x86_64/artifact-receipt.env \
  --oneplus-artifact /absolute/oneplus-prepared/Browser-test.apk \
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

Browser evidence is an external, content-free JSON receipt because these
native UI and CookieManager operations cannot be truthfully reconstructed by a
source-only script. It must name
`native-password-store-and-cookie-manager` and, for each device, bind its
platform, target, package, artifact SHA-256, admission hashes, native
`sync-receipt.json` SHA-256, and Linux profile marker or Android null marker.
Server evidence must come from the canonical TLS service, name the exact shared
source/core/Chromium train, and record only device, cursor, revision, count,
result, and journal-hash metadata. It must not contain payloads, credentials,
tokens, nonces, or ciphertext.

## Verify

```sh
node scripts/sync-runtime/three-client-acceptance.mjs verify \
  --run /absolute/three-client-run \
  --browser-evidence /absolute/browser-evidence.json \
  --server-evidence /absolute/server-evidence.json \
  --da-origin-audit /absolute/da-origin-audit.json \
  --oneplus-origin-audit /absolute/oneplus-origin-audit.json

node scripts/sync-runtime/three-client-acceptance.mjs status \
  --run /absolute/three-client-run
```

Verification rehashes all three artifacts, both Linux receipts, the complete
prepared Android inventory, both Linux markers, all three native screenshot and
Sync state/journal receipts, browser receipt, server receipt, and both origin
audits. It copies the admitted content-free inputs and a mode-0600 receipt
atomically into `verified/`; an existing result is never replaced. `status`
reports `passed` only after repeating that audit and matching the receipt to
the copied evidence; corruption does not degrade to a stale success label.

A source-test pass means the gate and canonical protocol foundations are ready.
It does not mean any browser artifact passed. Personal enrollment remains
blocked until all three native runtime receipts and the consolidated
three-device receipt exist for the exact returned artifacts.
