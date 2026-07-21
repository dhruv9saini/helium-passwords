# Helium Passwords Issues

This is the public issue ledger. IDs are stable so private Helium Sync work can
refer to the same backbone problems without publishing private implementation
details.

| ID | Priority | Status | Issue | Exit criterion |
| --- | --- | --- | --- | --- |
| HP-001 | P0 | Open | The patch train is based on Chromium 148 while upstream Helium is on Chromium 150. | One exact Helium/platform train is pinned, both patches apply, Linux compiles, and the manifest records all commits and hashes. |
| HP-002 | P0 | Open | Native save, update, storage, suggestion, and autofill behavior has no automated runtime coverage. | The disposable-profile password acceptance gate in `DEVELOPMENT.md` passes on Linux and the platform-specific manual subset passes on macOS and Windows. |
| HP-003 | P0 | Open | UI restoration follows Helium removals hunk by hunk and is already stale at `PasswordSuggestionGenerator`. | Every current upstream password/autofill removal is inventoried and the refreshed overlay is reviewed against the same Chromium source. |
| HP-004 | P1 | Open | Fast CI proves injection only, not patch application. | CI has a source-backed `git apply --check`/Helium patch-prepare gate before any multi-hour build. |
| HP-005 | P1 | Open | The last full matrix did not complete Windows or macOS x86_64. | All six desktop artifact jobs finish or unsupported targets are explicitly removed from the matrix. |
| HP-006 | P1 | Open | Builds use moving platform `main` refs and do not emit a complete provenance manifest. | Platform commits, Helium core, Chromium version, GN args, patch hashes, and artifact hash are immutable build inputs/outputs. |
| HP-007 | P2 | Ready locally | Repositories and developer commands were fragmented. | Both repos live under `/home/d/coding/helium`, share `scripts/dev.sh`, and Sync contains Passwords `main` through Git ancestry. |
| HP-008 | P2 | Open | There are no public fixture pages or browser-driving acceptance tests. | A small local test site and driver cover save/update/autofill without real credentials or profiles. |
| HP-009 | P0 | Blocked | Chromiumer SSH and isolation are ready, but its 106 GiB available disk cannot satisfy the 100 GiB workspace plus 20 GiB reserve and the build toolchain is absent. | Chromiumer has a local build filesystem with at least 120 GiB available, a pinned Nix/Docker toolchain, and production `scripts/chromiumer-job.sh preflight` passes. |

Do not close an issue based only on patch metadata lint or overlay injection.
