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

## Independent lm Management Paths

Build control has two independently probed SSH routes to the same pinned host
identity:

```text
Tailscale: chromiumer / chromiumer.tail0168aa.ts.net
Direct LAN: 192.168.5.27
SSH user: d
Identity: /home/d/.ssh/helium_chromiumer_ed25519
HostKeyAlias: chromiumer
```

The single reviewed configuration is
`chromiumer-management.conf`. It contains addresses, the existing private-key
path, the pinned known-host alias, and numeric policy—not a private key,
password, token, or mail credential. Installation copies it mode 0600 to
`/home/d/.config/helium/chromiumer-management.conf`; both admission and the
persistent monitor read that exact file.

Before either `start` or `resume` creates a remote build unit, registering its
local management timer requires three consecutive complete probe cycles.
Every cycle must prove:

- a default IPv4 route exists and the Tailscale DNS name resolves;
- `tailscale ping --until-direct` reports a direct peer route rather than
  DERP, and non-interactive strict-host-key SSH succeeds through the
  `chromiumer` alias; and
- non-interactive SSH independently succeeds to `192.168.5.27` while forcing
  the same dedicated identity and pinned `HostKeyAlias=chromiumer`.

Any failed cycle immediately refuses start; admission does not loop until a
degraded path happens to pass.
Successful registration atomically creates one mode-private state file bound
to the configuration SHA-256, then enables that job's timer before the wrapper
asks chromiumer to start. This is an lm control-plane gate only: it does not
replace, seed, bypass, or weaken chromiumer's cgroup limits, allocated-block
watchdog, health readiness proof, or eight-hour unit deadline.

Install the reviewed source on lm only when no older active job depends on a
different installed worker:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/install-chromiumer-management.sh
systemctl --user cat helium-chromiumer-management@.timer
```

Registration enables one persistent user-systemd timer instance for that job.
The `d` user has systemd lingering enabled on lm, so these timers survive
detached shells, tmux loss, logout, and lm restart. Every 60 seconds each
timer runs its own low-priority oneshot. It runs as `d` with `CPUQuota=5%`,
`MemoryMax=64M`, `TasksMax=16`, `Nice=15`, and idle I/O scheduling. The
current management state and pending cancellation are stored content-free in
one atomic state file; historical poll output is the systemd journal:

```text
/home/d/.local/state/helium-chromiumer-management/jobs/<job>.env
```

Use:

```sh
scripts/chromiumer-job.sh management-status "$job"
systemctl --user status \
  "helium-chromiumer-management@${job}.timer" --no-pager
journalctl --user \
  --unit="helium-chromiumer-management@${job}.service" \
  --since today --no-pager
