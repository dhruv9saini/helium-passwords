# Chromiumer Build Execution

`lm` is the control plane for Helium development. `chromiumer` is the only
approved Linux executor for large Helium or Chromium builds. Never start a full
browser build on `lm`, and never use the NAS as a live compiler workspace.
macOS and Windows artifacts still require their matching native builders; this
workflow covers Linux Helium and Linux-hosted Android Chromium work.

## Connection

The dedicated non-interactive connection is:

```text
SSH alias:       chromiumer
Tailscale DNS:   chromiumer.tail0168aa.ts.net
Remote user:     d
lm private key:  /home/d/.ssh/helium_chromiumer_ed25519
lm public key:   /home/d/.ssh/helium_chromiumer_ed25519.pub
Key fingerprint: SHA256:BLwzylKz36GigVYQQEbEhRLDHJkjTDSaVuSXbLOtsEw
```

The private key is machine state, not repository content. The matching public
key is appended to `d`'s `authorized_keys` on chromiumer. `/home/d/.ssh/config`
selects this identity, requires the recorded host key, disables interactive
authentication, and sends keepalives.

Verify it from `lm` before every source transfer:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/chromiumer-job.sh connection
scripts/chromiumer-job.sh preflight 80
```

`connection` must report `connection=ok`, `host=chromiumer`, and `user=d`.
`preflight` is deliberately stricter and must succeed before staging.

## Enforced Production Policy

The **local wrapper** is `scripts/chromiumer-job.sh` in the Helium checkout on
`lm`. “Local” means it is the control client: it validates job IDs and a clean
Git tree, materializes a shallow detached checkout of the superproject `HEAD`
together with the exact `helium-chromium` gitlink commit, transfers that
checkout as one archive, and provides the one interface for
start/status/logs/cancel/fetch/cleanup. It does not compile and it does not
enforce cgroups on `lm`.

The local wrapper installs the matching `scripts/chromiumer-worker.sh` as
`~/.local/libexec/helium-chromiumer-worker` on chromiumer. That **remote
worker** performs capacity admission and starts a detached transient user
systemd service in its own cgroup plus a separate health-watchdog service.

| Resource | Production bound |
| --- | --- |
| Compiler/build jobs | `2`; exported as `HELIUM_BUILD_JOBS`, `AUTONINJA_JOBS`, `NINJA_JOBS`, and `GCLIENT_JOBS` |
| CPU | hard `200%` quota, weight `10`, nice `15` |
| Memory | `4G` high, `5G` hard max, `0` swap inside the unit |
| I/O | weight `10`, Linux idle I/O scheduling class |
| Processes/threads | `TasksMax=256` |
| Job tree | explicit per-job allocated-block budget; `80 GiB` is the bounded-proof recommendation and `100 GiB` is the full-build recommendation |
| Root free space | `2 GiB` unprivileged floor, independent of the job budget and checked on `/` |
| Host available memory | `2 GiB` required at start; watchdog stops after two readings below `1 GiB` |
| Watchdog | independent unit: `10%` CPU, weight `10`, `64M` memory high / `128M` hard max, `0` swap, idle I/O, nice `15`, `TasksMax=16` |
| Wall time | hard `8h` systemd deadline |
| Concurrency | one active `helium-job-*` service on chromiumer |

There is no global 100 GiB class and no build-filesystem reserve. Every
production job declares a positive whole-GiB budget at `preflight` and `stage`.
The budget covers its source, output, temporary files, and redirected caches.
Use `80` for the first bounded source/compile proof and `100` for a full build;
these are command choices, not hidden defaults. The harmless wrapper test uses
`1 GiB`.

The old worker coupled a fixed 100 GiB job ceiling to a fixed 20 GiB free-space
reserve and consequently required 120 GiB for every production job. The
20 GiB value was local Helium policy, not a Chromium requirement, and there
was no measured host consumer that justified it. It also made a bounded proof
indistinguishable from a full build.

The current admission arithmetic is:

```text
remaining job budget = declared job budget - current job-tree use

build tree on /: required build-filesystem availability
                 = remaining job budget + 2 GiB root floor

