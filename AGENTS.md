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
  Android extension/uBO experiments must use the explicit
  `CHROMIUM_ANDROID_DESKTOP_EXTENSIONS=true` build-helper path, which writes
  Chromium's `is_desktop_android = true` GN arg. Use
  `scripts/android-local/install-android-ublock.sh` for rooted runtime uBO
  testing; it verifies the pinned archive, adds the local Google AI Overview
  cosmetic filter to Helium's annoyances list, and writes Android command-line
  flags without dropping the DevTools socket flag needed by CookieCloud.
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
  launcher defaults to `/root/.config/helium-passwords`, uses native password
  sync for `helium`, and uses the CDP password bridge only for the temporary
  `chromium` fallback. The launcher removes stale Chromium singleton files only
  when their recorded PID is no longer running. The CDP chroot bridge folds
  records that Chromium's native password API treats as the same origin and
  username.
- `scripts/chromium` contains Chromium/Android build helpers and direct patch
  application helpers.

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