```

A Tailscale-only failure is an explicit transition alarm; the LAN route
remains available for terminal inspection. A LAN-only failure is recorded the
same way. A single or double simultaneous failure never cancels a build.
After three consecutive 60-second cycles with neither management route, the
monitor durably records `cancel_pending=yes`. Delivery is impossible while
both routes are down, so it attempts no imaginary cancellation. On the first
cycle where either route recovers, it first checks the remote terminal record
and immediately sends the pending worker cancellation over that recovered
route if the job is still nonterminal. Cancellation delivery and the path used
are retained in the state file and journal, respectively.

The one operator cancellation command uses the same durable mechanism:

```sh
scripts/chromiumer-job.sh cancel "$job"
```

If either route is available it delivers immediately. If both are unavailable,
the request remains pending and is delivered on the first recovery. There is
no second direct-SSH cancellation path in the wrapper.

The offline management test uses fake route, DNS, Tailscale, SSH, terminal, and
cancellation commands. It starts no unit, build, Mailbridge turn, or mail:

```sh
bash scripts/tests/chromiumer-management.test.sh
```

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
| Compiler/build/source-sync jobs | exactly `1`; exported as `HELIUM_BUILD_JOBS`, `AUTONINJA_JOBS`, `NINJA_JOBS`, and `GCLIENT_JOBS`, with consumers rejecting every other value |
| CPU | hard `200%` quota, weight `10`, nice `15` |
| Memory | `4G` high, `5G` hard max, `0` swap inside the unit |
| I/O | weight `10`, Linux idle I/O scheduling class |
| Processes/threads | `TasksMax=256` |
| Job tree | explicit per-job allocated-block budget; the current full-target measurement uses `80 GiB`, while `100 GiB` is an optional larger ceiling only after a new capacity decision |
| Root free space | `2 GiB` unprivileged floor, independent of the job budget and checked on `/` |
| Host available memory | `2 GiB` required at start; watchdog stops after two readings below `1 GiB` |
| Watchdog | separate cgroup: `10%` CPU, weight `10`, `64M` memory high / `128M` hard max, no swap, idle I/O, nice `15`, `TasksMax=16`, and a finite 600-second production readiness cap |
| Wall time | hard `8h` systemd deadline |
| Concurrency | one active `helium-job-*` service on chromiumer |

The one-job value is an evidence-based host policy, not a Chromium default.
Job `hs-android-150-sync-test-09` admitted two large Clang translation units
under the unchanged `MemoryHigh=4G` and `MemoryMax=5G` bounds. The cgroup
accumulated more than 4.7 million `memory.high` events and roughly 1 TB of
filesystem rereads in about one hour without advancing Ninja, while the host
remained responsive. Serializing source sync and compilation avoids that
measured reclaim loop. It does not change the CPU, memory, I/O, task, disk,
root-space, watchdog, or eight-hour bounds. The worker exports all four
job-count variables as `1`; the pinned environment and platform entry points
reject missing or different values instead of choosing their own defaults.

There is no global 100 GiB class and no build-filesystem reserve. Every
production job declares a positive whole-GiB budget at `preflight` and `stage`.
The budget covers its source, output, temporary files, and redirected caches.
It does not select a Ninja target. The queued public 80 GiB run still invokes
the platform's complete `chrome` and `chromedriver` targets; if it succeeds,
the result is the full Linux runtime artifact. It is a capacity-bounded
full-target attempt, not a small-target compile. `100` permits the identical
command to allocate 20 GiB more and is appropriate only after an 80 GiB disk
stop establishes the need and live capacity is reviewed. The harmless wrapper
test uses `1 GiB`.

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
which is normal while Git or Ninja mutates a tree. It does not suppress every
active-tree race: a directory can disappear after `find` has begun traversing
it. A failed scan is discarded and retried once from the root. A repeated
failure, an inconsistent exit status, or invalid counter output is fatal and
stops the job. Multiple directory
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
the command runs. A failed or unavailable watchdog therefore stops the build
even if no policy reason was recorded. `MemoryMax`, `CPUQuota`, `TasksMax`,
idle I/O priority, and the systemd runtime deadline remain additional enforced
bounds rather than substitutes for the watcher.

Production allows at most 600 seconds for that first complete scan; the
two-minute harmless test profile allows 10 seconds. This is a readiness bound,
not permission to start from a stale preflight result. A retained 44.17 GiB
Android workspace took 31.678 seconds to scan under the watchdog's low CPU and
idle-I/O priority, while earlier actively mutating checkout scans took roughly
four to five minutes. The 600-second cap is about nineteen times the retained
scan and twice the largest observed moving-tree scan, leaving the watchdog
low-priority while bounding a wedged scan. The command never starts without
the newly written health record and readiness marker. The eight-hour build
unit deadline remains unchanged and includes readiness time.

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
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$job" 80
```

The wrapper creates its source checkout and archive under the mode-0700
`/home/d/.local/state/helium-builds/source-staging` root. Start and resume use
the invoking user's `/run/user/<uid>` directory for their small notification
records. Neither path consumes lm's quota-bound bulk `/tmp` tmpfs.

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

