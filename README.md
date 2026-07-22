# helium-passwords

Password manager and autofill restoration overlay for
[Helium Browser](https://github.com/imputnet/helium).

See [DEVELOPMENT.md](DEVELOPMENT.md) for the shared Passwords/Sync architecture,
developer commands, upstream update train, and acceptance gates. The current
public work inventory is in [ISSUES.md](ISSUES.md). Large Linux and Android
builds use the enforced lm-to-chromiumer workflow in
[docs/chromiumer-builds.md](docs/chromiumer-builds.md); never build Chromium on
lm. Terminal build results are delivered through the lm-only durable path in
[docs/job-notifications.md](docs/job-notifications.md).

This is no longer a Linux packaging fork. The repo only keeps the password
patches plus a small wrapper that clones the official Helium platform repo,
injects the overlay, removes Helium's upstream password-disable patch, and runs
that platform's native build.

## Targets

The GitHub Actions target matrix covers the official desktop OS/architecture
set and verifies that each platform checkout receives the password and payment
overlay. Full Chromium builds still run through the local wrapper commands
below on a matching host, or by dispatching the build workflow with
`run-build` enabled.

| OS | Architectures |
| --- | --- |
| Linux | `x86_64`, `arm64` |
| macOS | `x86_64`, `arm64` |
| Windows | `x86_64`, `arm64` |

## Local Build

Builds must run on the matching host OS. Chromium builds are large, so expect a
long run and significant disk usage.

```bash
bash scripts/build.sh linux x86_64
bash scripts/build.sh linux arm64
bash scripts/build.sh macos x86_64
bash scripts/build.sh macos arm64
bash scripts/build.sh windows x86_64
bash scripts/build.sh windows arm64
```

The wrapper clones platform repos under `build/platforms/` by default. Override
repo URLs, clone ref, or the work directory in `helium-passwords.conf` or by
exporting the same variables before running a script.

## Releases

Dispatch **Build Helium Passwords** with `create-release` enabled to run the
selected full build, upload its packaged artifacts, and publish a prerelease.
Leave `release-tag` blank to use the built Helium version.

Linux, macOS, and Windows release builds run through staged reusable workflows
so Chromium compile state can be checkpointed between GitHub-hosted runner jobs
instead of relying on one six-hour job.

## Patch Flow

`patches/series` is the canonical overlay list. During platform preparation,
each listed patch is copied into the platform repo as `patches/helium/passwords/`
and appended to that platform's `patches/series`.

The wrapper also removes `helium/hop/disable-password-manager.patch` from the
cloned `helium-chromium` submodule before the platform build applies patches.

## License

All code, patches, modified portions of imported code or patches, and any other
content that is unique to this repo is licensed under GPL-3.0. See
[LICENSE](LICENSE). Imported content keeps its original license.
