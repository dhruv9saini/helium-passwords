# Native Password Runtime Acceptance

This is the executable browser gate for HP-002 and HP-008 after a verified
Linux browser or Android test APK returns from the build host. It uses only a
new disposable profile or a separately installable Android package ending in
`.test`. It does not use an extension, `chrome.passwordsPrivate`, CDP to write
passwords, or a raw password database.

The gate combines two independent observations:

1. native UI screenshots, inspected by Codex before each capture; and
2. a loopback fixture that compares submitted synthetic credentials in memory
   without writing or returning their values.

The fixture proves that the browser submitted the saved password after a
restart, submitted the changed password after a second restart, and left the
login form empty after native deletion. The screenshot sequence proves that
those fixture observations came through the native settings, prompt,
suggestion, generation, update, storage, and delete surfaces. The verifier
does not interpret pixels: capture a screenshot only after Codex has visually
confirmed the named native surface. Hashes make that reviewed evidence
immutable and bind it to the admitted browser artifact.

Initialization also creates one random, non-secret run nonce. The fixture
copies that nonce into its create-new evidence file, and final verification
requires an exact match. Evidence from an older successful fixture lifecycle
therefore cannot be reused to admit a new artifact or screenshot sequence.

## Admission

First run `scripts/verify-linux-runtime.sh` on lm as documented in
`chromiumer-builds.md`. Transfer the resulting verified directory and its
mode-0600 receipt to da through the existing trusted artifact path without
changing either file. On da, use a new result directory. `init` requires the
verifier receipt, rehashes the admitted executable, and creates the only
allowed profile below the result directory. Launch that exact executable with
that exact `--user-data-dir`; never substitute an existing profile.

The audited da host has Node 24.18.0 installed through mise, but its
non-interactive SSH `PATH` does not expose `node` directly. Use the verified
mise entry point for every harness command:

```sh
node_runtime=(mise exec node@24.18.0 -- node)
verified=/PATH/ON/DA/verified
browser="$verified/helium-passwords-linux-x86_64/runtime/helium-wrapper"
artifact_receipt="$verified/artifact-receipt.env"
run=/home/d/.local/state/helium-password-acceptance/PASSWORD_JOB
"${node_runtime[@]}" scripts/password-runtime/acceptance.mjs init \
  --artifact "$browser" \
  --artifact-receipt "$artifact_receipt" \
  --platform linux \
  --output "$run"

# Launch only the artifact passed above, with:
#   --user-data-dir="$run/profile"
```

For Android, first prepare and verify the build output. The artifact directory
must contain `Browser-test.apk`, `acceptance.env`, and `PACKAGE_SHA256SUMS`.
The package named by both the APK metadata and `--package` must end in `.test`,
which keeps the acceptance app separate from a production installation:

```sh
"${node_runtime[@]}" scripts/password-runtime/acceptance.mjs init \
  --artifact /srv/nas/helium-acceptance/JOB/Browser-test.apk \
  --platform android \
  --package computer.helium.passwords.test \
  --output "$run"
```

Clearing or uninstalling is permitted only for the admitted `.test` package.
Do not read any other app data, `Login Data`, or a personal profile.

Start the stateful fixture and keep it running across browser restarts:

```sh
run_nonce=$(jq -er .run_nonce "$run/run.json")
"${node_runtime[@]}" scripts/password-runtime/fixture-server.mjs \
  --port 0 \
  --run-nonce "$run_nonce" \
  --evidence "$run/fixture-evidence.json"
```

Record the emitted loopback origin and use it for every lifecycle step. The
fixture binds only `127.0.0.1`; port `0` asks the kernel for an unused local
port instead of colliding with another fixture. For Android, expose that exact port with one bounded
`adb reverse` entry and remove only that entry during cleanup. The fixture
stores only SHA-256 comparisons in memory and writes no submitted username or
password. Its create-new evidence file appears only after the complete ordered
lifecycle and is bound to this run's public nonce.

## Ordered native lifecycle

Use one synthetic username and synthetic passwords. Never place their values
in filenames, commands retained as evidence, or browser logs. For every row,
inspect the native UI, take a PNG screenshot, and then run `capture`. The
harness copies the screenshot to a mode-0600 step-specific file.

| Step | Required action and observation |
| --- | --- |
| `settings_entry` | Open the app menu/settings entry and verify the native password-manager surface opens. |
| `save_prompt` | On `/login`, type the initial fixture credential, submit, verify the native save prompt, and accept Save. |
| `saved_store` | Open the native password manager and verify exactly the fixture entry is present. |
| `suggestions` | Cleanly restart, return to `/login`, focus the fields without typing, and verify the native suggestion surface. |
| `saved_restart_autofill` | Select the native suggestion and submit without typing. The fixture must accept the exact original credential. |
| `generation` | Open `/change-password`, focus the new-password field, verify the native generated-password surface, and accept it. |
| `update_prompt` | Submit the change form, verify the native update prompt, and accept Update. |
| `updated_store` | Verify the same native fixture entry exists with the new generated password. |
| `updated_restart_autofill` | Cleanly restart and submit `/login` using only native fill. The fixture must accept the updated credential. |
| `delete` | Delete the fixture entry through the native settings surface and verify the native confirmation. |
| `deleted_store` | Verify the fixture entry is absent from the native password manager. |
| `deleted_restart_empty` | Cleanly restart, verify no fixture suggestion appears and both login fields stay empty, then click “Confirm empty after native deletion.” |

Capture each step immediately after inspection:

```sh
"${node_runtime[@]}" scripts/password-runtime/acceptance.mjs capture \
  --run "$run" --step STEP --screenshot /ABSOLUTE/SCREEN.png
```

The command rejects non-PNG input, truncated or checksum-invalid PNG chunks,
symlinks, unexpected or out-of-order steps, duplicate arguments, and a second
capture of the same step. No command accepts password values or a
password-store path.

After the fixture writes its evidence, finalize once:

```sh
"${node_runtime[@]}" scripts/password-runtime/acceptance.mjs verify \
  --run "$run" \
  --fixture-evidence "$run/fixture-evidence.json"
```

`verify` rehashes the artifact, the Linux provenance receipt, and every
captured screenshot; rechecks the Linux synthetic-profile marker or Android
test-package admission; and verifies the fixture's loopback/no-secret
contract. It creates `receipt.json` with mode 0600 and refuses to replace an
existing receipt.

## Failure and cleanup

Any missing prompt, wrong native surface, unexpected credential, rejected
fixture submission, modified artifact or screenshot, incomplete sequence, or
non-test Android identity fails the run. Preserve a failed result directory as
evidence and initialize a new directory for another attempt. Do not edit or
reuse a failed `run.json`.

Stop only the disposable browser and fixture. Remove only ADB reverse/forward
entries created for this run. Keep the artifact, receipt, screenshots, and
synthetic fixture evidence until the program audit is complete. A successful
receipt does not authorize installation into a personal profile.