build tree on another filesystem: required build-filesystem availability
                                  = remaining job budget
                                  and / must independently have 2 GiB free
```

For example, an empty 80 GiB job on the current root filesystem requires
82 GiB available. After it has allocated 10 GiB, startup requires 72 GiB. On a
separate build filesystem those numbers are 80 GiB and 70 GiB; the separate
filesystem does not inherit a global reserve. If the job tree already exceeds
its declared budget, startup fails.

The 2 GiB root floor is local host policy, not Chromium policy. It preserves
unprivileged SSH, user-systemd, watcher, and state operations. It is intentionally
small because the current ext4 root already reserves 1,549,785 blocks of 4096
bytes for root: 6,347,919,360 bytes (5.91 GiB) that the unprivileged build user
cannot consume. At the audit, the journal used 16 MiB, Helium state used
106 KiB, and all of `/home/d` used about 355 MiB. The 2 GiB floor is additional
to ext4's root-only reserve.

The worker measures allocated filesystem blocks rather than apparent file
sizes. It streams [GNU `find`'s `%b` size directive][gnu-find-blocks] into a
constant-size sum; `%b` is the allocated space for each entry in 512-byte
blocks. GNU
[`-ignore_readdir_race`](https://www.gnu.org/software/findutils/manual/html_node/find_html/Directories.html)
suppresses only entries that disappear after their parent directory was read,
which is normal while Git or Ninja mutates a tree. It does not suppress every
active-tree race: a directory can disappear after `find` has begun traversing
it. A failed scan is discarded and retried once from the root. A repeated
failure, an inconsistent exit status, or invalid counter output is fatal and
stops the job. The stream retains no path or inode table. Multiple directory
entries for one hard-linked file are counted more than once, a conservative
early stop rather than an undercount. The ceiling is polled, not an ext4
project quota, so a job can briefly cross the budget between completed scans.

Admission requires cgroup v2 CPU, memory, I/O, and PID controllers, a running
user systemd manager, the standard supervision tools, the job's remaining disk
budget, the root floor, and the memory floors. The wrapper intentionally does
not prescribe Git, Python, depot_tools, or Docker: the build command must enter
the pinned tool environment that provides them. Provision that environment
before a long job so Nix store downloads do not consume the root floor during
the build. Any failed infrastructure check refuses startup.

The watchdog runs allocated-block accounting asynchronously. Every supervisor
second, including while that scan runs and during the 30-second delay before
the next scan, it takes a fresh `/` free-space reading and a fresh
`MemAvailable` reading. A root-floor breach stops the build on that check; two
consecutive low-memory readings stop it on the second check. Disk-budget
evaluation occurs only after one complete valid scan. A scan-command failure,
with or without a diagnostic, is retried exactly once because a
concurrent build-tree mutation can invalidate a traversal. The partial count is
never used. `disk-scan-retry.env` records the retry, and the first stderr is
preserved verbatim in `disk-scan-first-error.log`. A second consecutive scan
failure remains fatal. `health.env` is then atomically replaced with the
successful disk result and the latest fresh filesystem, memory, and load
readings. Consequently health-file cadence is scan duration plus the 30-second
inter-scan delay, not one second or exactly 30 seconds.

`watchdog-ready.env` is written only after the first complete healthy disk
scan. The build command waits for that marker and an active watchdog before it
starts. Its independent wrapper checks the watchdog unit every second while
the command runs. A failed or unavailable watchdog stops the build even if no
policy reason was recorded and records terminal failure `125` when no more
specific reason exists. CPU, memory, task, I/O, and wall-time controls remain
additional enforced bounds rather than substitutes for the watcher.

## Immutable Source Transfer

Use a unique lowercase job ID. Staging refuses a dirty repository, requires the
checked-out `helium-chromium` submodule to match the superproject gitlink, and
creates a shallow detached Git checkout containing exactly those two commits.
The retained minimal Git metadata lets build-time provenance and cleanliness
checks resolve the staged commits without contacting a remote. The wrapper
transfers that checkout directly over the dedicated SSH connection, checks the
archive SHA-256 on chromiumer, and expands it under the job workspace. It does
not push a branch or disclose private Sync source to a public remote.

```sh
cd /home/d/coding/helium/helium-passwords
scripts/dev.sh check
git status --short --branch

