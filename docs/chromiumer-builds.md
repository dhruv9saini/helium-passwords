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
Git tree, materializes a minimal-depth detached checkout of the superproject
`HEAD` that retains the exact Passwords ancestor named by `linux-product.conf`,
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
| Compiler/build/source-sync jobs | exactly `1`; exported as `HELIUM_BUILD_JOBS`, `AUTONINJA_JOBS`, `NINJA_JOBS`, and `GCLIENT_JOBS`, with consumers rejecting every other value; GRIT multiprocessing and ThinLTO backends are serialized so one Ninja edge cannot fork around the limit |
| CPU | hard `200%` quota, weight `10`, nice `15` |
| Memory | `4G` high, `5G` hard max, `0` swap inside the unit |
| I/O | weight `10`, Linux idle I/O scheduling class |
| Processes/threads | `TasksMax=1024`; compilation remains one-job, while Chromium source hydration may create many lightweight Git/Python helper threads inside that one job |
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
The prepared Linux core also passes `--jobs=1` to its actual `gclient sync`
invocation. Its pinned depot_tools bootstrap patch removes gsutil's internal
`-m` fan-out, so one gclient dependency cannot create another parallel worker
pool behind the job-count boundary. Job `hs-sync-current-c82231f` established
this second boundary: three concurrent git-cache bootstrap copies remained in
TCP `CLOSE-WAIT` for 45--74 minutes, gclient emitted its five-minute stall
diagnostic, and the otherwise healthy job was cancelled through the official
wrapper with exit `130`. The returned source sentinel and retained wrapper
journal are diagnostic evidence only, not a browser artifact.
The same run proved that the former `TasksMax=256` process/thread ceiling was
below source hydration's real helper-thread fan-out even with one gclient job;
it failed at 256 and again at 512. `TasksMax=1024` is therefore the persisted
production ceiling. This does not increase Ninja, Gclient, ThinLTO, GRIT, or
Mojom job counts: those remain serialized independently.

Claimed jobs also carry a durable, non-secret owner and generation lease in
both the local management state and remote job state. A claimed job's manual
cancel, artifact read/receipt, and cleanup transitions fail closed unless both
identifiers match. Automatic dual-path-loss cancellation loads and forwards
the same lease; stale task controllers cannot reuse an old job name to perform
a destructive transition.
Chromium's Mojom parser normally creates its own process pool independently of
Ninja. The Sync patch series caps that pool with the existing
`AUTONINJA_JOBS` value, so a serialized Android continuation cannot silently
start four memory-heavy parser workers inside its one Ninja edge. Chromium's
GRIT tool can likewise fork up to one worker per CPU. Job
`hs-android-150-current-synthetic-23` exposed eight 642 MiB workers inside one
nominally serialized edge, sustained roughly 87% full cgroup memory pressure,
and accumulated more than 57 million `memory.high` events without completing
the edge for over two hours. The pinned Chromiumer environment therefore
forces GRIT's upstream `GRIT_DISABLE_MULTIPROCESSING=1` switch for both Sync
and control builds. The retained Linux job `hs-node22-cont-e7be889` exposed the
same hidden-parallelism class in LLD: one Ninja link selected
`--thinlto-jobs=all`, launched eight backends, held the cgroup above its 4 GiB
memory-high boundary, and reread more than 5.5 TiB without completing that edge
for over seven hours. Sync patch
`0013-helium-sync-cap-thinlto-backends.patch` keeps ThinLTO and CFI enabled but
sets one ThinLTO backend. This is a compile-resource control, not a browser
runtime or hardening reduction.