### Continuing an exact wall-time timeout

An eight-hour deadline bounds one systemd unit; it does not imply that every
one-job Chromium compile will finish in one unit. A healthy compile that
reaches that exact deadline may continue in a new, independently bounded
segment without retransferring source or discarding Ninja state:

```sh
parent=hs-android-150-sync-test-01
job=hs-android-150-sync-test-01b
scripts/chromiumer-job.sh resume "$parent" "$job" \
    --summary "Continuation of the pinned Android compile and package gate" \
    --next "Fetch and verify the exact-source Android artifact." -- \
    env \
      HELIUM_SYNC_REPO=. \
      GITHUB_WORKSPACE=.build \
      CHROMIUM_ANDROID_PHASE=all \
      bash scripts/chromium/build-android-ci.sh
```

The command after `--` is mandatory and must byte-for-byte reproduce the
parent policy's shell-escaped argument vector. This keeps the executable build
plan explicit while letting Ninja reuse its dependency log and completed
objects. The continuation is not a longer unit: it gets a new unique
`helium-job-<job>.service`, watchdog, state directory, journal, terminal
record, Mailbridge event key, and exact eight-hour `RuntimeMaxSec`.

Admission fails closed unless all of these statements are true:

- the parent has one complete terminal record with `result=timeout` and
  `exit_code=124`;
- it was a production job with a complete source manifest, matching owner
  manifest, internally consistent policy/stage disk budget, and the exact
  requested command;
- no cancellation, watchdog stop, cleanup, or prior continuation exists (a
  returned timeout-evidence artifact is permitted and remains recorded);
- the parent units are inactive, the preserved workspace is present and
  contained under the work root, no other Helium unit is active, and the new
  job ID has no state or workspace collision;
- normal production admission passes using the entire preserved owner
  workspace as current use.

For an 80 GiB owner that already uses 44 GiB on chromiumer's current root
filesystem, the continuation gate is therefore approximately:

```text
80 GiB budget - 44 GiB allocated owner workspace + 2 GiB root floor
= 38 GiB required filesystem availability
```

The worker records `parent_job`, `workspace_owner`, and the source-manifest
SHA-256 in the continuation state. Only one child can claim a terminal segment.
The control client creates that durable claim first, registers the new job
with the lm notifier, and only then starts the unit. If notification
registration fails, the still-unstarted claim is removed. If start delivery is
uncertain, retrying the same parent, child, and command is idempotent; a
different value is rejected.

Use the continuation job ID with the normal `status`, `terminal`, `limits`,
`logs`, `cancel`, and `fetch` commands. `source-info` and artifact lookup
resolve its recorded owner workspace, while journals and terminal state remain
segment-specific. Only the latest segment can clean the shared workspace, and
only after its artifact-return receipt exists:

```sh
scripts/chromiumer-job.sh fetch "$job" \
    .build/android-artifacts/chrome_public_apk-arm64.tar.xz
scripts/chromiumer-job.sh cleanup "$job"
```

Cleanup rejects the timed-out parent, any non-latest segment, a second cleanup,
an active Helium unit, or a missing receipt. It deletes the workspace owner
once and retains every segment's manifests, policy, health, terminal,
notification provenance, and journal.

Public Linux x86_64 does not use the platform's Docker wrapper on chromiumer.
A daemon-launched container would sit outside the transient user service's
process tree and job-tree disk accounting, and chromiumer has no Docker daemon.
The public driver instead enters the pinned Nix FHS environment and calls the
prepared platform's native build script directly. It independently requires
the one-job environment, job cgroup, job-owned `TMPDIR`, exact Linux/core/
Chromium commits, and a clean staged source before compilation.

