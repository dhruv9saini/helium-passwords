# Helium Sync

Helium Sync is the private personal-browser layer on top of the public
[Helium Passwords](https://github.com/dhruv9saini/helium-passwords) backbone.
The two repositories share normal Git ancestry, patch tooling, the pinned
Chromium environment, and the chromiumer build workflow. This repository adds
native password and login-session convergence across the private Tailnet plus
device-local tab durability for d, da, and oneplus.

The product contract and current implementation boundary are
[docs/architecture.md](docs/architecture.md). The executable release gates are
[docs/acceptance.md](docs/acceptance.md), and [TODO.md](TODO.md) is the
canonical private issue ledger. The shared artifact-bound native password
protocol is [docs/password-runtime-acceptance.md](docs/password-runtime-acceptance.md);
its private Sync evidence extension is
[docs/password-runtime-sync-acceptance.md](docs/password-runtime-sync-acceptance.md).

## Invariants

- d is the only initial password seed.
- da and oneplus join pending and pull-only. They cannot bulk-publish their
  initial state.
- Passwords use Chromium's native password store. Cookies use Chromium's native
  `CookieManager`. Normal installs and launches do not use CDP writers,
  CookieCloud, a phone-local server, or copied profile databases.
- The Tailnet is the confidentiality boundary. The lm server stores readable
  authenticated JSON records and only hashed device bearer credentials. Do not
  add content encryption, a private inner TLS CA, or public Serve/Funnel routes.
- Tabs never enter sync. They remain device-local and are protected by local
  recovery, atomic versioned snapshots, and two private off-source copies.
- No personal profile is touched until all compiled disposable gates pass and
  that profile has a verified recoverable backup.
- Chromium is never built on lm. Every large build uses the isolated
  [chromiumer workflow](docs/chromiumer-builds.md) and its durable completion
  notification.

## Repository map

- `chromium/overlay/`: native password, cookie, enrollment, and local tab
  snapshot integration.
- `chromium/patches/`: generated overlay plus desktop/Android wiring.
- `internal/syncstore/`: readable record server, hash-only bearer enrollment,
  scoped credentials, CAS conflicts, tombstones, and atomic journal recovery.
- `internal/tabsnapshot/` and `scripts/tabs/`: device-local generations,
  validation, retention, private two-destination backup, quarantine, and
  disposable restore.
- `scripts/chromium/`: pinned Android composition, codec/streaming provenance,
  and remote compile entry points.
- `scripts/password-runtime/`: shared artifact-bound native password fixture
  and UI receipt plus the private Sync state/journal receipt extension.
- `systemd/helium-syncd.service`: least-privilege HTTP service bound only to
  lm's Tailscale IPv4 address.
- `scripts/install-lm-sync-service.sh`: install/initialize/activation gates;
  it keeps Tailscale Serve/Funnel empty and does not enable the service unless
  the endpoint matches lm's live Tailscale IPv4 and the server restore drill
  passed. State-changing
  operator actions are serialized, and activation refuses any existing
  listener on the canonical service port.
- `scripts/helium-sync-server-backup.sh`: read-only validation and versioned
  backup of only the hashed registry, readable journal, journal snapshots, and
  optional quarantine. It never archives client bearer tokens.
- `docs/deployment.md`: exact seed, join, rotation, backup, and rollback
  sequence.

## Lightweight verification

These checks are safe on lm and use only synthetic data:

```sh
scripts/dev.sh check
```

The command validates patch composition, Go protocol and recovery tests,
password/cookie/tab state-machine tests, media/streaming fixtures, Chromiumer
isolation arithmetic, notifications, and shared public ancestry. It is not a
substitute for a native compile or disposable browser run.

## Chromium builds

On chromiumer, do not use the Docker-backed local command. Use the isolated
Nix entry point and pass an explicit product, architecture, deployment target,
and job ID to `scripts/build-chromiumer-linux.sh` exactly as shown in
[docs/chromiumer-builds.md](docs/chromiumer-builds.md). The driver returns one
provenance-bound archive plus its strict build-produced deployment receipt;
`scripts/verify-linux-runtime.sh` must admit both before the executable can
enter the disposable native-password gate.

The source of truth is the pinned Nix environment and detached wrapper:

```sh
scripts/chromiumer-job.sh connection
scripts/chromiumer-job.sh preflight 80
scripts/chromiumer-job.sh stage JOB 80
scripts/chromiumer-job.sh start JOB --summary "..." --next "..." -- \
  scripts/chromiumer-nix.sh run -- COMMAND
scripts/chromiumer-job.sh status JOB
scripts/chromiumer-job.sh logs JOB 120
scripts/chromiumer-job.sh cancel JOB
```

The wrapper caps the complete systemd cgroup at two jobs, 200% CPU, 5 GiB
memory, idle I/O priority, 256 tasks, the declared workspace budget, a 2 GiB
root floor, and eight hours. Builds are detached, watched, journaled, and
reported exactly once through lm Mailbridge to `dhruv.codex@gmail.com`.
Returned artifacts are checksum-verified before a workspace can be cleaned.

## Installation boundary

`scripts/laptop/install-laptop-sync.sh` installs only the native browser
artifact, the enrollment client, local tab tool, and launcher. It does not
create enrollment state or start a daemon. `scripts/android-local/install-phone-sync.sh`
does not install CookieCloud, CDP writers, or a server into the phone chroot.

Actual enrollment is deliberately separate from binary installation. Follow
[docs/deployment.md](docs/deployment.md) only after the artifact and disposable
acceptance gates pass.

## License

Repository-original code is GPL-3.0; imported material keeps its original
license. See [LICENSE](LICENSE).
