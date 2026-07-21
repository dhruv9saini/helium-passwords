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
scripts/chromiumer-job.sh preflight
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
| Job tree | `100 GiB` allocated-block allowance for source, output, temp, and redirected caches; polled every 30 seconds |
| Free space | `20 GiB` operational reserve on the job filesystem; also on `/` when the job filesystem is separate |
| Host available memory | `2 GiB` required at start; watchdog stops after two readings below `1 GiB` |
| Wall time | hard `8h` systemd deadline |
| Concurrency | one active `helium-job-*` service on chromiumer |

For a new empty job, staging requires exactly `100 GiB + 20 GiB = 120 GiB`
available on the job filesystem. This is an admission envelope, not a claim
that Chromium always consumes 100 GiB, and the reserve is not build capacity.
Chromium's current Linux instructions require at least 100 GB free and say to
allocate roughly 50–80 GB for a build. Helium therefore permits a conservative
100 GiB total job tree and keeps another 20 GiB unused so ext4, SSH, systemd,
the health watcher, Nix/system logs, and unrelated work do not encounter a full
filesystem. On chromiumer's present root filesystem, 20 GiB is more than four
times the observed 4.2 GB steady-state use. It also provides headroom for disk
growth between watchdog samples. The 20 GiB value is Helium's operational
safety policy, not an upstream Chromium requirement.

At start, after source staging, the corrected gate is:

```text
required available = (100 GiB - current job-tree use) + 20 GiB reserve
```

For example, a 10 GiB staged job requires 110 GiB still available, not another
120 GiB. The old worker incorrectly demanded the full 120 GiB a second time and
therefore double-counted staged bytes. If the job tree already exceeds 100 GiB,
startup fails. The worker measures allocated filesystem blocks rather than
apparent file sizes. The 100 GiB check is a watchdog ceiling, not an ext4
project quota, so the runbook does not describe it as an instantaneous hard
quota.

Admission also requires cgroup v2 CPU, memory, I/O, and PID controllers; a
running user systemd manager; Git; Python 3; and the basic supervision tools.
If the job tree moves to a dedicated filesystem, the worker independently
requires 20 GiB free on chromiumer's root filesystem. Any failed check refuses
startup.

The watchdog writes `health.env` every 30 seconds with job-filesystem free
space, root-filesystem free space, allocated job-tree size, available memory,
and load. A disk, workspace, or memory violation stops
the entire build cgroup. `MemoryMax`, `CPUQuota`, `TasksMax`, idle I/O priority,
and the systemd runtime deadline remain enforced even if the watchdog itself
fails.

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
scripts/chromiumer-job.sh stage "$job"
```

For the private repository, invoke the same inherited wrapper from Sync:

```sh
cd /home/d/coding/helium/helium-sync
scripts/dev.sh check

job=hs-android-150-sync-01
scripts/chromiumer-job.sh stage "$job"
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
immediately after creating the isolated job and watchdog.

For public Linux x86_64, the prepared platform wrapper forwards the enforced
two-job limit into its Dockerized Ninja invocation:

```sh
scripts/chromiumer-job.sh start "$job" -- \
    bash scripts/build.sh linux x86_64
```

For Sync Android, pin `CHROMIUM_REF` to an immutable Chromium commit; never use
the script's moving `main` default for a validation artifact:

```sh
scripts/chromiumer-job.sh start "$job" -- \
    env \
      HELIUM_SYNC_REPO=. \
      GITHUB_WORKSPACE=.build \
      CHROMIUM_REF=<full-chromium-commit> \
      CHROMIUM_ANDROID_PHASE=all \
      bash scripts/chromium/build-android-ci.sh
```

Linux/Android jobs additionally need a reproducible chromiumer build
environment. Helium Linux currently expects Docker. Chromium's NixOS guidance
requires running depot tools in its Nix shell. Record the Nix system closure,
Docker image ID when applicable, exact command, GN args, patch hashes, and
Chromium commit alongside the source manifest before accepting an artifact.

## Status, Logs, Cancellation, and Artifacts

These commands run from the repository on `lm`:

```sh
scripts/chromiumer-job.sh status "$job"
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
/home/d/.local/state/helium-builds/<job>/job.log
```

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
disk whose 116 GiB root filesystem had about 106 GiB available. The empty-job
120 GiB gate can never pass on that filesystem, even if it is otherwise empty.
It had no separate build disk or NAS mount,
and `git`, Python 3, Docker, and Chromium tools were absent from the normal
login `PATH`. Production preflight therefore refuses the host. Chromium's
current Linux instructions require at least 100 GB free, recommend more than
16 GB RAM, and recommend substantial swap for an 8 GB machine:

<https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md>

The setup gate is:

1. Add or mount a local chromiumer build filesystem with at least 120 GiB
   available after tools/caches, while retaining at least 20 GiB free on `/`;
   do not use `lm`'s NAS as the live build directory.
2. Provision a pinned Nix/Docker toolchain containing Git, Python 3, depot
   tools/build dependencies, and Docker for the Helium Linux wrapper.
3. Prefer adding RAM and swap before expecting a full link to finish; the
   isolation limits protect the machine but may make the build fail cleanly.
4. Re-run `connection`, `preflight`, and the short wrapper test before staging.

The corrected harmless wrapper test was executed as
`wrapper-test-20260721-143505`. It completed with exit code 0 while live systemd
properties reported a 50% CPU quota, 128/256 MiB memory high/max, zero swap,
I/O weight 10 with idle scheduling, 32 tasks, and a two-minute test deadline.
The watchdog reported `status=ok`, recorded both root and job-filesystem free
space, and measured the complete test job tree. The generated test workspace
was removed; its small proof log and policy/state files remain on chromiumer.
The pure arithmetic check also proves `0 GiB used -> 120 GiB required`, `10 GiB
used -> 110 GiB required`, and `100 GiB used -> 20 GiB required`. Production
preflight then refused the real host with 113,542,557,696 bytes available versus
128,849,018,880 bytes required for an empty job.

Re-run the same proof without starting Chromium:

```sh
scripts/chromiumer-job.sh test
```
