# Helium Browser Development

This repository is the public backbone for both Helium Passwords and the
private Helium Sync product. Helium Sync must remain a downstream Git history:
it periodically merges this repository's `main` branch, keeps the two password
patches byte-identical, and adds private sync behavior afterward.

## Repository Roles

| Repository | Visibility | Responsibility |
| --- | --- | --- |
| `dhruv9saini/helium-passwords` | Public | Password-manager restoration, desktop platform preparation, shared developer command, and public acceptance criteria |
| `dhruv9saini/helium-sync` | Private | Personal sync, Android, device integration, cookie handling, and tab durability layered on Passwords |

The supported local layout is:

```text
/home/d/coding/helium/
├── helium-passwords/
└── helium-sync/
```

The private repository should have a remote named `passwords` pointing at the
public repository. A backbone update is a normal Git merge, not a file copy:

```sh
git fetch passwords
git merge --no-ff passwords/main
scripts/dev.sh check
```

Never merge the public `push-sync` branch into either `main`. It is a preserved,
diverged experiment rather than an update branch.

## Current Evidence

The state observed on 2026-07-22 is intentionally recorded here so that a smoke
test is not mistaken for product validation:

- The checked-in `helium-chromium` submodule is exact Helium `0.14.8` commit
  `81bb0219ad6df2adefd12f42ca79198f049f1497`, based on Chromium
  `150.0.7871.181` at exact Chromium commit
  `24b04c927b23c39cf9c5227cc8dc6f64a744c8e9`.
- The Linux platform is pinned to exact commit
  `9fbdff55283c9275f285c49dc054a1ff38dcdc96`, whose gitlink resolves to that
  Helium core. The commit identifies itself as the `0.14.8.1` update; no release
  tag existed when it was selected, so preparation fetches the immutable commit
  directly rather than following moving `main`.
- Upstream still applies four direct password/autofill removals, plus several UI
  cleanup patches that remove password-manager entry points.
- The current public patches were refreshed for Chromium 150. A focused
  official-source replay proves they apply after the real ordered Helium series
  at `150.0.7871.181`; they have not yet been compiled or exercised in a browser.
- The six fast CI matrix jobs only prove that wrapper injection produced the
  expected patch filenames. They do not apply the patches to Chromium.
- The last dispatched full build, from 2026-06-05 through 2026-06-07, packaged
  Linux x86_64 and arm64 and collected macOS arm64. Windows failed in a later
  stage and macOS x86_64 failed late. No automated password lifecycle test ran
  against those artifacts.

Therefore `main` is an auditable patch overlay, not a currently validated
browser release.

## One Developer Command

Use the same entry point in both repositories:

```sh
scripts/dev.sh status
scripts/dev.sh check
scripts/dev.sh smoke linux x86_64
```

`check` is deliberately lightweight and never downloads Chromium. In the
public repository it validates every shell script and the Helium patch tree. In
the private repository the inherited command additionally checks JavaScript,
Python, Go tests/vet/builds, public-backbone ancestry, and byte identity of the
password patches.

`smoke` clones a small platform repository into a disposable temporary
directory, verifies overlay injection, and removes only that generated
checkout. It still does not prove that a patch applies to Chromium or that
browser behavior works.

Run the focused source-backed Passwords gate separately because it downloads
15 official Chromium files and `scripts/dev.sh check` intentionally remains
offline/lightweight:

```sh
scripts/check-password-patch-stack.sh
```

The checker replays the Chromium 150 Helium patch order, skips only the
password-disable patch exactly as platform preparation does, applies both
restoration patches, and asserts the restored preference, native UI actions,
menu, settings redirect, and importer paths. It is not a compile or runtime
test.

## Upstream Update Train

Treat Helium core plus its three desktop platform repositories as one immutable
train. Never build an unrecorded mixture of moving `main` branches.

1. Fetch the latest public repo, Helium core tags, and the Linux/macOS/Windows
   platform refs. Linux fetches full commit
   `9fbdff55283c9275f285c49dc054a1ff38dcdc96` directly and fails unless `HEAD`
   is that value; the commit, not a moving branch or absent tag, is the trusted
   input and is recorded in the artifact manifest. Record exact commit IDs and
   the Chromium version for every other platform before building.
2. Select one Helium release train. Update the submodule and platform refs in a
   single commit.
3. Materialize each platform and confirm that all three resolve to the same
   Helium core and Chromium versions.
4. Refresh the password patches against that exact Chromium tree. Review every
   upstream patch containing `password`, `autofill`, `PasswordManager`,
   `ManagePasswords`, or related action IDs. Restoring only the mandatory
   policy is insufficient because Helium also removes settings, app-menu,
   omnibox, toolbar, importer, and suggestion surfaces.
