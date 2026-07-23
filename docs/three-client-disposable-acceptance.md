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

Runtime completion still requires a compiled, receipt-bound browser and the
existing disposable TLS service. The gate validates the resulting evidence; it
does not invent browser UI or server observations.

## Initialize

Use one exact verified Linux browser input. The initializer reuses the public
native password admission code, creates `d`, `da`, and `oneplus` profile
directories with mode 0700 and the existing mode-0600 synthetic-only marker,
adds a distinct mode-0600 device identity marker to each, and records every
path and combined marker hash. The output directory must not exist.

```sh
node scripts/sync-runtime/three-client-acceptance.mjs init \
  --artifact /absolute/verified/runtime/helium-wrapper \
  --artifact-receipt /absolute/verified/artifact-receipt.env \
  --output /absolute/new/three-client-run
```

The returned `native_ui_run` is the `d` seed run. Complete
[`password-runtime-acceptance.md`](password-runtime-acceptance.md) and
[`password-runtime-sync-acceptance.md`](password-runtime-sync-acceptance.md)
there with the exact admitted artifact. `da` and `oneplus` use the other two
profile paths from `run.json`.

## Required runtime flow

Use only the browser's native password store and CookieManager plus the normal
Helium Sync bridge.

1. Enroll `d` as the explicit seed. Create the synthetic password and complete
   the native save/update/generation/autofill/settings/delete protocol. Seed the
   complete controlled cookie fixture.
2. Enroll `da`, then `oneplus`, each pending and pull-only. Verify native
   password-store and CookieManager application/readback before promotion.
   Each joiner's initial password and cookie publication count must be zero.
3. Restart all three unchanged profiles. Hash the bridge state before and after
   and record zero password and cookie publications.
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
`native-password-store-and-cookie-manager`, bind the exact
`sync-receipt.json` SHA-256, and bind all three profile marker hashes. Server
evidence must come from the canonical TLS service, name the exact private source
commit admitted by the artifact receipt, and record only device, cursor,
revision, count, result, and journal-hash metadata. It must not contain payloads,
credentials, tokens, nonces, or ciphertext.

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

Verification rehashes the artifact, artifact receipt, disposable markers,
native screenshots, native Sync state/journal evidence, browser receipt, server
receipt, and both origin audits. It copies the admitted content-free inputs and
a mode-0600 receipt atomically into `verified/`; an existing result is never
replaced. `status` reports `passed` only after repeating that audit and matching
the receipt to the copied evidence; corruption does not degrade to a stale
success label.

A source-test pass means the gate and canonical protocol foundations are ready.
It does not mean a browser artifact passed. Personal enrollment remains blocked
until the runtime receipt exists for the returned artifact and all three new
disposable profiles.
