# Pinned Chromiumer Nix Environment

The resource-isolation wrapper and the build tool environment solve different
problems. `scripts/chromiumer-job.sh` transfers clean committed source and the
remote worker constrains the job. `scripts/chromiumer-nix.sh` supplies the
userspace programs and shared libraries inside that already-constrained job.
It cannot start a build directly: `run` refuses unless it sees chromiumer,
`HELIUM_BUILD_JOBS=2`, the wrapper-owned temporary directory, and a
`helium-job-*.service` cgroup.

The expression is `chromium/nix/chromiumer-shell.nix`. It uses the exact
nixpkgs revision and hash selected by Chromium 148.0.7778.178 at commit
`d096af1c9e98c45c3596e59620622b1a049bfecb`. It adds Helium's Python modules,
source-transfer, patch, archive, and provenance tools to Chromium's matching
NixOS runtime libraries. It deliberately omits Chromium's Google Cloud SDK and
downloaded clangd bundle because Helium does not use remote execution on
chromiumer and the host's disk reserve is small.

## One-time realization

Realization changes `/nix/store`, outside the worker's job-tree measurement, so
it runs as its own isolated **20 GiB** admission job before any browser job. It
inherits the production CPU, memory, I/O, task and wall-time bounds. The Nix
entry point separately records root free space and enforces:

```text
start gate = 80 GiB future browser budget + 2 GiB root floor
             + 20 GiB maximum Nix-store growth
           = 102 GiB

stop if Nix-store-era root delta > 20 GiB
or if root available space < 82 GiB
```

The 20 GiB wrapper budget also bounds the staged realization job tree; it does
not claim that `/nix/store` is inside that tree. The explicit root delta is the
separate accounting for Nix.

```sh
cd /home/d/coding/helium/helium-passwords
scripts/chromiumer-job.sh connection
scripts/chromiumer-job.sh preflight 20
job=hp-nix-env-148
scripts/chromiumer-job.sh stage "$job" 20
scripts/chromiumer-job.sh start "$job" \
  --summary "Pinned Chromium 148 Nix environment realization" \
  --next "Fetch its provenance, clean the staging job, and rerun preflight 80." -- \
  bash -c 'scripts/chromiumer-nix.sh check &&
    scripts/chromiumer-nix.sh realise &&
    mkdir -p build-provenance &&
    scripts/chromiumer-nix.sh provenance >build-provenance/chromiumer-nix.env'
scripts/chromiumer-job.sh terminal "$job"
scripts/chromiumer-job.sh fetch "$job" build-provenance/chromiumer-nix.env
scripts/chromiumer-job.sh cleanup "$job"

# Realization consumed root space outside its job tree. Browser admission must
# be recomputed against the actual remaining space.
scripts/chromiumer-job.sh preflight 80
```

`realise` refuses direct SSH execution and creates the stable GC root
`~/.local/state/helium-build-env/chromium-148`; it refuses to replace an
existing root. `provenance` records its resolved store path, complete closure
hash and size, Nix version, Chromium commit, and nixpkgs commit. Copy that
output into the build's provenance directory. Do not run `nix-collect-garbage`
as part of a Helium job.

The provenance also records realization start/end free bytes, measured delta,
20 GiB realization budget, 82 GiB post-realization floor, and 102 GiB start
gate. At the audited 105.7 GiB free, the start gate has only about 3.7 GiB of
headroom before realization starts; any unrelated growth can correctly refuse
or stop the operation.

The environment has not been realized merely because its source and pin checks
pass. A successful `realise`, a recorded closure, and a fresh production
preflight are three separate gates.

## Bounded build command

After staging the actual browser source through the normal wrapper, enter the
environment as the build command:

```sh
scripts/chromiumer-job.sh start "$job" \
  --summary "Bounded Android source, media, and APK validation" \
  --next "Fetch the artifact and run disposable device acceptance." -- \
  scripts/chromiumer-nix.sh run -- \
    bash scripts/chromium/build-android-ci.sh
```

The environment inherits the wrapper's job-count, cache, temporary-directory,
CPU, memory, I/O, process, disk, watchdog, and wall-time policy. It does not
raise or replace any limit. The single cancel command remains:

```sh
scripts/chromiumer-job.sh cancel "$job"
```

Chromium's current Linux instructions require NixOS users to enter the
source-provided Nix shell and call for at least 100 GB free space, with more
than 16 GB RAM highly recommended. Chromiumer has less RAM and only narrowly
admits the repository's declared build budgets, so successful shell
realization is not evidence that a full compile will fit. The first validation
must remain the bounded source/patch and small-target sequence documented in
`docs/chromiumer-builds.md`.