job=hp-linux-150-passwords-01
scripts/chromiumer-job.sh preflight 100
scripts/chromiumer-job.sh stage "$job" 100
```

For the private repository, invoke the same inherited wrapper from Sync:

```sh
cd /home/d/coding/helium/helium-sync
scripts/dev.sh check

job=hs-android-150-sync-01
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$job" 80
```

The retained source manifest records repository name, origin, commit, tree,
Helium submodule commit, archive hash, transfer time, and source host. The
archive is deleted only after remote verification and extraction; the manifest
remains under:

```text
/home/d/.local/state/helium-builds/<job>/source.manifest
```

## Starting a Build

Start only after `preflight` and staging succeed. The command returns
immediately after creating the isolated job and watchdog. The detached build
wrapper then waits for the watchdog's first healthy sample before launching the
requested build command. `--summary` records what the job tests or produces;
`--next` is the useful action included in a success notification. Both are
mandatory and must describe the particular job, not a generic build class.

Public Linux x86_64 does not use the platform's Docker wrapper on chromiumer.
A daemon-launched container would sit outside the transient user service's
process tree and job-tree disk accounting, and chromiumer has no Docker daemon.
The public driver instead enters the pinned Nix FHS environment and calls the
prepared platform's native build script directly. It independently requires
the two-job environment, job cgroup, job-owned `TMPDIR`, exact Linux/core/
Chromium commits, and a clean staged source before compilation:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "Linux x86_64 browser artifact and password acceptance input" \
    --next "Fetch and verify the packaged artifact, then run the disposable password gate." -- \
    scripts/chromiumer-nix.sh run -- \
      bash scripts/build-chromiumer-linux.sh x86_64
```

The driver writes exactly one return artifact at
`.build/artifacts/helium-passwords-linux-x86_64.tar.xz`. It contains the raw
runtime plus the source/tree, Helium core, Chromium, Linux platform, resolved
GN arguments, Passwords patch hashes, Nix closure, and complete runtime hash
inventory. This command is not ready until the current Nix expression's
expression-hash-named GC root has been realized and a fresh 80 GiB preflight
passes. An older `chromium-150-*` root is not accepted as evidence for a
changed expression.

Android source acquisition has one shared backbone entry point:

```sh
scripts/chromium/prepare-android-source.sh .build/chromium-android
```

It reads `chromium/android-build.lock`, pins and verifies depot_tools, disables
depot_tools self-update and its local Git cache, verifies the direct launcher
before and after execution, and makes exactly one source request:

```text
gclient sync --jobs 2 --revision src@<locked-full-sha> --nohooks --no-history
```

