# Sync Extension for Native Password Acceptance

Run the shared browser-generic protocol in
[`password-runtime-acceptance.md`](password-runtime-acceptance.md) first. This
private extension adds only the Helium Sync bridge assertions: exact revisions,
readable journal agreement, a deletion tombstone, and byte-identical no-op
restart state. Keeping these checks here leaves the public Passwords harness
independent of the private record schema.

The extension accepts only secret-free metadata from `password-state.json` and
the isolated readable server journal. It hashes any observed synthetic payload
for the receipt, rejects unknown fields and plaintext-shaped credential keys,
and never retains payload values. Never point it
at a personal profile, production Android app data, or a production server
journal.

The captured state must be schema 4 with identity
`password-form-unique-key-v2`, `migration_status` equal to `complete`, an empty
`legacy_credentials` map, and `credential/v2/<sha256>` keys. Stable acceptance
captures reject `pending_publication` and `queued_mutation`; those states must
first resolve through a remote pull.

## Capture

For each row below, first visually inspect and capture the public native UI
step. Immediately afterward, before advancing to another public step, capture
the disposable Sync metadata:

| Public step | Required private assertion |
| --- | --- |
| `saved_store` | The first verified browser write exists in bridge state and the readable journal. |
| `saved_restart_autofill` | State and complete journal hash equal `saved_store`. |
| `updated_store` | The same credential has one changed revision and fingerprint. |
| `updated_restart_autofill` | State and complete journal hash equal `updated_store`. |
| `deleted_store` | The next revision is a tombstone with an empty fingerprint. |
| `deleted_restart_empty` | State and complete journal hash equal `deleted_store`. |

The command pair for those six steps is:

```sh
node scripts/password-runtime/acceptance.mjs capture \
  --run "$run" --step STEP --screenshot /ABSOLUTE/SCREEN.png

node scripts/password-runtime/sync-acceptance.mjs capture \
  --run "$run" --step STEP \
  --password-state /ABSOLUTE/DISPOSABLE/password-state.json \
  --journal /ABSOLUTE/DISPOSABLE/records.jsonl
```

The private capture records the public screenshot hash. It refuses a delayed
or retroactive snapshot if the named public step is no longer the most recent
capture. A failure invalidates the run; start a new disposable result directory
rather than editing `run.json` or `sync-run.json`.

The private run is schema 2 and copies the public run's exact 256-bit
`run_nonce`. Capture and verification fail if either run has an older schema,
an absent or malformed nonce, or different nonces. The shared capture gate
accepts only a structurally complete PNG with valid chunk CRCs; the final
private verifier invokes the shared audit again and therefore revalidates every
PNG and its recorded SHA-256 before reading Sync metadata.

## Verify

After all twelve public steps and the six private snapshots, create the public
receipt and then the private receipt:

```sh
node scripts/password-runtime/acceptance.mjs verify \
  --run "$run" \
  --fixture-evidence "$run/fixture-evidence.json"

node scripts/password-runtime/sync-acceptance.mjs verify \
  --run "$run" \
  --fixture-evidence "$run/fixture-evidence.json"
```

The second command rehashes the browser artifact, every public screenshot, the
fixture evidence, and the exact schema-2 public receipt before checking Sync
metadata. The public receipt and fixture evidence must carry the same
`run_nonce` as both run files. It creates a schema-2, mode-0600
`sync-receipt.json`, bound to `receipt.json` and that nonce, and refuses to
replace an existing private receipt.

A pass proves one browser-originated save revision, exactly one update
revision, exactly one tombstone revision, and zero state or journal writes on
the three unchanged restarts. It does not replace the three-device stale-write,
pending-join, token-rotation, or malformed-record gates in
[`acceptance.md`](acceptance.md).
