# Pinned Chromiumer Nix Environment

The resource-isolation wrapper and the build tool environment solve different
problems. `scripts/chromiumer-job.sh` transfers clean committed source and the
remote worker constrains the job. `scripts/chromiumer-nix.sh` supplies the
userspace programs and shared libraries inside that already-constrained job.
It cannot start a build directly: `run` refuses unless it sees chromiumer,
all four wrapper job variables set to exactly one, the wrapper-owned temporary
directory, and a `helium-job-*.service` cgroup.

The expression is `chromium/nix/chromiumer-shell.nix`. It uses the exact
nixpkgs revision and hash selected by Chromium 150.0.7871.181 at commit
`24b04c927b23c39cf9c5227cc8dc6f64a744c8e9`. It adds Helium's Python modules,
source-transfer, patch, archive, and provenance tools to Chromium's matching
NixOS runtime libraries. The public Linux path additionally supplies the exact
host tools its pinned platform build invokes directly: Node 22, Ninja, Bison,
Flex, Yasm, and ImageMagick. It deliberately omits Chromium's Google Cloud SDK
and downloaded clangd bundle because Helium does not use remote execution on
chromiumer and the host's disk reserve is small.

The expression returns the `buildFHSEnv` derivation, whose output contains
`bin/helium-chromium-150-env`. It does not return that derivation's `.env`
attribute: `.env` is an interactive `nix-shell` helper and `nix-build` refuses
to realize it.

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
job=hp-nix-linux-150-01
scripts/chromiumer-job.sh stage "$job" 20
scripts/chromiumer-job.sh start "$job" \
  --summary "Pinned Chromium 150 Nix environment realization" \
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

`realise` refuses direct SSH execution and creates a stable GC root named
`~/.local/state/helium-build-env/chromium-150-<expression-hash-prefix>`; it
refuses to replace an existing root. An expression change therefore creates a
new root instead of silently reusing an older closure. `provenance` records
the full expression hash, resolved store path, complete closure hash and size,
Nix version, Chromium commit, and nixpkgs commit. Copy that output into the
build's provenance directory. Do not remove an older root or run
`nix-collect-garbage` as part of a Helium job.

The provenance also records realization start/end free bytes, measured delta,
20 GiB realization budget, 82 GiB post-realization floor, and 102 GiB start
gate. Job `hs-nix-150-a0820646-01` realized the current expression at
`chromium-150-a0820646387c653b`. Root availability changed from 110,053,076,992
to 109,691,019,264 bytes, a measured 362,057,728-byte delta. The exact closure
contains 1,853,912,336 bytes and hashes to
`a3e8b195d0e69263de2239e5410fc3509de22c8c3ed0657c82d387816bd40d57`.
Returned provenance is stored at
`/srv/nas/helium-builds/hs-nix-150-a0820646-01/chromiumer-nix.env`; its SHA-256
is `a87f590a5519db58633cd31f99a67d09b4f9e1ea9ac3ffb448fe94f0f4d147b6`.

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
realization is not evidence that a full compile will fit. The first public
validation invokes the complete Linux `chrome` and `chromedriver` targets with
an 80 GiB job-tree ceiling. That ceiling makes it a capacity measurement; it
does not turn the command into a small-target build. The exact sequence is
documented in `docs/chromiumer-builds.md`.

The current realization, provenance return, cleanup, and fresh 80 GiB preflight
are complete. The serialized Android validation train retains chromiumer until
its explicit artifact-and-cleanup handoff. After that handoff, rerun connection
and preflight because admission is always based on live capacity. The exact
compile successor is:

```sh
cd /home/d/coding/helium/helium-passwords
scripts/chromiumer-job.sh preflight 80
job=hp-linux-150-passwords-01
scripts/chromiumer-job.sh stage "$job" 80
scripts/chromiumer-job.sh start "$job" \
  --summary "Linux x86_64 browser artifact and password acceptance input" \
  --next "Fetch and verify the packaged artifact, then run the disposable password gate on da." -- \
  scripts/chromiumer-nix.sh run -- \
    bash scripts/build-chromiumer-linux.sh \
      helium-sync x86_64 linux-x86_64 "$job"
```

Use `scripts/chromiumer-job.sh cancel "$job"` as the one cancellation command.
Fetch and verify the returned archive exactly as documented in
`chromiumer-builds.md`.
