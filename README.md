# Helium Passwords

Helium Passwords restores Chromium's native password manager in Helium and
adds private-Tailnet password convergence. It also supplies independent
password, cookie, and local-tab recovery. This public repository is the sole
product source and build-provenance authority.

The product contract and current implementation boundary are
[docs/architecture.md](docs/architecture.md). The executable release gates are
[docs/acceptance.md](docs/acceptance.md), and [TODO.md](TODO.md) is the
canonical public issue ledger. The shared artifact-bound native password
protocol is [docs/password-runtime-acceptance.md](docs/password-runtime-acceptance.md);
its password-convergence evidence extension is
[docs/password-runtime-sync-acceptance.md](docs/password-runtime-sync-acceptance.md),
and the exact password, cookie, and tab recovery mechanisms are in
[docs/nine-path-recovery.md](docs/nine-path-recovery.md). Historical
mixed-kind cookie-sync and OnePlus-CDP gates are retained only to audit old
synthetic receipts and are not current execution paths.

## Invariants

- d is the only initial password seed.
- da and oneplus join pending and pull-only. They cannot bulk-publish their
  initial state.
- Passwords use Chromium's native password store. Browserpass, Bitwarden,
  extension vaults, CDP writers, and raw password-database mutation are not
  product paths.
- Cookies are backup and restore data only. Normal browsing never publishes,
  pulls, or reconciles cookies through the Tailnet. Cookie drills use synthetic
  accounts and disposable profiles through Chromium's native `CookieManager`.
- The Tailnet is the confidentiality boundary. The lm server stores readable
  authenticated JSON records and only hashed device bearer credentials. Do not
  add an inner record-encryption protocol, a private inner TLS CA, a public Funnel, or a
  Tailscale Serve listener on the Sync port. Unrelated tailnet-only Serve
  routes may coexist and Helium operators leave them unchanged.
- Tabs never enter sync. They remain device-local and are protected by local
  recovery, atomic versioned snapshots, and two private off-source copies.
- Passwords, cookies, and tabs each have exactly three materially different
  recovery mechanisms. Replica destinations strengthen one mechanism and do
  not inflate that count; the nine-path matrix and exact storage locations are
  defined in [docs/nine-path-recovery.md](docs/nine-path-recovery.md).
- No personal profile is touched until all compiled disposable gates pass and
  that profile has a verified recoverable backup.
- Chromium is never built on lm. Every large build uses the isolated
  [chromiumer workflow](docs/chromiumer-builds.md) and its durable completion
  monitor. The monitor records terminal state locally on da; it never launches
  an assistant or uses OpenBubbles, activation payloads, Mailbridge, a work
  queue, email, or a personal relay. A frozen product commit may use only hash-bound newer build
  tooling recorded separately in the artifact; its product source stays clean
  and retains its own exact commit identity.

## Repository map

- `chromium/overlay/`: native password sync, cookie recovery, enrollment, and local tab
  snapshot integration.
- `chromium/patches/`: generated overlay plus desktop/Android wiring.
- `internal/syncstore/`: readable record server, hash-only bearer enrollment,
  scoped credentials, CAS conflicts, tombstones, and atomic journal recovery.
- `internal/tabsnapshot/` and `scripts/tabs/`: device-local generations,
  validation, retention, private two-destination backup, quarantine, and
  disposable restore. The runtime proof adapter supports marked desktop drills
  and only the checksum-admitted `computer.helium.sync.test` Android sandbox;
  Android profile bytes are round-trip fingerprinted and every launch remains
  inside the guarded disposable browser boundary.
- `scripts/chromium/`: pinned Android composition, codec/streaming provenance,
  remote compile entry points, and the verifier for the separately locked
  Android runtime-acceptance kit. `chromium/android-runtime-kit.lock` is the
  sole accepted lifecycle-kit identity; a frozen product commit never supplies
  acceptance files implicitly.
- `scripts/password-runtime/`: shared artifact-bound native password fixture
  and UI receipt plus the private Sync state/journal receipt extension.
