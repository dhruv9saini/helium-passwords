# helium-sync

Private fork-of-a-fork for Helium Browser.

Base lineage:

1. [`imputnet/helium`](https://github.com/imputnet/helium) removes Google
   services, browser sync, and the built-in Chromium password manager.
2. [`oof-baroomf/helium-passwords`](https://github.com/oof-baroomf/helium-passwords)
   restores the native Chromium password manager.
3. `oof-baroomf/helium-sync` adds local password-manager sync and cookie sync on
   top of that restored-password Helium fork.

## What This Repo Adds

- Native password-manager restoration patches from `helium-passwords`.
- A local encrypted record daemon, `helium-syncd`, for browser data.
- A Chromium-side `helium_sync` component that observes Chromium's native
  password store, serializes passwords through browser APIs, and syncs through
  the local daemon.
- A CookieCloud-compatible local cookie bridge for browsers that can expose
  DevTools Protocol but cannot load the CookieCloud browser extension directly.
- Android-local helper scripts for sharing the same daemon/token between the
  Android browser process and the Arch chroot browser environment.

Passwords must remain in Chromium's native password manager. Do not use a
password-sync extension and do not copy raw profile databases.

## Targets

The desktop wrapper supports the official Helium platform repositories:

| OS | Architectures |
| --- | --- |
| Linux | `x86_64`, `arm64` |
| macOS | `x86_64`, `arm64` |
| Windows | `x86_64`, `arm64` |

Android is handled separately under `scripts/chromium/build-android-ci.sh` until
a full Android Helium platform repository exists.

## Local Build

Desktop builds must run on the matching host OS. Chromium builds are large, so
expect a long run and significant disk usage.

```bash
bash scripts/build.sh linux x86_64
bash scripts/build.sh linux arm64
bash scripts/build.sh macos x86_64
bash scripts/build.sh macos arm64
bash scripts/build.sh windows x86_64
bash scripts/build.sh windows arm64
```

The wrapper clones platform repos under `build/platforms/` by default. Override
repo URLs, clone ref, or the work directory in `helium-sync.conf` or by
exporting the same variables before running a script.

Go checks for the local daemon:

```bash
go test ./...
go build ./cmd/helium-sync ./cmd/helium-syncd ./cmd/helium-local-syncd
```

## Patch Flow

`patches/series` is the canonical password-manager restoration list. During
platform preparation, each listed patch is copied into the platform repo as
`patches/helium/passwords/` and appended to that platform's `patches/series`.

`chromium/patches/*.patch` is the canonical sync integration list. During
desktop platform preparation, only the desktop-safe subset is copied into
`patches/helium/sync/` and appended after the password patches. Android-only
startup, OSCrypt, branding, and password-store replacement files stay on the
direct Android Chromium build path.

The first sync patch is generated from `chromium/overlay/` so the full native
sync component can be applied by Helium platform patch tooling. Desktop
platform preparation filters the Android password-store replacement file diffs
out of that patch because current desktop Chromium owns those paths already.
Keep the overlay and generated patch in sync when editing Chromium-side files.

The wrapper also removes `helium/hop/disable-password-manager.patch` from the
cloned `helium-chromium` submodule before platform builds apply patches.

## Android

The current Android path uses Chromium Android source plus this repo's sync
patches, Android built-in password-store restoration, and local daemon/token
configuration. `chromium/patches/0005-helium-sync-android-branding.patch`
brands the APK as `Helium Sync` and changes the Android package to
`computer.helium.sync`.

Phone APKs must use the normal Android build path, not Chromium's experimental
desktop-Android extension path. `scripts/chromium/build-android-ci.sh` rejects
`CHROMIUM_ANDROID_DESKTOP_EXTENSIONS=true` because it writes
`is_desktop_android = true`, which Chromium documents as unstable prototype
support. The same helper builds local phone APKs as release-style non-debug
builds by default: `is_debug = false`, `dcheck_always_on = false`, and
`is_official_build = false`. This keeps renderer DCHECKs off without paying the
hours-long local cost of Chromium's official optimized Android build path. Set
`CHROMIUM_ANDROID_OFFICIAL_BUILD=true` only for deliberate release/CI builds.
The helper also pins local phone builds to `chrome_pgo_phase = 0`, so they do
not require Chromium/V8 PGO profiles that are absent from a small local
checkout, and sets `android_static_analysis = "off"` so local phone APK builds
do not run Android Error Prone validation during the main app build. It also
defaults `CHROMIUM_ANDROID_USE_SISO=auto`: existing Siso out
dirs continue using Siso, because Chromium requires `gn clean` before switching
that same out dir to Ninja, while fresh local out dirs use Ninja unless
overridden. Use the chroot Helium browser for uBO and other extension workflows.
When Siso is used locally, the helper defaults
`CHROMIUM_ANDROID_SISO_GOMEMLIMIT=1536MiB`; this keeps Siso from pushing the
laptop into sustained swap while still allowing multiple compiler jobs. Override
that value only after watching `vmstat` for swap-out pressure. Existing Siso
output dirs may also set `CHROMIUM_ANDROID_SISO_FLAGS="--batch=false"` to keep
Siso's fast local path enabled in non-interactive resumes, but only keep that
setting if `vmstat` shows no sustained swap-out.

Google AI Overview blocking for the Android main browser is built into the
Android fork by `chromium/patches/0006-helium-sync-android-ai-overview-blocker.patch`.
It injects a small Java-owned isolated-world script on normal Google Search
pages, so it does not use `udm=14` and does not remove other Google widgets.

For isolated runtime uBO debugging on a rooted phone,
`scripts/android-local/install-android-ublock.sh` can still stage the pinned
uBO archive and write `--load-extension` command-line flags, but it refuses to
run unless `HELIUM_ANDROID_UBLOCK_UNSTABLE_EXPERIMENT=true` is set. Do not use
that path for the daily phone browser.
Override them with `HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS`, point
`HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS_FILE` at a newline-delimited filter
file, or set `HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS` empty to skip them.
`HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTER` remains supported for a single
legacy override.

See [docs/android-local-sync.md](docs/android-local-sync.md) for the current
phone/chroot bridge details.

The chroot should run a Linux ARM64 Helium Sync package when one is available.
Install it with:

```bash
ADB=/path/to/adb scripts/android-local/install-chroot-helium.sh /path/to/helium-linux-arm64.tar.xz
```

The existing Chromium fallback is only for temporary bridge testing and should
not be treated as the completed chroot browser install.

## License

All code, patches, modified portions of imported code or patches, and any other
content that is unique to this repo is licensed under GPL-3.0. See
[LICENSE](LICENSE). Imported content keeps its original license.
