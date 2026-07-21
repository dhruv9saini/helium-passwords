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

The state observed on 2026-07-21 is intentionally recorded here so that a smoke
test is not mistaken for product validation:

- The checked-in `helium-chromium` submodule is Helium `0.12.4`, based on
  Chromium `148.0.7778.178`.
- Upstream Helium is already `0.14.7`, based on Chromium `150.0.7871.128`.
- Upstream still applies four direct password/autofill removals, plus several UI
  cleanup patches that remove password-manager entry points.
- The current public patches were refreshed for Chromium 148. A focused
  official-source replay now proves they apply after the real ordered Helium
  series; they have not been compiled on 148 or rebased to Chromium 150.
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

The checker replays the Chromium 148 Helium patch order, skips only the
password-disable patch exactly as platform preparation does, applies both
restoration patches, and asserts the restored preference, native UI actions,
menu, settings redirect, and importer paths. It is not a compile or runtime
test.

## Upstream Update Train

Treat Helium core plus its three desktop platform repositories as one immutable
train. Never build an unrecorded mixture of moving `main` branches.

1. Fetch the latest public repo, Helium core tags, and the Linux/macOS/Windows
   platform refs. Record exact commit IDs and the Chromium version.
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
[`docs/chromiumer-builds.md`](docs/chromiumer-builds.md). Chromiumer still
cannot pass production preflight: an empty job requires 120 GiB available (a
100 GiB job-tree allowance plus a separate 20 GiB operational reserve), but
the entire root filesystem is only 116 GiB and exposes about 106 GiB free. It
also lacks the pinned build toolchain. GitHub Actions in
the private repo is independently blocked before job startup by the account
billing/spend limit. Full browser validation remains blocked until chromiumer
capacity/tooling is provisioned; it must not fall back to lm.

## References

- Chromium Android build requirements and target:
  <https://chromium.googlesource.com/chromium/src/+/main/docs/android_build_instructions.md>
- Chromium password-manager architecture:
  <https://chromium.googlesource.com/chromium/src/+/HEAD/components/password_manager/README.md>
- Current upstream Helium: <https://github.com/imputnet/helium>
