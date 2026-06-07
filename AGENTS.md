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
  component and Android password-store overrides.
- `chromium/patches/` contains the patches actually injected into Helium
  platform repos. `0001-helium-sync-overlay-files.patch` is generated from
  `chromium/overlay/`; regenerate it whenever overlay files change. Android
  builds are branded as `Helium Sync` with package `computer.helium.sync`.
- `cmd/helium-syncd` runs the localhost encrypted record daemon.
- `cmd/helium-sync` initializes local secrets and provides test/push/pull
  commands.
- `cmd/helium-local-syncd` runs the phone-local CookieCloud-compatible API.
- `internal/syncstore` stores append-only encrypted records.
- `scripts/android-local` installs and configures the phone/chroot local sync
  pieces. The chroot launcher prefers a `helium` binary and only falls back to
  `chromium` for temporary testing. The CDP chroot bridge folds records that
  Chromium's native password API treats as the same origin and username.
- `scripts/chromium` contains Chromium/Android build helpers and direct patch
  application helpers.

## Patch Flow

`scripts/prepare-platform.sh` clones an official Helium platform repo, removes
Helium's upstream password-disable patch from `helium-chromium`, copies
password patches into `patches/helium/passwords/`, copies sync patches into
`patches/helium/sync/`, and appends both groups to the platform
`patches/series`.

Run this after changing patch injection:

```bash
bash scripts/ci-check-target.sh linux x86_64
```

Run Go checks after changing daemon or bridge tooling:

```bash
go test ./...
go build ./cmd/helium-sync ./cmd/helium-syncd ./cmd/helium-local-syncd
```
