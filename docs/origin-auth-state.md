# Per-origin Login-State Audit

Cookie replication does not prove that a login is portable. A site can also
depend on a device-bound session or on localStorage, IndexedDB, service-worker
storage, Cache Storage, or another origin-owned store. This audit records that
boundary without copying any of those stores.

`scripts/session-state/origin-state-audit.mjs` is a strict metadata-only
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
  `service-worker`, `cache-storage`, and `other-origin-state`; and
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

## Synthetic invocation

Create a non-secret fixture artifact and an evidence JSON file whose
`artifact_sha256` is that exact file's SHA-256, then run:

```sh
node scripts/session-state/origin-state-audit.mjs \
  /path/to/evidence.json /path/to/synthetic-artifact
```

The command writes classifications and opaque references to stdout. Its output
does not contain cookie values or origin-store data.

## Browser gate still required

A disposable-browser collector must eventually produce the evidence and
artifact from the built browser. For each supported origin it must compare the
cookie-only result with the minimum origin state needed for authentication,
verify the destination through site behavior rather than mere cookie presence,
and record device-bound-session manager observations. Only an explicitly
implemented origin-scoped export/import adapter may handle evidenced required
state. Arbitrary application databases must never be merged, and no adapter is
implemented today.
