# helium-sync

This repo is the private `oof-baroomf/helium-sync` fork. It is based on
`oof-baroomf/helium-passwords`, which is itself a Helium Browser fork that
restores Chromium's native password manager.

## Operating Rules

- Keep this repo based on `helium-passwords`; do not turn it back into a plain
  Chromium-only repo.
- Password sync must use Chromium's native password-manager APIs and the local
  encrypted daemon. Do not add a password-manager browser extension and do not
  copy raw profile databases.
- Password sync is additive/update-only. Do not propagate password deletions
  between devices unless this policy is explicitly changed.
- Cookie sync may use the CookieCloud-compatible local bridge for environments
  that cannot load a CookieCloud extension directly.
- Treat synced payloads as sensitive. Avoid logging decrypted cookies,
  passwords, tokens, passphrases, or full cookie/password payloads.
- Keep `README.md`, `docs/`, and this file current when integration paths or
  record schemas change.

## Repo Shape

- `patches/series` lists the password-manager restoration patches inherited
  from `helium-passwords`.
- `chromium/overlay/` is the source tree for the native Chromium sync
  component and Android password-store overrides. Desktop Linux/macOS/Windows
  builds must use the desktop-safe overlay copy path so Android password-store
  replacement files are not copied over upstream desktop Chromium files.
- `chromium/patches/` contains the Chromium sync patches. Desktop Helium
  platform repos receive only the desktop-safe patch subset: the filtered
  native sync overlay patch plus desktop profile service wiring. Android-only
  startup, OSCrypt, branding, and password-store override files stay on the
  direct Android build path. `0001-helium-sync-overlay-files.patch` is
  generated from `chromium/overlay/`; regenerate it whenever overlay files
  change. Android builds are branded as `Helium Sync` with package
  `computer.helium.sync`.
  `chromium/patches/0006-helium-sync-android-ai-overview-blocker.patch`
  blocks Google AI Overviews in the Android main browser with a small Java
  `ChromeActivity` hook; do not rely on Android command-line extension content
  scripts for that behavior. Keep that injected script cheap: do not use
  layout-forcing DOM reads such as `innerText` inside mutation-driven scans.
  Android extension/uBO experiments must not be used for the daily phone APK.
  Chromium marks desktop-Android extension support as experimental and unstable;
  the Android build helper rejects `CHROMIUM_ANDROID_DESKTOP_EXTENSIONS=true`.
  Use the chroot Helium browser for uBO/extension workflows. The Android main
  browser uses the Java AI Overview blocker and local sync bridge, not
  command-line extension content scripts.
- `cmd/helium-syncd` runs the localhost encrypted record daemon.
- `cmd/helium-sync` initializes local secrets and provides test/push/pull
  commands.
- `cmd/helium-local-syncd` runs the phone-local CookieCloud-compatible API.
- `internal/syncstore` stores append-only encrypted records.
- `scripts/android-local` installs and configures the phone/chroot local sync
  pieces. The installer places `start-helium-local-sync` in `/usr/local/bin`
  and the X11 helper path. `configure-android-chromium-sync.sh` also marks
  Android Chromium first-run complete so DevTools starts in the real browser
  activity. The chroot launcher prefers a `helium` binary and only falls back
  to `chromium` for temporary testing. Use
  `scripts/android-local/install-chroot-helium.sh` with a Linux ARM64 Helium
  Sync artifact to install `/usr/local/bin/helium` in the phone chroot. The
  launcher defaults to `$HOME/.config/helium-passwords`, starts the CDP
  password bridge by default for the chroot browser, and only disables it when
  `HELIUM_CHROOT_CDP_PASSWORD_SYNC=false` is set. The bridge uses Chromium's
  native `chrome.passwordsPrivate` API; it is not a password extension. The
  launcher removes stale Chromium singleton files only when their recorded PID
  is no longer running. The CDP chroot bridge folds records that Chromium's
  native password API treats as the same origin and username. The
  `cdp-cookiecloud` bridge uses browser-level `Storage.getCookies` and
  `Storage.setCookies` when CDP exposes a browser websocket, because chroot
  page targets can be missing or still starting. The installer places the
  CookieCloud extension and the Google AI Overview blocker under both
  `/root/.local/share` and
  `/home/dhruv/.local/share`; the launcher loads whichever copies live under
  the invoking user's `$HOME`. The chroot AI Overview blocker is a normal
  desktop Chromium extension loaded by that launcher.
- `scripts/chromium` contains Chromium/Android build helpers and direct patch
  application helpers.
- Android APKs intended for local phone use should be release-style,
  non-debuggable builds: keep `is_debug = false` and
  `dcheck_always_on = false`; do not set `is_desktop_android = true`.
  Default `is_official_build = false` for local laptop builds because Chromium's
  official Android path enables expensive optimized/LTO-style work and is too
  slow for iteration here. Use `CHROMIUM_ANDROID_OFFICIAL_BUILD=true` only for
  deliberate release/CI builds. Local phone builds must also keep
  `chrome_pgo_phase = 0` unless the matching Chromium/V8 PGO profiles have
  explicitly been fetched into the checkout. Keep `android_static_analysis =
  "off"` for local phone builds so Android Error Prone validation does not
  dominate RAM and swap during the main app build. The helper defaults
  `CHROMIUM_ANDROID_USE_SISO=auto`: preserve Siso for an existing Siso out dir,
  because Chromium requires `gn clean` before switching that out dir to Ninja;
  use Ninja for a fresh local out dir unless explicitly overridden. When Siso is
  active, keep `CHROMIUM_ANDROID_SISO_GOMEMLIMIT=1536MiB` unless a build monitor
  shows there is no swap-out pressure at a higher limit. For existing Siso out
  dirs, `CHROMIUM_ANDROID_SISO_FLAGS="--batch=false"` can be tested during
  local non-interactive resumes so Siso keeps its fast local path enabled, but
  revert it immediately if `vmstat` shows sustained swap-out.

## Patch Flow

`scripts/prepare-platform.sh` clones an official Helium platform repo, removes
Helium's upstream password-disable patch from `helium-chromium`, copies
password patches into `patches/helium/passwords/`, copies the desktop-safe sync
patch subset into `patches/helium/sync/`, and appends both groups to the
platform `patches/series`.

Run this after changing patch injection:

```bash
bash scripts/ci-check-target.sh linux x86_64
```

Run Go checks after changing daemon or bridge tooling:

```bash
go test ./...
go build ./cmd/helium-sync ./cmd/helium-syncd ./cmd/helium-local-syncd
```
