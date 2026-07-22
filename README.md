# Helium Sync

Helium Sync is the private personal-browser layer on top of the public
[Helium Passwords](https://github.com/dhruv9saini/helium-passwords) backbone.
The two repositories share normal Git ancestry, patch tooling, the pinned
Chromium environment, and the chromiumer build workflow. This repository adds
native end-to-end encrypted password and login-session convergence plus
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
- The lm server stores opaque authenticated ciphertext and hashed device
  credentials. Content and recovery keys never belong on lm, its server data,
  the NAS server backup, chromiumer, or Git.
- Tabs never enter sync. They remain device-local and are protected by local
  recovery, atomic versioned snapshots, and two encrypted off-source copies.
- No personal profile is touched until all compiled disposable gates pass and
  that profile has a verified recoverable backup.
- Chromium is never built on lm. Every large build uses the isolated
  [chromiumer workflow](docs/chromiumer-builds.md) and its durable completion
  notification.

## Repository map

- `chromium/overlay/`: native password, cookie, enrollment, and local tab
  snapshot integration.
- `chromium/patches/`: generated overlay plus desktop/Android wiring.
- `internal/syncstore/`: opaque server, client-side E2EE protocol, enrollment,
  scoped credentials, rotations, CAS conflicts, tombstones, and encrypted d
  recovery export/import.
- `internal/tabsnapshot/` and `scripts/tabs/`: device-local generations,
  validation, retention, encrypted two-destination backup, quarantine, and
  disposable restore.
- `scripts/chromium/`: pinned Android composition, codec/streaming provenance,
  and remote compile entry points.
- `scripts/password-runtime/`: shared artifact-bound native password fixture
  and UI receipt plus the private Sync state/journal receipt extension.
- `systemd/helium-syncd.service`: least-privilege direct TLS service bound only
  to lm's Tailscale IPv4 address.
- `scripts/install-lm-sync-service.sh`: install/initialize/activation gates;
  it keeps Tailscale Serve/Funnel empty and does not enable the service unless
  an offline-CA-signed, endpoint-constrained TLS generation matches lm's live
  tailnet identity and the opaque restore drill passed. State-changing
  operator actions are serialized, and activation refuses any existing
  listener on the canonical service port.
- `scripts/helium-sync-server-backup.sh`: read-only validation and versioned
  backup of only the hashed registry, opaque journal, journal snapshots, and
  optional opaque quarantine. It never archives d client state, content keys,
  recovery identities, or recovery-recipient configuration.
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