The pinned Linux platform calls raw `ninja`. The
[Ninja manual](https://ninja-build.org/manual.html#_running_ninja) specifies an
explicit `-j` count; Ninja does not read the wrapper's `NINJA_JOBS` variable.
The driver therefore puts the checked-in
`scripts/chromiumer-bin/ninja` shim first on `PATH`, binds its real Ninja path
before doing so, and rejects any caller-supplied `-j` override. Every Ninja
invocation in the platform build consequently receives explicit `-j 1`; the
CPU quota and `TasksMax` remain independent outer bounds.

Start the job with:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "Linux x86_64 browser artifact and password acceptance input" \
    --next "Fetch and verify the packaged artifact, then run the disposable password gate." -- \
    scripts/chromiumer-nix.sh run -- \
      bash scripts/build-chromiumer-linux.sh \
        helium-passwords x86_64 linux-x86_64 "$job"
```

Product, architecture, deployment target, and build job ID are mandatory;
there is no inferred product or host-architecture default. The public binding
in `linux-product.conf` requires `helium-passwords`, maps `x86_64` to
`linux-x86_64` and `arm64` to `linux-arm64`, binds the Passwords commit to
the repository `HEAD`, and records the Git null OID for the inapplicable
private Sync commit. A different product or product/architecture target fails
before source preparation.

The driver writes one archive and its build-produced deployment receipt:

```text
.build/artifacts/helium-passwords-linux-x86_64.tar.xz
.build/artifacts/helium-passwords-linux-x86_64.receipt.env
```

The archive contains the raw runtime plus the source/tree, public/private/core/
Chromium commits, explicit target and job ID, Linux platform, resolved GN
arguments, Passwords patch hashes, Nix closure, and complete runtime hash
inventory. The separate strict schema-1 receipt binds the archive hash and
size, target, all four commit slots, job ID, provenance-manifest hash, and UTC
creation time. It is created only by the packager; never hand-author one after
a build.

The pinned Helium Linux platform also supports an x86_64-hosted `ARCH=arm64`
cross-build and writes `target_cpu = "arm64"`. Start that as a separate job
with the same wrapper limits and explicit inputs:

```sh
scripts/chromiumer-job.sh start "$arm_job" \
    --summary "Linux arm64 Helium Passwords artifact" \
    --next "Fetch both files and verify the arm64 runtime receipt." -- \
    scripts/chromiumer-nix.sh run -- \
      bash scripts/build-chromiumer-linux.sh \
        helium-passwords arm64 linux-arm64 "$arm_job"
```

Source support and synthetic packaging checks do not substitute for a
completed arm64 compile. Either command is not ready until the current Nix
expression's expression-hash-named GC root has been realized and a fresh
capacity preflight passes. An older `chromium-150-*` root is not accepted as
evidence for a changed expression.

Android source acquisition has one public backbone entry point:

```sh
scripts/chromium/prepare-android-source.sh .build/chromium-android
```

It reads `chromium/android-build.lock`, pins and verifies depot_tools, disables
depot_tools self-update and its local Git cache, verifies the direct launcher
before and after execution, and makes exactly one source request:

```text
gclient sync --jobs 1 --revision src@<locked-full-sha> --nohooks --no-history
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
/home/d/.local/state/helium-builds/<job>/health.env
/home/d/.local/state/helium-builds/<job>/disk-scan-retry.env
/home/d/.local/state/helium-builds/<job>/disk-scan-first-error.log
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
    .build/artifacts/helium-passwords-linux-x86_64.receipt.env
scripts/chromiumer-job.sh fetch "$job" \
    .build/artifacts/helium-passwords-linux-x86_64.tar.xz

scripts/chromiumer-job.sh fetch "$job" \
    .build/android-artifacts/chrome_public_apk-arm64.tar.xz \
    /srv/nas/helium-builds/"$job"
```

Fetch the small deployment receipt first and the archive last. The wrapper's
remote cleanup admission then remains bound to the returned archive SHA-256;
the runtime verifier independently binds that archive to the fetched
deployment receipt.

Transport checksum verification is necessary but not sufficient. Before a
Linux runtime reaches da, validate its internal source and file inventories
from the same public commit that was staged:

```sh
scripts/verify-linux-runtime.sh \
  helium-passwords x86_64 linux-x86_64 \
  /srv/nas/helium-builds/"$job"/helium-passwords-linux-x86_64.tar.xz \
  /srv/nas/helium-builds/"$job"/helium-passwords-linux-x86_64.receipt.env \
  /srv/nas/helium-builds/"$job"/verified
```

For the first public run, classify a failure before changing source or limits:

```sh
scripts/chromiumer-job.sh terminal "$job"
scripts/chromiumer-job.sh status "$job"
scripts/chromiumer-job.sh limits "$job"
scripts/chromiumer-job.sh logs "$job" 240
```

- A patch or GN error before Ninja is a source-composition failure. Fix it in
  the public repository and use a new job ID; never edit the staged checkout.
- A C++, Rust, TypeScript, or link error is a real full-target compile failure.
  Preserve the exact diagnostic and source manifest before fixing the public
  patch. In particular, do not describe the Android focused target as proof
  that desktop-only settings, app-menu, omnibox, or toolbar files compile.
- `oom-kill`, the 5 GiB cgroup maximum, or the 80 GiB disk ceiling is capacity
  evidence, not a source failure. An exact healthy exit-124 wall timeout may
  use the bounded continuation workflow above. Do not raise a limit or retry
  at 100 GiB without a separate capacity decision.
- A successful Ninja followed by a missing runtime entry, Nix mismatch, or
  manifest/inventory failure is a packaging/provenance failure. The compiled
  output is not an admitted artifact.
- Only a fetched archive that passes `verify-linux-runtime.sh` can proceed to
  the disposable native-password protocol. Preserve a failed workspace until
  its useful diagnostics are returned; never manually delete it.

The destination must not exist. Verification first validates the
build-produced deployment receipt with an exact field inventory and no legacy
schema fallback, then requires its commits, job, and provenance hash to match
the archive manifest. It also rejects an unexpected source train, product,
architecture, target, field/file inventory, symlink, canonical patch-series
member, GN args, Nix environment, or runtime hash. The destination is
published atomically only after the complete check. It contains a mode-0600
copy of the deployment receipt and a separate mode-0600 version-2
`artifact-receipt.env` for disposable runtime acceptance. The latter admits
exactly one `runtime/helium-wrapper` entry point and binds the complete runtime
checksum inventory. It is not an installer receipt. The native password gate
rechecks every listed runtime file after transfer, so an unchanged wrapper
cannot conceal a changed browser binary, library, or resource.

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

At the initial audit, an empty 80 GiB job required 82 GiB on the current shared
root and passed disk admission with 23.74 GiB of headroom. An empty 100 GiB job
required 102 GiB and then had only 3.74 GiB of headroom. The later pinned Nix
realization changed the relevant measured availability to 109,691,019,264
bytes (102.1577 GiB): 20.1577 GiB above the 80 GiB job's 82 GiB gate, but only
0.1577 GiB above the 100 GiB job's 102 GiB gate. Both gates retain the same
independent 2 GiB root floor, but the larger one is operationally brittle on
this disk. The current full-target attempt therefore uses the 80 GiB ceiling;
crossing that ceiling is evidence for a new capacity decision, not permission
to relabel the run or silently retry at 100 GiB.

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
3. Run the complete `chrome` plus `chromedriver` target under that 80 GiB
   storage ceiling and the existing 5 GiB hard memory cap. Host
   swap cannot help the build because its cgroup has `MemorySwapMax=0`, and
   extra RAM does not raise `MemoryMax=5G`. If the proof hits that cap, record
   the failure before making a separate hardware and cgroup-policy decision.
4. Return and strictly verify the single provenance-bound Linux archive before
   any disposable browser run.

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