The prepared Linux platform also passes GN bootstrap's built-in
`--use-custom-libcxx` option. The platform deliberately selects Chromium's
downloaded Clang for that bootstrap, so its matching in-tree libc++ and
libc++abi headers must be selected explicitly rather than depending on host
C++ headers. The same scoped invocation passes Chromium's installed Debian
host sysroot through compile-only `CFLAGS`. Downloaded Clang otherwise has no
platform C headers inside the pinned Nix environment: libc++ is found, but its
`mbstate_t` and wide-character declarations cannot resolve. The sysroot is
deliberately absent from `LDFLAGS`: `libc++.gn.so` is built as a host library,
and forcing Bullseye libc and libpthread into the final GN host-tool link mixes
host GLIBC symbols with sysroot libraries. A missing sysroot or an unsupported
GN host architecture fails before bootstrap. The pinned FHS deliberately does
not provide a generic `ld`, while Chromium's downloaded Clang otherwise asks
for bare `ld` when linking the custom host library. The prepared bootstrap
therefore requires the downloaded toolchain's adjacent `ld.lld` and selects it
for both the handwritten libc++ link and the generated GN host link with
`-fuse-ld=lld`. Both host links also select Clang's matching compiler runtime
with `-rtlib=compiler-rt`; neither flag introduces the compile sysroot into
`LDFLAGS`. Generated GN host archives likewise cannot depend on a generic host
`ar`; the prepared bootstrap requires the downloaded toolchain's adjacent
`llvm-ar` and passes its absolute path through bootstrap's `AR` environment
input. The invocation also uses the bootstrap's supported
`--build-path out/Default` option. Custom libc++ is a shared host library with
an origin-relative rpath; leaving the bootstrap at its default `out/Release`
build directory while requesting only the GN executable under `out/Default`
strands `libc++.gn.so` in the former directory. One build
path keeps the executable and its runtime library together without a loader
override or a second copy. Chromium 150's
libc++ also consumes shared LLVM libc headers, while the best-effort GN
bootstrap template still names the removed `third_party/llvm/libc` directory.
The prepared platform rewrites that one exact template entry to the canonical
`third_party/llvm-libc/src` include root, then requires both that exact entry
and `shared/fp_bits.h` before bootstrap. Chromium's normal libc++abi target
also carries the temporary `_LIBCPP_CONSTINIT=constinit` compatibility define
needed by its pinned libc++/libc++abi roll. The best-effort bootstrap template
omits that target define, so the prepared platform adds it only to the
handwritten `cxx_libcxxabi` rule and requires the exact resulting command.

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
sizes. It streams [GNU `find`'s `%b` size directive][gnu-find-blocks] into a
constant-size sum; `%b` is the allocated space for each entry in 512-byte
blocks. GNU
[`-ignore_readdir_race`](https://www.gnu.org/software/findutils/manual/html_node/find_html/Directories.html)
suppresses only entries that disappear after their parent directory was read,
which is normal while Git or Ninja mutates a tree. It does not suppress every
active-tree race: a directory can disappear after `find` has begun traversing
it. After the initial complete readiness scan, the watchdog accepts that narrow
second race only when every diagnostic is an exact `No such file or directory`
for a descendant of the still-present job root. The partial scan then omits a
name that is no longer reachable there; the next poll accounts for any
replacement or renamed entry. A missing root, permission or I/O error, mixed
diagnostic, or any other failed scan is discarded and retried once from the
root. A repeated unclassified failure, an inconsistent exit status, or invalid
counter output is fatal and stops the job. Multiple directory entries for one
hard-linked file are counted more than once, a conservative early stop rather
than an undercount. The ceiling is polled, not an ext4 project quota, so a job
can briefly cross the budget between completed scans. The independent root-free
check continues every supervisor second while any disk scan runs. The stream
retains no path or inode table.

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
evaluation occurs after a valid scan or, after readiness, a scan whose only
failure is that narrowly classified descendant disappearance. Any other
scan-command failure, with or without a diagnostic, is retried exactly once
because a concurrent build-tree mutation can invalidate a traversal. Its
partial count is never used. `disk-scan-retry.env` records the retry, and the
first stderr is preserved verbatim in `disk-scan-first-error.log`. A second
consecutive unclassified failure remains fatal. `health.env` is then atomically
replaced with the admitted disk result and the latest fresh filesystem, memory,
and load readings. Consequently health-file cadence is scan duration plus the
30-second inter-scan delay, not one second or exactly 30 seconds.

`watchdog-ready.env` is written only after the first complete healthy disk
scan. The build command waits for that marker and an active watchdog before it
starts. Its independent wrapper checks the watchdog unit every second while
the command runs. A failed or unavailable watchdog stops the build even if no
policy reason was recorded and records terminal failure `125` when no more
specific reason exists. CPU, memory, task, I/O, and wall-time controls remain
additional enforced bounds rather than substitutes for the watcher.

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
creates a minimal-depth detached Git checkout containing the source commit,
its exact configured Passwords ancestor, and the core commit. The retained
minimal Git metadata lets build-time ancestry, provenance, and cleanliness
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

Start only after `preflight` and staging succeed. The command returns
immediately after creating the isolated job and watchdog. The detached build
wrapper then waits for the watchdog's first healthy sample before launching the
requested build command. `--summary` records what the job tests or produces;
`--next` is the useful action included in a success notification. Both are
mandatory and must describe the particular job, not a generic build class.

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
    scripts/chromiumer-nix.sh run -- \
      env \
        HELIUM_SYNC_REPO=. \
        GITHUB_WORKSPACE=.build \
        CHROMIUM_ANDROID_PHASE=build \
        bash scripts/chromium/build-android-ci.sh
```

The command after `--` is mandatory and normally must byte-for-byte reproduce
the parent policy's shell-escaped argument vector. A retained Android
continuation may change one exact `CHROMIUM_ANDROID_PHASE=all` argument to
`CHROMIUM_ANDROID_PHASE=build`: source preparation intentionally leaves a
composed Chromium worktree, so rerunning `gclient` would reject the expected
changes before Ninja could reuse its state. The other admitted adjustment is
changing one exact `AUTONINJA_JOBS=2` argument to `AUTONINJA_JOBS=1`. This
lets a retained build serialize a linker/compiler pair that reached the
unchanged cgroup memory-high boundary. Any other token change fails admission.
The child records both commands and either `command_mode=retained-build` or
`command_mode=reduced-parallelism`.

This keeps the executable build plan explicit while letting Ninja reuse its
dependency log and completed objects. The continuation is not a longer unit:
it gets a new unique
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
SHA-256 in the continuation state. It also records `source_build_jobs`
separately from the current one-job execution policy. A source train that
pinned `HELIUM_BUILD_JOBS=2` before serialization keeps that value only as its
fail-closed Nix/source-entry attestation; the reduced continuation still gives
Autoninja exactly one job. New source trains require all job-count variables
to be one.

A reduced continuation that fails at that historical source-entry assertion
may itself be continued only when the worker proves all of the following:
the source attestation is two, the current execution policy is one, the first
continuation made the exact two-to-one Autoninja change, and it exited no more
than five seconds after watchdog readiness. This narrowly recovers the
orchestration-policy transition without admitting a retry after any compiler,
linker, packaging, watchdog, disk, cancellation, or wall-time failure.

An older exact continuation may instead fail when its `all` phase re-enters
`gclient` against the intentionally composed retained Chromium tree. The
worker admits one `all`-to-`build` recovery only when that continuation came
directly from a timeout, kept the one-job source policy, and exited no more
than 30 seconds after watchdog readiness. The build phase regenerates and
verifies GN and provenance before resuming Ninja, while source acquisition and
composition remain bound to the retained workspace.

Only one child can claim a terminal segment.
The control client creates that durable claim first, registers the new job
with the lm notifier, and only then starts the unit. If notification
registration fails, the still-unstarted claim is removed. If start delivery is
uncertain, retrying the same parent, child, and command is idempotent; a
different value is rejected. The control client's resume transaction runs in
its own shell scope so an early local failure can still use the admitted
parent, child, registration, and scratch paths during its `EXIT` cleanup. It
aborts the unstarted claim and unregisters local management before returning
the original error; a cleanup error must never replace that failure with an
unbound-variable diagnostic. Start and resume notification scratch lives in
the invoking user's `/run/user/<uid>` runtime directory, so unrelated bulk
work in `/tmp` cannot strand a successfully admitted remote continuation.

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
before doing so, and leaves the platform's explicit bound intact for other
build paths. The shim accepts and strips exactly one policy-equivalent one-job
spelling (`-j 1`, `-j1`, `--jobs 1`, or `--jobs=1`), rejects a non-1 or second
override, preserves `--` plus every following target verbatim, and invokes real
Ninja once with its own `-j 1`. The CPU quota and `TasksMax` remain independent
outer bounds.

Start the job with:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "Linux x86_64 browser artifact and password acceptance input" \
    --next "Fetch and verify the packaged artifact, then run the disposable password gate." -- \
    scripts/chromiumer-nix.sh run -- \
      bash scripts/build-chromiumer-linux.sh \
        helium-sync x86_64 linux-x86_64 "$job"
```

Product, architecture, deployment target, and build job ID are mandatory;
there is no inferred product or host-architecture default. The private binding
in `linux-product.conf` requires `helium-sync`, maps `x86_64` to
`linux-x86_64` and `arm64` to `linux-arm64-chroot`, binds the shared Passwords
source to its exact public ancestor, and binds the private Sync commit to the
repository `HEAD`. A different product or product/architecture target fails
before source preparation.

The driver writes one archive and its build-produced deployment receipt:

```text
.build/artifacts/helium-sync-linux-x86_64.tar.xz
.build/artifacts/helium-sync-linux-x86_64.receipt.env
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
    --summary "Linux arm64 Helium Sync chroot artifact" \
    --next "Fetch both files and verify the arm64 runtime receipt." -- \
    scripts/chromiumer-nix.sh run -- \
      bash scripts/build-chromiumer-linux.sh \
        helium-sync arm64 linux-arm64-chroot "$arm_job"
```

Source support and synthetic packaging checks do not substitute for a
completed arm64 compile. Either command is not ready until the current Nix
expression's expression-hash-named GC root has been realized and a fresh
capacity preflight passes. An older `chromium-150-*` root is not accepted as
evidence for a changed expression.

Android source acquisition has one shared backbone entry point:

```sh
scripts/chromium/prepare-android-source.sh .build/chromium-android
```

It reads `chromium/android-build.lock`, pins and verifies depot_tools, disables
depot_tools self-update and its local Git cache, verifies the direct launcher
before and after execution, and makes exactly one source request:

```text
gclient sync --jobs 1 --revision src@<locked-full-sha> --nohooks --no-history
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
runtime_kit_commit=$(sed -n 's/^HELIUM_ANDROID_RUNTIME_KIT_COMMIT=//p' \
  chromium/android-runtime-kit.lock)
runtime_kit_root=/home/d/.local/libexec/helium-android-runtime-kit-$runtime_kit_commit
runtime_kit_sha=$(sed -n 's/^HELIUM_ANDROID_RUNTIME_KIT_SOURCE_SHA256=//p' \
  chromium/android-runtime-kit.lock)

sync_job=hs-android-150-sync-test-01
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$sync_job" 80
scripts/chromiumer-job.sh start "$sync_job" \
  --summary "Chromium 150 disposable Helium Sync arm64 APK" \
  --next "Fetch and verify the Sync APK, then prepare disposable acceptance." -- \
  scripts/chromiumer-nix.sh run -- \
    env HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
      CHROMIUM_WORKSPACE=.build/chromium-android-sync-test \
      ARTIFACT_DIR=.build/android-sync-test-artifacts \
      HELIUM_ANDROID_RUNTIME_KIT_ROOT="$runtime_kit_root" \
      HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$runtime_kit_commit" \
      HELIUM_ANDROID_RUNTIME_KIT_SHA256="$runtime_kit_sha" \
      HELIUM_ANDROID_RUNTIME_KIT_VERIFIER=/home/d/.local/libexec/helium-android-tooling/verify-android-runtime-kit-source.sh \
      CHROMIUM_ANDROID_MANIFEST_PACKAGE=computer.helium.sync.test \
      CHROMIUM_ANDROID_PHASE=all \
      bash scripts/chromium/build-android-ci.sh

control_job=hs-android-150-control-test-01
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage "$control_job" 80
scripts/chromiumer-job.sh start "$control_job" \
  --summary "Same-source unmodified Chromium 150 arm64 control APK" \
  --next "Fetch and verify the control APK, then prepare disposable acceptance." -- \
  scripts/chromiumer-nix.sh run -- \
    env HELIUM_SYNC_REPO=. GITHUB_WORKSPACE=.build \
      CHROMIUM_WORKSPACE=.build/chromium-android-control \
      ARTIFACT_DIR=.build/android-control-artifacts \
      HELIUM_ANDROID_RUNTIME_KIT_ROOT="$runtime_kit_root" \
      HELIUM_ANDROID_RUNTIME_KIT_COMMIT="$runtime_kit_commit" \
      HELIUM_ANDROID_RUNTIME_KIT_SHA256="$runtime_kit_sha" \
      HELIUM_ANDROID_RUNTIME_KIT_VERIFIER=/home/d/.local/libexec/helium-android-tooling/verify-android-runtime-kit-source.sh \
      bash scripts/chromium/build-android-control-ci.sh
```

Do not run the two 80 GiB jobs concurrently. Before starting the second job,
fetch the first artifact and clean its verified workspace so the shared disk
admission is recomputed. Both artifact verifiers receive the saved
`$sync_commit`; this is the cross-job source binding. Sync and control also
prepend the locked Helium core `flags.gn`, carry it inside checksummed
provenance, forbid any locked key from appearing again in the appended
`args.gn`, and record the effective resolved values. The artifact plus final
A/B pair verifiers require both the source flags and effective locked values to
be byte-identical.

When a frozen exact product commit predates a current build-verifier fix, keep
that product checkout detached and clean. Run immutable copies of the current
`build-android-ci.sh` or `build-android-control-ci.sh`, media verifier, and
locked-GN verifier from the Chromiumer command instead of editing the frozen
checkout. Set `HELIUM_ANDROID_TOOLING_COMMIT` to the full commit containing
those copies, and point `HELIUM_ANDROID_MEDIA_CONFIG_VERIFIER` and
`HELIUM_ANDROID_LOCKED_GN_VERIFIER` at them. Each artifact records the tooling
commit and script hashes in `android-tooling.env`; the artifact verifier
recomputes every hash from that commit. The source commit/status fields still
bind the untouched product checkout. An external script without this
commit-and-hash binding is not admissible.

The runtime lifecycle kit is a second immutable source, not part of the frozen
product source. Materialize exactly the commit and checksum inventory in
`chromium/android-runtime-kit.lock`, pass its real directory plus all three
`HELIUM_ANDROID_RUNTIME_KIT_*` bindings and the immutable source verifier, and
record those bindings in `android-tooling.env` and `runtime-acceptance/kit.env`.
The artifact verifier compares every packaged lifecycle executable byte for
byte with that named commit. It rejects an old product-HEAD kit even when the
APK itself correctly comes from the frozen product commit.

Always preserve the commit from the staged source manifest and pass that exact
value to both artifact verifiers even if `main` advances while the detached job
runs. A clean ancestor artifact may be checksum/provenance verified and kept as
compile evidence. It is not a OnePlus runtime candidate unless that exact
commit is still the selected acceptance source, its generated overlay is
current, and its artifact-carried kit is the selected kit. Otherwise, finish
the evidence return and start a fresh Sync/control pair from the later exact
commit; never substitute the new `HEAD` as the old artifact's expected commit.

When each job reaches terminal success, fetch and verify the exact archive on
lm before cleanup:

```sh
scripts/chromiumer-job.sh terminal "$sync_job"
scripts/chromiumer-job.sh fetch "$sync_job" \
  .build/android-sync-test-artifacts/chrome_public_apk-arm64.tar.xz
sync_archive=/srv/nas/helium-builds/$sync_job/chrome_public_apk-arm64.tar.xz
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/chromium/verify-android-artifact.sh \
    "$sync_archive" computer.helium.sync.test "$sync_commit" \
    "$runtime_kit_commit"
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/android-media/prepare-disposable-acceptance.sh \
    "$sync_archive" computer.helium.sync.test "$sync_commit" \
    "$runtime_kit_commit" \
    /home/d/.local/state/helium-acceptance/$sync_job
scripts/chromiumer-job.sh cleanup "$sync_job"

scripts/chromiumer-job.sh terminal "$control_job"
scripts/chromiumer-job.sh fetch "$control_job" \
  .build/android-control-artifacts/chromium-control-apk-arm64.tar.xz
control_archive=/srv/nas/helium-builds/$control_job/chromium-control-apk-arm64.tar.xz
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/chromium/verify-android-artifact.sh \
    "$control_archive" computer.helium.control.test "$sync_commit" \
    "$runtime_kit_commit"
AAPT2=/home/d/Android/Sdk/build-tools/36.0.0/aapt2 \
  scripts/android-media/prepare-disposable-acceptance.sh \
    "$control_archive" computer.helium.control.test "$sync_commit" \
    "$runtime_kit_commit" \
    /home/d/.local/state/helium-acceptance/$control_job
scripts/chromiumer-job.sh cleanup "$control_job"
```

`prepare-disposable-acceptance.sh` refuses an existing output directory. Never
reuse or overwrite an earlier acceptance generation.

Test and production Sync builds both emit
`chrome_public_apk-arm64.tar.xz`. Fetch them into their distinct job-scoped NAS
directories and retain each wrapper-produced `artifact-receipt.env` beside its
archive. A common fetch directory is forbidden because the second basename
would collide with the first artifact and erase the product-role distinction.

`CHROMIUM_REF` may be omitted because the helper uses the lock; if supplied it
must equal the same full commit:

```sh
scripts/chromiumer-job.sh start "$job" \
    --summary "OnePlus arm64 APK for streaming, video, password, tab, and cookie validation" \
    --next "Fetch the APK and execute the documented disposable OnePlus acceptance sequence." -- \
    scripts/chromiumer-nix.sh run -- \
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

For a retained frozen build whose immutable operator produced a successful
fresh-graph boundary, finalize it externally from a clean current tooling
checkout. Do not edit or rerun the frozen product checkout, live build unit,
operator, or Ninja shim. The finalizer only reruns `ninja -t query`, captures
the concrete completed graph and exact producer sources, and packages the
already-built runtime into new outputs. Supply the real Ninja explicitly so
the capture cannot resolve the immutable shim through `PATH`:

```sh
HELIUM_BUILD_OPERATOR=/home/d/.local/state/helium-agent/eac8a57-linux-full-graph-node22-operator.sh \
HELIUM_NINJA_SHIM=/home/d/.local/libexec/helium-ninja-full-graph-node22/ninja \
HELIUM_REAL_NINJA=/nix/store/...-ninja-.../bin/ninja \
scripts/finalize-retained-linux-full-graph.sh \
  helium-sync x86_64 linux-x86_64 "$job" \
  "$frozen_product_checkout" \
  "$frozen_product_checkout/build/platforms/linux" \
  "/home/d/.local/state/helium-builds/$job/full-graph-boundary.env" \
  "/srv/nas/helium-builds/$job/final/helium-sync-linux-x86_64.tar.xz" \
  "/srv/nas/helium-builds/$job/final/helium-sync-linux-x86_64.receipt.env"
```

The output parent must already exist and all three outputs must be new. The
sibling `helium-sync-linux-x86_64.full-graph/` directory contains its schema-3
`receipt.env`, `SHA256SUMS`, concrete graph and target query, DevTools and
platform sources, graph boundary, operator, shim, recovery tool, and
finalization tools. The
schema-4 internal manifest and schema-2 deployment receipt both bind the graph
receipt and inventory hashes. A failed attempt is preserved; choose a new
empty output directory after diagnosing it.

The job20 false-positive is recoverable without source sync or GN. Its
immutable local receipt is
`/home/d/.local/state/helium-builds/hs-linux-x64-eac8a57-20/graph-gate-failure.env`
with SHA-256
`e3d6316545b45d4f4a8ac4525642f664a6f01f3954a374407e019446362c02ae`.
The retained-repair entry point rehashes that exact mode-0400 receipt,
operator, failed shim, frozen source, `build.ninja`, and `toolchain.ninja`.
It reproduces the failed broad 211/117 diagnostic but admits only the scoped
94 DevTools generate-CSS actions with zero missing tsconfig outputs. It also
rechecks the ui/kit output/phony/downstream graph, AI skill edge, and the
absence of pre-build outputs before invoking real Ninja directly at `-j 1`:

```sh
HELIUM_BUILD_OPERATOR=/home/d/.local/state/helium-agent/eac8a57-linux-full-graph-node22-operator.sh \
HELIUM_NINJA_SHIM=/home/d/.local/libexec/helium-ninja-full-graph-node22/ninja \
HELIUM_REAL_NINJA=/nix/store/...-ninja-.../bin/ninja \
scripts/continue-retained-linux-full-graph-failure.sh \
  helium-sync x86_64 linux-x86_64 hs-linux-x64-eac8a57-20 \
  "$frozen_product_checkout" \
  "$frozen_product_checkout/build/platforms/linux" \
  /home/d/.local/state/helium-builds/hs-linux-x64-eac8a57-20/graph-gate-failure.env \
  e3d6316545b45d4f4a8ac4525642f664a6f01f3954a374407e019446362c02ae \
  /srv/nas/helium-builds/hs-linux-x64-eac8a57-20/final/helium-sync-linux-x86_64.tar.xz \
  /srv/nas/helium-builds/hs-linux-x64-eac8a57-20/final/helium-sync-linux-x86_64.receipt.env
```

The entry point writes a mode-0400 preflight receipt before Ninja. A failed
Ninja invocation writes a separate immutable failure receipt and deliberately
refuses an automatic retry because outputs may then be partial. A successful
Ninja invocation writes the repair boundary and passes it to the ordinary
external finalizer. If only finalization fails after both binaries exist, do
not rebuild; diagnose it and invoke the finalizer with the preserved repair
boundary and entirely new artifact destinations.

Package build outputs as one file on chromiumer, then return that exact file.
The default destination is the NAS mounted on `lm`; pass a third argument only
when intentionally returning to another `lm` directory:

```sh
scripts/chromiumer-job.sh fetch "$job" \
    .build/artifacts/helium-sync-linux-x86_64.receipt.env
scripts/chromiumer-job.sh fetch "$job" \
    .build/artifacts/helium-sync-linux-x86_64.tar.xz

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
  helium-sync x86_64 linux-x86_64 \
  /srv/nas/helium-builds/"$job"/helium-sync-linux-x86_64.tar.xz \
  /srv/nas/helium-builds/"$job"/helium-sync-linux-x86_64.receipt.env \
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
copy of the deployment receipt and a separate mode-0600 version-3
`artifact-receipt.env` for disposable runtime acceptance. The latter admits
exactly one `runtime/helium-wrapper` entry point and binds the complete runtime
checksum inventory plus the re-audited private full-graph directory. It is not
an installer receipt. The native password gate
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
3. Run the complete `chrome` plus `chromedriver` target under that 80 GiB
   storage ceiling and the existing 5 GiB hard memory cap. Host
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
