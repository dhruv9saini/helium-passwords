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
Git tree, archives exactly `HEAD`, transfers that archive, and provides the one
interface for start/status/logs/cancel/fetch/cleanup. It does not compile and it
does not enforce cgroups on `lm`.

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
| Watchdog | separate cgroup: `10%` CPU, weight `10`, `64M` memory high / `128M` hard max, no swap, idle I/O, nice `15`, and `TasksMax=16` |
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
sizes. It streams GNU `find`'s `%b` values into a constant-size sum. GNU
[`-ignore_readdir_race`](https://www.gnu.org/software/findutils/manual/html_node/find_html/Directories.html)
suppresses only entries that disappear after their parent directory was read,
which is normal while Git or Ninja mutates a tree.
A missing scan root, permission error, I/O error, invalid counter output, or
any other scan failure remains fatal and stops the job. Multiple directory
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
second, including while that scan is running and during the 30-second delay
before the next scan, it takes a fresh `/` free-space reading and a fresh
`MemAvailable` reading. A root-floor breach stops the build on that check; two
consecutive low-memory readings stop it on the second check. Disk-budget
evaluation occurs only after one complete valid scan. `health.env` is then
atomically replaced with that disk result and the latest fresh filesystem,
memory, and load readings. Consequently health-file cadence is scan duration
plus the 30-second inter-scan delay, not one second or exactly 30 seconds.

`watchdog-ready.env` is written only after the first complete healthy disk
scan. The build command waits for that marker and an active watchdog before it
starts. Its independent wrapper checks the watchdog unit every second while
the command runs. A failed or unavailable watchdog therefore stops the build
even if no policy reason was recorded. `MemoryMax`, `CPUQuota`, `TasksMax`,
idle I/O priority, and the systemd runtime deadline remain additional enforced
bounds rather than substitutes for the watcher.

## Immutable Source Transfer

Use a unique lowercase job ID. Staging refuses a dirty repository, archives
exactly `HEAD`, transfers it directly over the dedicated SSH connection, checks
the archive SHA-256 on chromiumer, and expands it under the job workspace. It
does not push a branch or disclose private Sync source to a public remote.

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

Start only after `preflight` and staging succeed. The commands return
immediately after creating the isolated job and watchdog. `--summary` records
what the job tests or produces; `--next` is the useful action included in a
success notification. Both are mandatory and must describe the particular
job, not a generic build class.

For public Linux x86_64, the prepared platform wrapper forwards the enforced
two-job limit into its Dockerized Ninja invocation:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "Linux x86_64 browser artifact and password acceptance input" \
    --next "Fetch and verify the packaged artifact, then run the disposable password gate." -- \
    bash scripts/build.sh linux x86_64
```

Android source acquisition has one public backbone entry point:

```sh
scripts/chromium/prepare-android-source.sh .build/chromium-android
```

It reads `chromium/android-build.lock`, pins and verifies depot_tools, disables
depot_tools self-update and its local Git cache, verifies the direct launcher
before and after execution, and makes exactly one source request:

```text
gclient sync --jobs 2 --revision src@<locked-full-sha> --nohooks --no-history
```

The helper then requires Chromium `HEAD` to equal that locked SHA. The
`.gclient` solution `revision` key is deliberately not used: the locked
depot_tools parser ignores that key, while the command-line revision is
enforced before its shallow clone. Do not prepend a moving-main sync, manually
fetch and check out the commit, or run a second repair sync. Downstream Sync
build code must call this shared helper before its private patch and build
phases rather than owning another source-acquisition implementation.

The revision form is the one documented by the
[official depot_tools gclient source](https://chromium.googlesource.com/chromium/tools/depot_tools.git/+/HEAD/gclient.py).

For a Sync Android job, `CHROMIUM_REF` may be omitted because the helper uses
the lock; if supplied, it must equal the same full commit:

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
disk arithmetic are in [chromiumer-nix.md](chromiumer-nix.md). Helium Linux
currently expects Docker; that daemon is not provided by the Android Nix
environment. Chromium's NixOS guidance requires running depot tools in its Nix
shell. Record the Nix system closure, Docker image ID when applicable, exact
command, GN args, patch hashes, and Chromium commit alongside the source
manifest before accepting an artifact.

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
/home/d/.local/state/helium-builds/<job>/health.env
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
    build/platforms/linux/build/<artifact>.tar.xz

scripts/chromiumer-job.sh fetch "$job" \
    .build/android-artifacts/chrome_public_apk-arm64.tar.xz \
    /srv/nas/helium-builds/"$job"
```

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

Git, Python 3, Docker, and Chromium tools were absent from the normal login
`PATH`; `nix` is installed. Chromium's current Linux instructions require at
least 100 GB free, recommend more than 16 GB RAM and substantial swap on an
8 GB machine, and explicitly direct NixOS users to run depot_tools inside the
provided Nix shell:

<https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md>

The pinned environment is implemented but deliberately not realized. The
remaining setup gate is:

1. Follow [chromiumer-nix.md](chromiumer-nix.md): admit a 20 GiB isolated
   realization job, require the independent 102 GiB start gate, and record the
   resulting closure plus root-space delta. The environment provides the
   bootstrap for source-managed depot_tools. Add Docker only for the public
   Linux wrapper that actually calls it.
2. Re-run `preflight 80` after the tool closure is present; if the remaining
   headroom is insufficient, add a local build disk rather than using the NAS.
3. Measure the bounded compile under the existing 5 GiB hard memory cap. Host
   swap cannot help the build because its cgroup has `MemorySwapMax=0`, and
   extra RAM does not raise `MemoryMax=5G`. If the proof hits that cap, record
   the failure before making a separate hardware and cgroup-policy decision.
4. Re-run `connection`, budgeted `preflight`, and the short wrapper test before
   staging.

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

### Retained Android job 06 failure

`hs-android-148-disposable-apk-06` is retained as negative infrastructure
evidence. Its chromiumer state and journals remain, while its disposable
workspace was safely cleaned after the verified evidence archive was returned.
The authoritative copy is
`/srv/nas/helium-builds/hs-android-148-disposable-apk-06/job06-failure-evidence-v2.tar.xz`,
SHA-256
`b6b41e37cca4131b2aced0e0d7a4d6b059303dc008d60430fa26ab4f02ee3062`;
the cleaned workspace now reports `workspace_bytes=0`. The job ran from
`2026-07-22T07:26:43Z` through `10:13:04Z` and recorded terminal failure `125`
with the generic reason `health watchdog exited unexpectedly`. The reason is a
symptom, not the cause.

The pinned Chromium fetch completed at `10:10:21.103Z`. Checkout from moving
main `407597e9a111c4863bf2b8055cfe20f3d19d2731` to locked
`d096af1c9e98c45c3596e59620622b1a049bfecb` began one second later. The old
synchronous allocated-block scan overlapped that checkout. Its GNU `find`
process reported four paths disappearing between `10:10:32Z` and
`10:12:59Z`. Because the copied worker used `set -euo pipefail` around an
unguarded `find | awk` command substitution, the expected traversal race
terminated the watchdog with status `1` at `10:13:03.216Z`. The independent
one-second supervisor then stopped the build at `10:13:04.267Z`.

This was not a disk, memory, or build failure. The last complete health record
was `status=ok`, with `38,281,416,704` bytes used under the 80 GiB budget,
`72,333,332,480` root bytes available above the 2 GiB floor, and
`3,020,472,320` memory bytes available above the 1 GiB stop floor. Systemd
reported watchdog `exit-code`, not `oom-kill`; its 64.3 MiB peak was below the
128 MiB hard limit. The job had only entered its redundant second gclient sync.
Compilation never started, `.build/android-artifacts` was empty, `src/out` did
not exist, and neither expected Android archive was present.

The run also measured why disk-health cadence must not be described as every
30 seconds. Active checkout scans took roughly 128 seconds, then 231 seconds,
and later approximately four to five minutes. The old code read root space and
memory before each blocking scan, evaluated those stale readings afterward,
and then slept another 30 seconds. The replacement above preserves the
independent one-second safety checks while allowing a complete disk scan to
take as long as the bounded tree requires.

Do not resume, reuse, or restage the job 06 ID. Before cleanup its Chromium HEAD
was pinned, but dependency state was mixed because the second sync was
interrupted. The next Chromium attempt must use a unique job after the local
and harmless remote watchdog proofs pass, and it must use the single locked
source helper rather than the moving-main/two-sync sequence.

The recovery worker passed constrained job
`wrapper-test-20260722-090001` on chromiumer. Its independent watchdog reached
ready state, recorded `workspace_bytes=16,384`, `status=ok`, and current root
and memory readings, while the live units retained the test profile's 50% CPU,
128/256 MiB build memory, zero swap, idle I/O, 32-task, and two-minute bounds
plus the separate 10% CPU, 64/128 MiB, 16-task watchdog bounds. The five-second
command finished with terminal success and exit `0` after eight seconds. Only
that generated test workspace was cleaned; its state and journal remain. No
Chromium command ran.

Re-run the same proof without starting Chromium:

```sh
scripts/chromiumer-job.sh test
```
