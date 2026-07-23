# Per-origin Login-State Audit

Cookie replication does not prove that a login is portable. A site can also
depend on a device-bound session or on localStorage, IndexedDB, service-worker
storage, Cache Storage, or another origin-owned store. This audit records that
boundary without copying any of those stores.

`scripts/session-state/origin-state-audit.mjs` is a strict schema-2,
metadata-only
classifier. It accepts exact HTTPS origins, controlled test outcomes, opaque
evidence references, and the SHA-256 of one synthetic or disposable-browser
artifact. It rejects unknown fields, URL credentials, paths and query strings,
cookie values, tokens, and every unmodeled state kind. The CLI also hashes the
artifact itself and fails if it is absent, symlinked, oversized, or does not
match the declared digest.

Do not point either input at a real browser profile or an artifact made from
one. Until a disposable Helium binary exists, use only `synthetic` evidence.
The classifier does not collect browser evidence and is not an origin-state
export/import adapter.

## Evidence model

Each audit is bound to one target (`d`, `da`, or `oneplus`) and one artifact.
Every origin has:

- cookie apply, authenticated-session, and device-bound-session observations;
- zero or more unique state kinds from `local-storage`, `indexed-db`,
  `service-worker`, `cache-storage`, and `other-origin-state`, each with
  separate preview, apply, readback, and rollback results; and
- an opaque `evidence_ref` when and only when an observation was made.

An evidence reference is a correlation label, never a cookie name, value,
token, URL path, user identifier, or secret. `not-observed` means only that the
specific disposable run did not observe the condition; it is not proof that a
session is portable.

The classifications have deliberately narrow meanings:

| Classification | Meaning |
| --- | --- |
| `device-bound-observed` | Chromium reported a device-bound session in this disposable artifact; do not clone it. |
| `reauth-required-observed` | Cookie application or the resulting authenticated session failed on this target. |
| `destination-verified` | The controlled apply and authenticated check succeeded for this artifact and target only. |
| `cookie-only-insufficient` | Cookie readback succeeded but authentication was not verified. |
| `required-unsupported` | Controlled comparison showed an origin store was required, but no adapter exists. |
| `adapter-rejected-observed` | A future origin-scoped adapter ran and failed verification. |
| `not-required-observed` | A controlled disposable comparison did not need this origin-state kind. |
| `unknown` | The evidence is insufficient. |

Synthetic input can produce only labels beginning with `synthetic-` (or
`unknown` / `cookie-only-insufficient`). It can never create a concrete
portability claim. Even `destination-verified` does not generalize to another
device, browser build, site revision, or later token rotation.

The adapter registry is intentionally empty. An evidence file cannot invent an
adapter name and mark its own transfer successful. Source must first add one
reviewed, exact-origin adapter, and that adapter must separately prove preview,
apply, readback, and rollback. Until then, `adapter` must be `none` and every
transaction result must be `not-tested`; required state is classified
`required-unsupported`.

## Synthetic invocation

Create a non-secret fixture artifact and an evidence JSON file whose
`artifact_sha256` is that exact file's SHA-256, then run:

```sh
node scripts/session-state/origin-state-audit.mjs \
  /path/to/evidence.json /path/to/synthetic-artifact
```

The command writes classifications and opaque references to stdout. Its output
does not contain cookie values or origin-store data.

## Why automatic reauthentication is blocked

The cookie bridge can derive only the cookie's canonical identity and a
schemeful site. A cookie domain may cover several origins, and neither its
domain nor path identifies a login page. Chromium 150's password manager is
owned by a concrete `WebContents`; it discovers forms in that page and offers
native fill through its per-tab `PasswordManagerClient`. There is no safe
profile-level operation that takes a cookie site and starts a password login.
This boundary was checked against locked Chromium commit
`24b04c927b23c39cf9c5227cc8dc6f64a744c8e9` in
`components/password_manager/core/browser/password_manager_client.h` and
`chrome/browser/password_manager/chrome_password_manager_client.h`.

After a destination rejects a cookie, the bridge therefore restores and
readback-verifies the complete last-good local cookie snapshot, persists the
exception for exactly that record, revision, and encrypted-payload
fingerprint, and writes `cookie-reauth-required.json`. The signal deliberately
contains `schemeful_site`, `origin_status=unavailable-not-observed`,
`login_entry_status=unavailable-not-observed`,
`navigation_allowed=false`, and
`automatic_form_submission_allowed=false`. A same-revision remote record is
suppressed. A later local cookie mutation is held locally as unverified and is
not published as proof of login, which stops rotation ping-pong. A higher
authoritative remote revision may retry; concurrent local and remote changes
still fail closed.

A disposable-browser collector must provide the exact origin and verified
login entry before browser integration can open a local page and let
Chromium's normal password manager offer fill. Helium must never guess that
entry from the cookie domain, inject a credential, or submit a form.

## Why origin-state transfer is blocked

The pinned Chromium local-storage interface exposes per-key `Put`/`Delete` and
`GetAll`, but its own contract says a successful mutation reply does not prove
the value is still present because another page can race it. It has no
multi-key transaction for atomic replacement. IndexedDB, Cache Storage, and
service-worker data have still broader application-owned schemas. Copying or
live-merging those databases would not provide an atomic, validated transfer.
The checked locked interfaces are
`components/services/storage/public/mojom/local_storage_control.mojom`,
`third_party/blink/public/mojom/dom_storage/storage_area.mojom`, and
`content/public/browser/storage_partition.h`.

An eventual adapter must be exact-origin and evidence-specific, stop or
otherwise isolate writers, take a complete rollback snapshot, preview one
replacement, apply through a reviewed Chromium API, perform an independent
readback, and prove rollback into disposable state. The schema-2 transaction
fields make those gates explicit without transporting state values or
pretending an adapter exists.

## Browser gate still required

A disposable-browser collector must eventually produce the evidence and
artifact from the built browser. For each supported origin it must compare the
cookie-only result with the minimum origin state needed for authentication,
verify the destination through site behavior rather than mere cookie presence,
and record device-bound-session manager observations. Only an explicitly
implemented origin-scoped export/import adapter may handle evidenced required
state. Arbitrary application databases must never be merged, and no adapter is
implemented today.