5. Run `scripts/dev.sh check` and the focused patch-stack checker, then run the
   complete patch-application check against a prepared Chromium source tree on
   chromiumer.
6. Build the smallest Linux target first. Only after it compiles, run native
   password acceptance tests in a disposable profile.
7. Build the other desktop targets. Archive an artifact manifest containing
   repo commits, submodule commit, Chromium version, GN args, patch hashes,
   platform, architecture, and artifact hash.
8. Merge the validated public commit into Helium Sync through its `passwords`
   remote. Regenerate or rebase private overlays only after the public gate is
   green.

Do not run a Chromium build on `lm`; the 2026-07-21 audit found only 19 GB free.
All large Linux and Android work is orchestrated from lm and executed through
the fail-closed chromiumer wrapper in
[`docs/chromiumer-builds.md`](docs/chromiumer-builds.md).

## Password Acceptance Gate

Every release artifact must pass these tests in a new disposable profile. A
settings page rendering is not enough.

The artifact-bound protocol, exact native UI sequence, evidence format, and
cleanup rules are executable through
[`scripts/password-runtime/acceptance.mjs`](scripts/password-runtime/acceptance.mjs)
and documented in
[`docs/password-runtime-acceptance.md`](docs/password-runtime-acceptance.md).
Linux admission now requires the receipt from the strict returned-runtime
verifier. The gate is source-complete but still needs a compiled artifact
receipt.

For quick form-shape checks that do not claim browser behavior, start the
repository-owned stateless synthetic origin with:

```sh
node scripts/password-lifecycle-fixture.mjs
```

It binds only `127.0.0.1`, chooses an ephemeral port by default, prints that
origin, and provides login plus password-change forms. It discards submitted
bodies without parsing, storing, logging, or reflecting them. Its HTTP tests do
not claim that browser save prompts or autofill pass; those require the
artifact-bound gate.

1. Confirm `PasswordManagerEnabled` and passkey policy are not forcibly false.
2. Open the password manager from settings, the app menu, the omnibox action,
   and the toolbar/page action where supported.
3. Submit a deterministic HTML login form and verify exactly one save prompt.
4. Save the credential, restart cleanly, and verify it remains in the native
   password store.
5. Revisit the form and verify username and password suggestions plus autofill.
6. Change the password and verify an update prompt and the updated stored value.
7. Reject saving and verify the decision is honored without disabling later
   saves for unrelated sites.
8. Verify incognito and guest sessions do not persist credentials.
9. Import a small fixture through the supported native importer and verify
   password and form-data capability separately.
10. Repeat with a crash/restart and confirm the password database remains
    readable.

Tests must use fixture credentials and disposable profiles. Never point them at
a real profile or print stored values in logs.

## Build Capacity

Dedicated, non-interactive SSH from lm to chromiumer is working. The enforced
wrapper, health watchdog, immutable source transfer, artifact return, and
cleanup contract are documented in
[`docs/chromiumer-builds.md`](docs/chromiumer-builds.md). Every job declares a
disk budget: use 80 GiB for the bounded compile proof and 100 GiB for a full
build. The existing SSD passes the bounded-proof disk gate while keeping a
2 GiB unprivileged root floor in addition to ext4's 5.91 GiB root-only reserve.
The exact public Linux expression is realized at the expression-hash-named GC
root `chromium-150-a0820646387c653b`. Its returned provenance binds the current
expression, Chromium/nixpkgs pins, derivation, output, and complete closure; a
fresh 80 GiB preflight passed after realization and cleanup. The direct Linux
driver deliberately avoids Docker so compiler processes, temporary files, and
outputs remain inside the enforced cgroup and workspace accounting. Its 7.6
GiB RAM with no swap may still make compilation fail inside the deliberately
strict 5 GiB cgroup limit. The serialized Android validation train currently
owns chromiumer admission; the public build waits for its explicit handoff.
Browser validation must use chromiumer and must not fall back to lm.

The build wrapper also requires a job-specific result summary and success
action before startup. Its terminal-state notification path is installed on
lm, survives shell and host restarts, and is documented in
[`docs/job-notifications.md`](docs/job-notifications.md). Chromiumer never
receives mail credentials. Codex turn hooks are intentionally not part of this
path because they run at turn scope and would notify for routine agent work.

## References

- Chromium Android build requirements and target:
  <https://chromium.googlesource.com/chromium/src/+/main/docs/android_build_instructions.md>
- Chromium password-manager architecture:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/components/password_manager/README.md>
- Current upstream Helium: <https://github.com/imputnet/helium>
