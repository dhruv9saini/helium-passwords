# Native Password Runtime Acceptance

This is the executable gate for HS-008 after a hash-verified Linux browser or
parallel Android test APK returns from chromiumer. It never operates on a
personal profile or the production Android package. It does not use an
extension, `chrome.passwordsPrivate`, the historical CDP password writer, or a
raw password database.

The gate combines three independent observations:

1. native UI screenshots, inspected by Codex before each capture;
2. a loopback fixture attestation that compares submitted synthetic
   credentials in memory without writing or returning their values; and
3. the native bridge's secret-free `password-state.json` plus metadata and a
   hash from the isolated opaque journal.

The final verifier proves that one credential was published, survived an
unchanged restart without another journal write, changed by exactly one
revision, survived a second unchanged restart, became the next revision's
tombstone, and stayed unchanged after deletion/restart. Screenshot hashes make
the inspected native prompt/settings/suggestion evidence immutable. The
verifier does not interpret pixels; a screenshot must be captured only after
Codex has visually confirmed the named native surface.

## Admission

Use a new result directory and the exact returned artifact. For Linux, `init`
creates the only allowed profile below the result directory. Launch the
returned browser with that exact `--user-data-dir`; never substitute an
existing profile.

```sh
run=/srv/nas/helium-acceptance/PASSWORD_JOB
node scripts/password-runtime/acceptance.mjs init \
  --artifact /srv/nas/helium-acceptance/PASSWORD_JOB/bin/helium \
  --platform linux \
  --output "$run"

# First verify the extracted executable against the returned artifact receipt.
# Launch that exact admitted executable using:
#   --user-data-dir="$run/profile"
```

For Android, first pass `verify-android-artifact.sh`. `init` accepts only the
parallel test identity, which must coexist with and remain separate from
`computer.helium.sync`. It also requires the prepared directory's matching
`acceptance.env` and `PACKAGE_SHA256SUMS`, so a package-name argument alone
cannot admit an arbitrary APK:

```sh
node scripts/password-runtime/acceptance.mjs init \
  --artifact /srv/nas/helium-acceptance/JOB/Browser-test.apk \
  --platform android \
  --package computer.helium.sync.test \
  --output "$run"
```

Clearing or uninstalling is permitted only for
`computer.helium.sync.test`. Never run `pm clear` against the production
package. Stage enrollment, bridge state, and journal evidence only in the
disposable test namespace. On Linux, prefer a run-local loopback
`helium-syncd` under `$run/server`; on Android, use a separately initialized
synthetic endpoint and copy only the test package's metadata state for each
capture. Do not read `Login Data`, app data from `computer.helium.sync`, or any
personal profile.

Start the stateful fixture and keep it running across browser restarts:

```sh
node scripts/password-runtime/fixture-server.mjs \
  --port 44722 \
  --evidence "$run/fixture-evidence.json"
```

The fixture binds only `127.0.0.1`. For Android, expose that exact port with
one bounded `adb reverse` entry and remove only that entry during cleanup. The
fixture stores only SHA-256 comparisons in memory and writes no submitted
username or password. Its evidence file is create-new and appears only after
the complete ordered lifecycle.

## Ordered native lifecycle

Use one synthetic username and synthetic passwords. Never place their values
in filenames, commands that are retained as evidence, browser logs, or the
capture receipt. For every row, inspect the UI, take a PNG screenshot, then
run `capture`. The screenshot source may be overwritten after capture; the
harness copies it to a mode-0600 step-specific file.

| Step | Required action and observation | Metadata snapshot |
| --- | --- | --- |
| `settings_entry` | Open the app menu/settings entry and verify the native password-manager surface opens. | No |
| `save_prompt` | On `/login`, type the initial fixture credential, submit, verify the native save prompt, then accept Save. | No |
| `saved_store` | Open the native password manager and verify exactly the fixture entry is present. Wait for the bridge publication. | Yes |
| `suggestions` | Cleanly restart, return to `/login`, focus the fields without typing, and verify the native suggestion surface. | No |
| `saved_restart_autofill` | Select the native suggestion and submit without typing. The fixture must accept the exact original credential. | Yes; must equal `saved_store` and leave the journal hash unchanged |
| `generation` | Open `/change-password`, focus the new-password field, verify the native generated-password surface, and accept it. | No |
| `update_prompt` | Submit the change form, verify the native update prompt, then accept Update. | No |
| `updated_store` | Verify the same native fixture entry exists with the new generated password and wait for bridge publication. | Yes |
| `updated_restart_autofill` | Cleanly restart and submit `/login` using only native fill. The fixture must accept the updated credential. | Yes; must equal `updated_store` and leave the journal hash unchanged |
| `delete` | Delete the fixture entry through the native settings surface and verify the native confirmation/result. | No |
| `tombstone` | Verify the native entry is absent and wait for bridge publication. | Yes; must be the next revision and `deleted=true` |
| `deleted_restart_empty` | Cleanly restart, return to `/login`, verify no fixture suggestion appears and both fields stay empty, then click “Confirm empty after native deletion.” | Yes; must equal `tombstone` and leave the journal hash unchanged |

Capture a UI-only step with:

```sh
node scripts/password-runtime/acceptance.mjs capture \
  --run "$run" --step STEP --screenshot /ABSOLUTE/SCREEN.png
```

For the six metadata steps, also supply new point-in-time copies of the
disposable state and journal:

```sh
node scripts/password-runtime/acceptance.mjs capture \
  --run "$run" --step STEP --screenshot /ABSOLUTE/SCREEN.png \
  --password-state /ABSOLUTE/DISPOSABLE/password-state.json \
  --journal /ABSOLUTE/DISPOSABLE/records.jsonl
```

The capture command parses the state and journal but retains only schema-3
credential fingerprints/revisions/deletion/key IDs, password-record metadata,
and the complete journal hash. It rejects unexpected state fields, plaintext-
shaped record keys, malformed counters, symlinks, non-PNG screenshots,
out-of-order steps, and a second capture of the same step.

After the fixture writes its evidence, finalize once:

```sh
node scripts/password-runtime/acceptance.mjs verify \
  --run "$run" \
  --fixture-evidence "$run/fixture-evidence.json"
```

`verify` rehashes the admitted artifact and every captured screenshot, checks
the Linux synthetic-profile marker or Android test package, validates the
fixture's loopback/no-secret contract, and enforces revisions `N`, `N+1`, and
`N+2` for save, update, and tombstone. It creates `receipt.json` with mode 0600
and refuses to replace an existing receipt.

## Failure and cleanup

Any missing prompt, wrong native surface, unexpected credential, rejected
fixture submission, changed no-op journal hash, malformed state, revision gap,
or absent tombstone fails the run. Preserve the failed result directory as
evidence and initialize a new directory for another artifact/run. Do not edit
or reuse a failed `run.json`.

Stop only the disposable browser and fixture. Remove only ADB reverse/forward
entries created for this run. Keep the artifact, receipt, screenshots, and
synthetic server evidence until the program audit is complete. No successful
runtime receipt authorizes a personal-profile install; the separate backup,
three-device enrollment, and rollout gates still apply.
