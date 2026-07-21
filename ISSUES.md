# Helium Passwords Issues

This is the public issue ledger. IDs are stable so private Helium Sync work can
refer to the same backbone problems without publishing private implementation
details.

| ID | Priority | Status | Issue | Exit criterion |
| --- | --- | --- | --- | --- |
| HP-001 | P0 | Open | The patch train is based on Chromium 148 while upstream Helium is on Chromium 150. | One exact Helium/platform train is pinned, both patches apply, Linux compiles, and the manifest records all commits and hashes. |
| HP-002 | P0 | Open | Native save, update, storage, suggestion, and autofill behavior has no automated runtime coverage. | The disposable-profile password acceptance gate in `DEVELOPMENT.md` passes on Linux and the platform-specific manual subset passes on macOS and Windows. |
| HP-003 | P0 | Chromium 148 replay complete; Chromium 150 update open | The two restoration patches are refreshed against the actual Chromium-148-plus-Helium series. The focused replay also found and removed a second importer path that stripped passwords. | Repeat the removal inventory and source replay for the selected Chromium 150 Helium train, then compile and run HP-002. |
| HP-004 | P1 | Local source gate complete; CI wiring open | `scripts/check-password-patch-stack.sh` fetches only the 15 affected official Chromium 148 files, replays the ordered Helium patches, applies both restoration patches, and asserts the restored policy/UI/importer surfaces. | Run the same source-backed gate in CI before any multi-hour build. |
| HP-005 | P1 | Open | The last full matrix did not complete Windows or macOS x86_64. | All six desktop artifact jobs finish or unsupported targets are explicitly removed from the matrix. |
| HP-006 | P1 | Open | Builds use moving platform `main` refs and do not emit a complete provenance manifest. | Platform commits, Helium core, Chromium version, GN args, patch hashes, and artifact hash are immutable build inputs/outputs. |
| HP-007 | P2 | Ready locally | Repositories and developer commands were fragmented. | Both repos live under `/home/d/coding/helium`, share `scripts/dev.sh`, and Sync contains Passwords `main` through Git ancestry. |
| HP-008 | P2 | Fixture complete; browser driver open | The dependency-free loopback fixture provides same-origin login and password-change forms with correct autocomplete semantics, never parses/logs/reflects submitted values, and has synthetic HTTP tests. | A disposable-browser driver uses the fixture to prove native save/update/autofill without real credentials or profiles. |
| HP-009 | P0 | Disk admission ready; toolchain and compile open | Chromiumer SSH and isolation are ready. Jobs now declare their own disk budgets; the existing SSD passes the 80 GiB bounded-proof gate while preserving a 2 GiB unprivileged root floor in addition to ext4's 5.91 GiB root-only reserve. | A pinned Nix tool environment is recorded, `scripts/chromiumer-job.sh preflight 80` and the bounded source/compile proof pass, and the artifact records complete provenance. |

Do not close an issue based only on patch metadata lint or overlay injection.