The helper then requires Chromium `HEAD` to equal the locked SHA. The locked
depot_tools parser ignores a `.gclient` solution `revision` key, so the
command-line revision is the enforced input. Do not prepend a moving-main sync,
manually fetch and check out the commit, or run a second repair sync. The
private patch, hooks, GN, build, and packaging phases consume this checkout;
they do not own another acquisition path. The revision form is documented by
the [official depot_tools gclient source](https://chromium.googlesource.com/chromium/tools/depot_tools.git/+/HEAD/gclient.py).

The upstream Android control also calls this helper exactly once, then runs
pinned hooks and refuses any tracked Chromium diff before GN. Its dedicated
builder applies no Helium/core, Passwords, or Sync composition and packages
`ChromiumControl.apk` only after recording `upstream-control`. Run it as a new
isolated job; never reuse a terminal Sync workspace as the control.

After the focused compile proof passes, stage two fresh jobs from the same
clean private commit. The Sync job must explicitly select the disposable
package; production `computer.helium.sync` is not an acceptance input. Both
builders record the realized Nix closure and exact command inside their
artifact provenance, so invoke them through `chromiumer-nix.sh run`:

```sh
cd /home/d/coding/helium/helium-sync
scripts/dev.sh check
sync_commit=$(git rev-parse HEAD)

sync_job=hs-android-150-sync-test-01
scripts/chromiumer-job.sh preflight 100
scripts/chromiumer-job.sh stage "$sync_job" 100
scripts/chromiumer-job.sh start "$sync_job" \
  --summary "Chromium 150 disposable Helium Sync arm64 APK" \
  --next "Fetch and verify the Sync APK, then prepare disposable acceptance." -- \
  scripts/chromiumer-nix.sh run -- \
    env HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
      CHROMIUM_WORKSPACE=.build/chromium-android-sync-test \
      ARTIFACT_DIR=.build/android-sync-test-artifacts \
      CHROMIUM_ANDROID_MANIFEST_PACKAGE=computer.helium.sync.test \
      CHROMIUM_ANDROID_PHASE=all \
      bash scripts/chromium/build-android-ci.sh

control_job=hs-android-150-control-test-01
scripts/chromiumer-job.sh preflight 100
scripts/chromiumer-job.sh stage "$control_job" 100
scripts/chromiumer-job.sh start "$control_job" \
  --summary "Same-source unmodified Chromium 150 arm64 control APK" \
  --next "Fetch and verify the control APK, then prepare disposable acceptance." -- \
  scripts/chromiumer-nix.sh run -- \
    env HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
      CHROMIUM_WORKSPACE=.build/chromium-android-control \
      ARTIFACT_DIR=.build/android-control-artifacts \
      bash scripts/chromium/build-android-control-ci.sh
```

Do not run the two 100 GiB jobs concurrently. Before starting the second job,
fetch the first artifact and clean its verified workspace so the shared disk
admission is recomputed. Both artifact verifiers receive the saved
`$sync_commit`; this is the cross-job source binding.

When each job reaches terminal success, fetch and verify the exact archive on
lm before cleanup:

```sh
scripts/chromiumer-job.sh terminal "$sync_job"
scripts/chromiumer-job.sh fetch "$sync_job" \
  .build/android-sync-test-artifacts/chrome_public_apk-arm64.tar.xz
sync_archive=/srv/nas/helium-builds/$sync_job/chrome_public_apk-arm64.tar.xz
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/chromium/verify-android-artifact.sh \
    "$sync_archive" computer.helium.sync.test "$sync_commit"
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/android-media/prepare-disposable-acceptance.sh \
    "$sync_archive" computer.helium.sync.test "$sync_commit" \
    /home/d/.local/state/helium-acceptance/$sync_job
scripts/chromiumer-job.sh cleanup "$sync_job"

scripts/chromiumer-job.sh terminal "$control_job"
scripts/chromiumer-job.sh fetch "$control_job" \
  .build/android-control-artifacts/chromium-control-apk-arm64.tar.xz
control_archive=/srv/nas/helium-builds/$control_job/chromium-control-apk-arm64.tar.xz
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/chromium/verify-android-artifact.sh \
    "$control_archive" computer.helium.control.test "$sync_commit"
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/android-media/prepare-disposable-acceptance.sh \
    "$control_archive" computer.helium.control.test "$sync_commit" \
    /home/d/.local/state/helium-acceptance/$control_job
scripts/chromiumer-job.sh cleanup "$control_job"
```

`prepare-disposable-acceptance.sh` refuses an existing output directory. Never
reuse or overwrite an earlier acceptance generation.

`CHROMIUM_REF` may be omitted because the helper uses the lock; if supplied it
must equal the same full commit:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "OnePlus arm64 APK for streaming, video, password, tab, and cookie validation" \
    --next "Fetch the APK and execute the documented disposable OnePlus acceptance sequence." -- \
    env \
      HELIUM_SYNC_REPO=. \
      GITHUB_WORKSPACE=.build \
      CHROMIUM_ANDROID_PHASE=all \
      bash scripts/chromium/build-android-ci.sh
```

Linux/Android jobs additionally need a reproducible chromiumer build
environment. The pinned, cgroup-gated environment and its separate Nix-store
disk arithmetic are in [chromiumer-nix.md](chromiumer-nix.md). Chromium's
NixOS guidance requires running build tools in its Nix shell. The public Linux
driver deliberately bypasses Docker and returns the Nix closure, exact command,
GN args, patch hashes, and Chromium commit inside its artifact.

## Status, Logs, Cancellation, and Artifacts

These commands run from the repository on `lm`:

```sh
scripts/chromiumer-job.sh status "$job"
scripts/chromiumer-job.sh terminal "$job"
scripts/chromiumer-job.sh limits "$job"
scripts/chromiumer-job.sh logs "$job" 120
scripts/chromiumer-job.sh cancel "$job"
```

The fourth command is the single cancellation command. It stops both transient
units; systemd kills the complete build control group. Job state and logs live
at:

```text
/home/d/.local/state/helium-builds/<job>/policy.env
/home/d/.local/state/helium-builds/<job>/watchdog-ready.env
/home/d/.local/state/helium-builds/<job>/health.env
/home/d/.local/state/helium-builds/<job>/disk-scan-retry.env
/home/d/.local/state/helium-builds/<job>/disk-scan-first-error.log
/home/d/.local/state/helium-builds/<job>/watchdog-stop.env
/home/d/.local/state/helium-builds/<job>/result.env
/home/d/.local/state/helium-builds/<job>/terminal.env
```

`terminal.env` is atomically written exactly once and classifies the outcome
as `success`, `failure`, `timeout`, or `cancellation`, with the exit code,
duration, and reason. The lm notification timer observes only that record; it
does not infer completion from an SSH connection or a shell lifetime. See
[job-notifications.md](job-notifications.md) for installation, retry, and
acceptance details.

Build stdout and stderr go to the systemd journal. `logs` invokes
`journalctl --user --unit=helium-job-<job>.service`; no second log file or log
rotation mechanism is maintained by the wrapper.

Package build outputs as one file on chromiumer, then return that exact file.
The default destination is the NAS mounted on `lm`; pass a third argument only
when intentionally returning to another `lm` directory:

```sh
scripts/chromiumer-job.sh fetch "$job" \
    .build/artifacts/helium-passwords-linux-x86_64.tar.xz

scripts/chromiumer-job.sh fetch "$job" \
    .build/android-artifacts/chrome_public_apk-arm64.tar.xz \
    /srv/nas/helium-builds/"$job"
```

Transport checksum verification is necessary but not sufficient. Before a
Linux runtime reaches da, validate its internal source and file inventories
from the same public commit that was staged:

```sh
scripts/verify-linux-runtime.sh \
  /srv/nas/helium-builds/"$job"/helium-passwords-linux-x86_64.tar.xz \
  /srv/nas/helium-builds/"$job"/verified
```

The destination must not exist. Verification rejects an unexpected source
train, field/file inventory, symlink, patch, GN args, Nix environment, or
runtime hash and writes a mode-0600 `artifact-receipt.env` that admits exactly
one upstream `runtime/helium-wrapper` entry point to the native password gate.

The wrapper compares remote and returned SHA-256 values and writes an artifact
receipt. Cleanup refuses to remove a production workspace until that receipt
exists:

```sh
scripts/chromiumer-job.sh cleanup "$job"
```

Cleanup removes only `/home/d/helium-builds/work/<job>` after the job is
inactive and the artifact is verified elsewhere. It retains logs, manifests,
hashes, health history, and the receipt. Never manually remove a workspace that
could contain the only artifact copy.

## Current Capacity and Test Proof

On 2026-07-21, chromiumer had 8 CPUs, 7.6 GiB RAM, no swap, and one 119 GiB
SSD whose 116 GiB ext4 root filesystem exposed 113,542,557,696 bytes
(105.74 GiB) to the build user. `/home/d/helium-builds/work` is on that root;
there is no separate build mount. The filesystem has 6,347,919,360 additional
bytes reserved for root.

An empty 80 GiB bounded proof requires 82 GiB on the current shared root and
passes disk admission with 23.74 GiB of headroom. An empty 100 GiB job requires
102 GiB and passes current disk admission with only 3.74 GiB of headroom. The
existing SSD therefore supports the bounded proof without repartitioning or an
OS replacement. A full build remains tight after provisioning the toolchain.

Android source preparation does not use depot_tools' local Git mirror.
`gclient-sync-direct.sh` removes `GIT_CACHE_PATH` and indexed or legacy
command-scope Git config, requires exactly one `cache_dir = None` assignment in
`.gclient`, then invokes:

```text
gclient sync [--jobs 2] ...
```

The exact depot_tools commit is locked in `chromium/android-build.lock`.
Source preparation checks out that commit and verifies its HEAD, clean tracked
tree, launcher blobs, parser, and config loader before putting it on `PATH`:
the `config` command owns `--cache-dir`, the `sync` command has no such option,
and the config loader passes the top-level `None` value to
`git_cache.Mirror.SetCachePath`. [depot_tools normally updates itself whenever
`gclient` runs][depot-tools-update]. Helium exports its documented
`DEPOT_TOOLS_UPDATE=0` control, invokes the verified launcher's absolute path,
and re-verifies the checkout immediately before and after the only source
sync. That sync receives the locked commit as
`--revision src@<locked-full-sha>`; source preparation then requires Chromium
`HEAD` to equal it. The separate `runhooks` call has the same before/after depot
pin check but is not another source sync. Combined with `--no-history`, gclient
initializes each checkout and performs a shallow fetch from its origin. This
eliminates the local mirror's
`upload-pack -> pack-objects` path. A moved HEAD, dirty tracked file, changed
launcher blob, missing/duplicated cache setting, or cache-enabled configuration
fails before gclient starts. Packaged provenance records both the executing
depot_tools commit and `DEPOT_TOOLS_UPDATE=0`; artifact validation compares
them with the carried lock.

Job `hs-android-148-disposable-apk-05` discovered the missing no-update control.
The job checked out and validated
`36a464bfe6ef49e0710caf65bfbabc87725720da` at 07:02:09Z, then the `gclient`
launcher moved the checkout to `origin/main` commit
`1fa2c22bc302b770527ca30fd6f98b0576381001` at 07:02:10Z. The job was cancelled
before source preparation or compilation completed and retained terminal
`cancellation`, exit `130`. It is not artifact or validation evidence.

Do not replace this with `GIT_CONFIG_COUNT` pack settings. Git only processes
the key/value pairs while the matching count is present, while depot_tools
also invokes fetch with an explicit `-c core.deltaBaseCacheLimit=2g`, which has
higher precedence. Live process inspection showed the local `pack-objects`
child without the count, nine threads, and near-4-GiB RSS; that approach did
not establish the claimed limits. Direct fetch can still run a receive-side
`index-pack`, so the production cgroup's 4 GiB `MemoryHigh`, 5 GiB `MemoryMax`,
two-job ceiling, disk budget, watchdog, and wall deadline all remain mandatory.

Git, Python 3, Docker, Podman, and Chromium tools were absent from the normal
login `PATH`; `nix` is installed. A read-only check on 2026-07-22 reconfirmed
that neither container runtime is installed while the isolated Android compile
remained active. Chromium's current Linux instructions require at
least 100 GB free, recommend more than 16 GB RAM and substantial swap on an
8 GB machine, and explicitly direct NixOS users to run depot_tools inside the
provided Nix shell:

<https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md>

The current public Linux expression was realized through bounded job
`hs-nix-150-a0820646-01`. Its returned provenance is
`/srv/nas/helium-builds/hs-nix-150-a0820646-01/chromiumer-nix.env` with SHA-256
`a87f590a5519db58633cd31f99a67d09b4f9e1ea9ac3ffb448fe94f0f4d147b6`.
It records expression SHA-256
`a0820646387c653b416b58551893d450319ad22d0537f5b9621fe5c9fd04bf5e`,
root `chromium-150-a0820646387c653b`, derivation
`/nix/store/f5ysbgffynhgw2vq8m23ad7imia4iqar-helium-chromium-150-env.drv`,
output `/nix/store/j8sb2bh7kgcf8a3sfc8bv16z3brcij9g-helium-chromium-150-env`,
and closure SHA-256
`a3e8b195d0e69263de2239e5410fc3509de22c8c3ed0657c82d387816bd40d57`
over 1,853,912,336 bytes. Realization consumed 362,057,728 root bytes and
stayed above the 82 GiB post-realization floor. Its workspace was cleaned only
after provenance return; a subsequent 80 GiB preflight passed.

The remaining build gates are:

1. Wait for the serialized Android validation train to return its artifacts,
   clean its final workspace, and explicitly hand off chromiumer admission.
2. Re-run `connection` and `preflight 80`; unrelated disk growth can still
   correctly refuse the public job.
3. Measure the public compile under the existing 5 GiB hard memory cap. Host
   swap cannot help the build because its cgroup has `MemorySwapMax=0`, and
   extra RAM does not raise `MemoryMax=5G`. If the proof hits that cap, record
   the failure before making a separate hardware and cgroup-policy decision.
4. Return and strictly verify the single provenance-bound Linux archive before
   any disposable browser run.

After changing the depot_tools lock or launcher boundary, run this small
detached proof before another Chromium job. It clones only depot_tools, invokes
`gclient --version` through the real pinned launcher with auto-update disabled,
re-verifies unchanged HEAD and tracked blobs, and returns a proof record:

The first live attempt, `hs-depot-pin-proof-01`, disproved the original 1 GiB
estimate. The watchdog stopped it correctly after 64 seconds with terminal
`failure`, exit `1`, reason `job disk budget breached`; its failing sample was
`workspace_bytes=1,293,221,888` against a 1,073,741,824-byte budget. The
retained stopped tree stabilized at 1,483,829,248 allocated bytes: 923,947,008
bytes in the staged source and proof checkout and 559,845,376 bytes in the
redirected vpython cache. No proof record was produced, so that job is only
fail-closed disk-accounting evidence.

Use an explicit 2 GiB budget for this proof. It leaves 663,654,400 bytes above
the retained measured tree for bootstrap transients and the small verifier and
proof record; the helper does not fetch Chromium or compile anything. Keep the
same explicit value in `preflight` and `stage`. This is a per-job choice, not a
worker default.

```sh
job=hs-depot-pin-proof-$(date +%Y%m%d-%H%M%S)
scripts/chromiumer-job.sh preflight 2
scripts/chromiumer-job.sh stage "$job" 2
scripts/chromiumer-job.sh start "$job" \
  --summary "Pinned depot_tools no-self-update proof" \
  --next "Fetch depot-tools-pin-proof.env and verify the terminal state." -- \
  scripts/chromiumer-nix.sh run -- \
    scripts/chromium/prove-depot-tools-pin.sh \
      .build/depot-tools-pin-proof
scripts/chromiumer-job.sh terminal "$job"
scripts/chromiumer-job.sh limits "$job"
scripts/chromiumer-job.sh fetch "$job" \
  .build/depot-tools-pin-proof/depot-tools-pin-proof.env
```

The simplified harmless wrapper test was executed as
`wrapper-test-20260721-153235`. It completed with exit code 0 while live systemd
properties reported a 50% CPU quota, 128/256 MiB memory high/max, zero swap,
I/O weight 10 with idle scheduling, 32 tasks, and a two-minute test deadline.
The watchdog reported `status=ok`, recorded both root and job-filesystem free
space, and measured the complete test job tree. The generated test workspace
was removed; its 49,152-byte policy/state evidence and systemd journal records
remain on chromiumer.
The arithmetic test proves both mount cases for an 80 GiB job: on root,
`0 GiB used -> 82 GiB required`, `10 GiB used -> 72 GiB`, and
`80 GiB used -> 2 GiB`; on a separate build mount the same cases require
80 GiB, 70 GiB, and zero build-filesystem bytes while `/` retains its
independent 2 GiB floor.

Job `hs-android-148-disposable-apk-04` exposed the former watchdog's fail-open
behavior on 2026-07-22. Its repeated `du -sx` scan grew to the watchdog's exact
64 MiB hard limit; systemd recorded `Result=oom-kill`, exit `137`, and a 64 MiB
peak at 06:50:39Z. The build remained active until its explicit cancellation at
06:51:18Z, which correctly retained terminal `cancellation`, exit `130`. The
replacement streaming counter was measured against that retained
17,232,089,088-byte job tree: 2.08 seconds, 18,820 KiB peak RSS, and no build or
workspace mutation. The 128 MiB watchdog hard maximum is more than six times
that observed peak while remaining small compared with the host and build
cgroups.

`scripts/tests/chromiumer-watchdog.test.sh` grows a synthetic 16,000-file tree,
runs the counter under a 64 MiB virtual-memory ceiling, and simulates the
watchdog disappearing after readiness. It proves that the command is stopped
and the one terminal record is `failure`, exit `125`, with the watchdog reason;
it separately proves that an explicit cancellation race remains
`cancellation`, exit `130`. This is a source-level regression and starts no
Chromium or remote job. Run the harmless detached remote proof again before the
next Chromium job so the newly installed worker's live unit properties and
readiness handshake are also retained.

### Android job 06 failure evidence

`hs-android-148-disposable-apk-06` is retained as negative infrastructure
evidence. Its chromiumer state and journals remain, while its disposable
workspace was safely cleaned after the verified evidence archive was returned.
The authoritative copy is
`/srv/nas/helium-builds/hs-android-148-disposable-apk-06/job06-failure-evidence-v2.tar.xz`,
SHA-256
`b6b41e37cca4131b2aced0e0d7a4d6b059303dc008d60430fa26ab4f02ee3062`;
the cleaned workspace now reports `workspace_bytes=0`. The job ran from
`2026-07-22T07:26:43Z` through `10:13:04Z` and recorded terminal failure `125`
with the generic reason `health watchdog exited unexpectedly`. That reason is a
symptom, not the cause.

The pinned fetch completed at `10:10:21.103Z`. Checkout from moving main
`407597e9a111c4863bf2b8055cfe20f3d19d2731` to locked
`d096af1c9e98c45c3596e59620622b1a049bfecb` began one second later. The old
synchronous allocated-block scan overlapped the checkout and reported four
paths disappearing between `10:10:32Z` and `10:12:59Z`. Because the copied
worker used `set -euo pipefail` around an unguarded `find | awk` substitution,
that expected traversal race terminated the watchdog at `10:13:03.216Z`. The
one-second supervisor stopped the build at `10:13:04.267Z`.

This was not disk, memory, or compile pressure. The last complete health record
used `38,281,416,704` bytes under the 80 GiB budget, had
`72,333,332,480` root bytes available above the 2 GiB floor, and
`3,020,472,320` memory bytes available above the 1 GiB stop floor. Systemd
reported watchdog `exit-code`, not `oom-kill`; its 64.3 MiB peak was below the
128 MiB maximum. Compilation never started, `.build/android-artifacts` was
empty, `src/out` did not exist, and neither expected archive was present.

Active checkout scans had grown from roughly 128 seconds to 231 seconds and
later four to five minutes. The old code read root space and memory before each
blocking scan, evaluated those stale readings afterward, and then slept another
30 seconds. The asynchronous watcher preserves the independent one-second
safety checks regardless of scan duration.

Do not resume, reuse, or restage the job 06 ID. The next Chromium attempt must
use a unique job and the single locked source helper. The recovery worker passed
constrained job `wrapper-test-20260722-090001`: watchdog ready and health were
valid, the live cgroup bounds matched policy, and the five-second command
finished with terminal success and exit `0` after eight seconds. Only that test
workspace was cleaned; no Chromium command ran.

Re-run the same proof without starting Chromium:

```sh
scripts/chromiumer-job.sh test
```

[gnu-find-blocks]: https://www.gnu.org/software/findutils/manual/html_node/find_html/Size-Directives.html
[depot-tools-update]: https://chromium.googlesource.com/chromium/tools/depot_tools/+/HEAD/README.md#updating
