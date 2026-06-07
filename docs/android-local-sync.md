# Android Local Sync

This path handles phone-local cookie sync plus native password-manager sync
between Android Chromium Sync and the Arch chroot browser.

It runs all sync services on the phone:

- `helium-local-syncd` listens on `127.0.0.1:8088` inside the Arch chroot.
- `helium-syncd` listens on `127.0.0.1:44719` inside the Arch chroot for encrypted password/tabs/cookie records.
- `start-helium-local-sync` also bridges Android Chromium Sync DevTools to `127.0.0.1:9222` with `socat`.
- CookieCloud-compatible endpoints are exposed at `/update` and `/get/:uuid`.
- `cdp-cookiecloud` bridges browsers with DevTools but no extension support, including Android Chromium Sync.
- `cdp-cookiecloud daemon` runs a local Android-to-chroot-to-Android cookie
  cycle using the local CookieCloud client config; it does not handle passwords.
- `cdp-password-sync` bridges chroot Chromium's native password manager over
  DevTools. It is not a password extension.
- Chroot Helium Sync is launched with the official CookieCloud extension.

## Install

Build and push from the laptop:

```sh
ADB=/path/to/adb scripts/android-local/install-phone-sync.sh
ADB=/path/to/adb scripts/android-local/configure-android-chromium-sync.sh
```

The installer uses the CookieCloud extension tarball at:

```text
/tmp/cookiecloud-extension-chrome-mv3.tar.xz
```

If that file is missing, `install-phone-sync.sh` fetches the official
`easychen/CookieCloud` Chrome release asset and packs it into that path.

## Run In Chroot

From the Arch desktop:

```sh
chromium-helium-local
```

The installer places `chromium-helium-local` and `start-helium-local-sync` in
`/root/.config/x11/bin`; make sure that directory is in the desktop session
`PATH`, or run `/root/.config/x11/bin/chromium-helium-local` directly.

The wrapper starts `helium-local-syncd`, `helium-syncd`, and
`cdp-password-sync` first, starts `cdp-cookiecloud daemon` when
`/root/.local/share/helium-local-sync/cookiecloud-client.json` exists, then
launches Helium Sync with:

- profile: `/root/.config/helium-sync`
- CookieCloud extension: `/root/.local/share/cookiecloud-extension/chrome-mv3`

Configure CookieCloud in the extension UI or client config:

- endpoint: `http://127.0.0.1:8088`
- mode: `up` on the source browser, `down` on the destination browser
- uuid/password: same values on both sides

The installer also provides a no-dependency CDP bridge:

```sh
cdp-cookiecloud sync --android-cdp http://127.0.0.1:9222 --chroot-cdp http://127.0.0.1:9223 --server http://127.0.0.1:8088 --config-file /root/.local/share/helium-local-sync/cookiecloud-client.json
cdp-cookiecloud daemon --android-cdp http://127.0.0.1:9222 --chroot-cdp http://127.0.0.1:9223 --server http://127.0.0.1:8088 --config-file /root/.local/share/helium-local-sync/cookiecloud-client.json
```

`upload` and `download` still exist for directed checks and accept
`--config-file` so the CookieCloud password does not need to appear on the
command line. Use `--include domain,domain` on upload when verifying one domain
so unrelated profile cookies are not written into the local CookieCloud record.

Use port `9222` for Android Chromium Sync through the local `socat` bridge; use port `9223` for the chroot Helium Sync wrapper.

## Password Manager

This setup does not replace Chromium's native password manager and does not install a password-manager extension. CookieCloud is only for cookies. Chroot Helium Sync uses its normal profile password store at `/root/.config/helium-sync`; Android Chromium Sync uses the native Chromium profile store in `app_chrome/Default/Login Data`.

The Android fork forces Chromium's built-in encrypted `Login Data` backend for the profile password store instead of the Android Google Password Manager backend. `chromium/patches/0004-helium-sync-android-oscrypt-provider.patch` makes Android initialize the stable `v10` OSCrypt provider needed by that built-in database.

The native Chromium overlays in `chromium/overlay/components/helium_sync` and `chromium/overlay/chrome/browser/helium_sync` serialize profile password entries through Chromium's password-manager APIs and store them in the local encrypted `helium-syncd` record API. `chromium/patches/0002-helium-sync-profile-service.patch` wires the profile service into browser startup, and `chromium/patches/0003-helium-sync-android-profile-startup.patch` starts it for Android profiles. The service stays inactive unless it can read a local token file.

The password payload format is `helium-password-v1`, a small JSON record with
`url`, `signon_realm`, `username`, `password`, and `note`. Records are encrypted
at rest by `helium-syncd`. The chroot side uses `cdp-password-sync` to call
`chrome.passwordsPrivate` inside `chrome://password-manager`; Android uses the
native C++ bridge.

Manual chroot password sync commands:

```sh
cdp-password-sync once --cdp http://127.0.0.1:9223 --server http://127.0.0.1:44719 --token-file /root/.local/share/helium-sync/token --device helium-chroot
cdp-password-sync daemon --cdp http://127.0.0.1:9223 --server http://127.0.0.1:44719 --token-file /root/.local/share/helium-sync/token --device helium-chroot
```

Config lookup is profile-first:

- `<profile>/helium-sync/token`
- `<user-data-dir>/helium-sync/token`
- `$HOME/.local/share/helium-sync/token`
- Android app-data `helium-sync/token`

The chroot launcher mirrors `/root/.local/share/helium-sync/token` into `/root/.config/helium-sync/Default/helium-sync/token` and writes `base_url` and `device_name` beside it before starting Chromium. The local daemon keeps its passphrase and bearer token in `/root/.local/share/helium-sync`.

`configure-android-chromium-sync.sh` copies the same bearer token into Android Chromium Sync's app-private `helium-sync` directories and writes `base_url=http://127.0.0.1:44719` with `device_name=helium-android`. Android startup may briefly return an empty native password read before the built-in store is ready; the bridge retries empty startup reads and also does a delayed post-apply export after importing remote records.