- `scripts/cookie-runtime/`: historical mixed-kind receipt auditor; current
  cookie recovery is the native neutral path, stopped compressed profile, and
  encrypted restic profile repository.
- `scripts/native-recovery/`: browser-API password/cookie neutral snapshots,
  fixed NAS-plus-peer backup scheduling, fresh marked desktop and
  checksum-admitted `.test`-only Android restore drills, and the per-device
  two-destination receipt gate.
- `scripts/android-acceptance/`: guarded `.test`-only package admission,
  physical-device identity receipts, and historical fleet-receipt auditors.
- `systemd/helium-syncd.service`: least-privilege HTTP service bound only to
  lm's Tailscale IPv4 address.
- `scripts/install-lm-sync-service.sh`: install/initialize/activation gates;
  it rejects every public Funnel plus every Serve listener, Web proxy, and TCP
  forward whose parsed numeric port is 44719 (including leading-zero forms)
  without changing unrelated tailnet-only Serve routes. Present `Foreground`
  and `Services` containers and every recursively descended config must be
  objects; malformed or null configs fail closed. The operator does not enable
  the service unless the endpoint matches lm's live
  Tailscale IPv4 and the server restore drill passed. State-changing
  operator actions are serialized, and activation refuses any existing
  listener on the canonical service port.
- `scripts/tailnet-serve-acceptance.sh`: create-new Gate 0 evidence that
  requires the canonical unrelated Serve configuration to be byte-identical
  before and after a disposable acceptance run.
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

The command validates patch composition, Go password protocol and recovery tests,
password/cookie/tab recovery tests, media/streaming fixtures, Chromiumer
isolation arithmetic, terminal monitoring, and shared public ancestry. It is not a
substitute for a native compile or disposable browser run.

## Chromium builds

On chromiumer, do not use the Docker-backed local command. Use the isolated
Nix entry point and pass an explicit product, architecture, deployment target,
and job ID to `scripts/build-chromiumer-linux.sh` exactly as shown in
[docs/chromiumer-builds.md](docs/chromiumer-builds.md). The driver returns one
provenance-bound archive plus its strict build-produced deployment receipt;
`scripts/verify-linux-runtime.sh` must admit both before the executable can
enter the disposable native-password gate. The guarded Ninja shim preserves
the platform's one-job intent, strips one equivalent `-j 1` spelling, stops at
Ninja's `--` target delimiter, rejects non-1 or duplicate overrides, and
invokes real Ninja once with `-j 1`.

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

The wrapper caps the complete systemd cgroup at one build job, 200% CPU, 5 GiB
memory, idle I/O priority, 256 tasks, the declared workspace budget, a 2 GiB
root floor, and eight hours. Builds are detached, watched, journaled, and
recorded exactly once in protected local terminal state on da. No terminal
result is delivered to an account or assistant endpoint.
Returned artifacts are checksum-verified before a workspace can be cleaned.

## Desktop patch flow

`patches/series` is the canonical direct-build overlay list. Desktop platform
preparation copies only the two password-restoration patches into
`patches/helium/passwords/` and appends them to the platform series. The two
Android compatibility patches remain on the direct Android source path; the
desktop target gate proves they are absent from Linux, macOS, and Windows.
Desktop preparation also removes
`helium/hop/disable-password-manager.patch` from the cloned Helium core before
the platform applies its series.

## Installation boundary

`scripts/laptop/install-laptop-sync.sh` installs only the native browser
artifact, the enrollment client, local tab tool, and launcher. It does not
create enrollment state or start a daemon. `scripts/android-local/install-phone-sync.sh`
does not install CookieCloud, CDP writers, or a server into the phone chroot.

Password enrollment is deliberately separate from binary installation. Follow
[docs/deployment.md](docs/deployment.md) only after the artifact and disposable
acceptance gates pass.

## License

Repository-original code is GPL-3.0; imported material keeps its original
license. See [LICENSE](LICENSE).
