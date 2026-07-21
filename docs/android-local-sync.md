# Android Local Sync

This path handles phone-local cookie sync plus native password-manager sync
between Android Helium Sync and the Arch chroot browser.

Status: experimental. The current cookie bridge does not preserve Chromium
partition keys or distinguish an authoritative token source from replicas, and
the native password bridge exports before its first pull. Do not treat it as a
durable or conflict-safe sync system until HS-001 through HS-004 in
[`TODO.md`](../TODO.md) pass the gates in
[`docs/acceptance.md`](acceptance.md). Device-bound session credentials are not
portable cookie data and must be re-established on each device.

It runs all sync services on the phone:

- `helium-local-syncd` listens on `127.0.0.1:8088` inside the Arch chroot.
- `helium-syncd` listens on `127.0.0.1:44719` inside the Arch chroot for encrypted password/tabs/cookie records.
- `start-helium-local-sync` also bridges Android Helium Sync DevTools to `127.0.0.1:9222` with `socat`.
- CookieCloud-compatible endpoints are exposed at `/update` and `/get/:uuid`.
- `cdp-cookiecloud` bridges browsers with DevTools but no extension support, including Android Helium Sync.
- `cdp-cookiecloud daemon` runs a local Android-to-chroot-to-Android cookie
  cycle using the local CookieCloud client config; it does not handle passwords.
- `cdp-password-sync` bridges chroot Chromium's native password manager over
  DevTools. It is not a password extension.
- Chroot Helium Sync is launched with the official CookieCloud extension when a
  `helium` binary is installed. The wrapper falls back to `chromium` only for
  temporary testing.

## Install

Build and push from the laptop:

```sh
ADB=/path/to/adb scripts/android-local/install-phone-sync.sh
ADB=/path/to/adb CHROMIUM_ANDROID_PACKAGE=computer.helium.sync scripts/android-local/configure-android-chromium-sync.sh
```

The installer uses the CookieCloud extension tarball at:

```text
/tmp/cookiecloud-extension-chrome-mv3.tar.xz
```

If that file is missing, `install-phone-sync.sh` fetches the official
`easychen/CookieCloud` Chrome release asset and packs it into that path.

Install the chroot browser package after a Linux ARM64 Helium Sync artifact has
been built:

```sh
ADB=/path/to/adb scripts/android-local/install-chroot-helium.sh /path/to/helium-linux-arm64.tar.xz
```

The installer extracts the artifact to `/opt/helium-sync` inside the Arch chroot
and exposes `/usr/local/bin/helium`.

## Run In Chroot

From the Arch desktop:

```sh
chromium-helium-local
```

The installer places `start-helium-local-sync` in `/usr/local/bin` and also
places `chromium-helium-local` plus `start-helium-local-sync` in
`/root/.config/x11/bin` and `/home/dhruv/.config/x11/bin`; make sure the
matching user directory is in the desktop session `PATH`, or run the helper
from that directory directly.

The wrapper prefers `helium` and falls back to `chromium` only for temporary
testing. Override with `HELIUM_CHROOT_BROWSER=/path/to/browser`.

The wrapper starts `helium-local-syncd` and `helium-syncd` first, starts the
CDP password bridge by default for the chroot browser, starts
`cdp-cookiecloud daemon` when
`$HOME/.local/share/helium-local-sync/cookiecloud-client.json` exists, then
launches Helium Sync with:

- profile: `$HOME/.config/helium-passwords`
- CookieCloud extension: `$HOME/.local/share/cookiecloud-extension/chrome-mv3`
- Google AI Overview blocker extension:
  `$HOME/.local/share/google-ai-overview-blocker`

The chroot Google AI Overview blocker is a normal desktop Chromium extension.
The Android main browser uses the compiled
`0006-helium-sync-android-ai-overview-blocker.patch` Java hook instead, because
Android command-line extension content scripts are not reliable in this fork.

Configure CookieCloud in the extension UI or client config:

- endpoint: `http://127.0.0.1:8088`
- mode: `up` on the source browser, `down` on the destination browser
- uuid/password: same values on both sides

The installer also provides a no-dependency CDP bridge. It uses browser-level
CDP `Storage.getCookies` and `Storage.setCookies` when available so cookie sync
does not depend on a responsive page renderer target:

```sh
cdp-cookiecloud sync --android-cdp http://127.0.0.1:9222 --chroot-cdp http://127.0.0.1:9223 --server http://127.0.0.1:8088 --config-file "$HOME/.local/share/helium-local-sync/cookiecloud-client.json"
cdp-cookiecloud daemon --android-cdp http://127.0.0.1:9222 --chroot-cdp http://127.0.0.1:9223 --server http://127.0.0.1:8088 --config-file "$HOME/.local/share/helium-local-sync/cookiecloud-client.json"
```

For laptop or multi-browser runs, pass one or more CDP endpoints explicitly:

```sh
cdp-cookiecloud daemon --cdp-list http://127.0.0.1:9222,http://127.0.0.1:9223,http://127.0.0.1:9224 --server http://127.0.0.1:8088 --config-file "$HOME/.local/share/helium-local-sync/cookiecloud-client.json"
```

`upload` and `download` still exist for directed checks and accept
`--config-file` so the CookieCloud password does not need to appear on the
command line. Use `--include domain,domain` on upload when verifying one domain
so unrelated profile cookies are not written into the local CookieCloud record.

Use port `9222` for Android Helium Sync through the local `socat` bridge; use port `9223` for the chroot Helium Sync wrapper.

## Password Manager

This setup does not replace Chromium's native password manager and does not install a password-manager extension. CookieCloud is only for cookies. Chroot Helium Sync uses its normal profile password store at `$HOME/.config/helium-passwords`; Android Helium Sync uses the native Chromium profile store in `app_chrome/Default/Login Data`.

The Android fork forces Chromium's built-in encrypted `Login Data` backend for the profile password store instead of the Android Google Password Manager backend. The Android password-store replacement files live in `chromium/overlay/` and are copied only by the direct Android build path. `chromium/patches/0004-helium-sync-android-oscrypt-provider.patch` makes Android initialize the stable `v10` OSCrypt provider needed by that built-in database.

The native Chromium overlays in `chromium/overlay/components/helium_sync` and `chromium/overlay/chrome/browser/helium_sync` serialize profile password entries through Chromium's password-manager APIs and store them in the local encrypted `helium-syncd` record API. `chromium/patches/0002-helium-sync-profile-service.patch` wires the profile service into browser startup, and `chromium/patches/0003-helium-sync-android-profile-startup.patch` starts it for Android profiles. The service stays inactive unless it can read a local token file.

The password payload format is `helium-password-v1`, a small JSON record with
`url`, `signon_realm`, `username`, `password`, and `note`. Records are encrypted
at rest by `helium-syncd`. The chroot bridge uses `cdp-password-sync` to call
Chromium's native `chrome.passwordsPrivate` API inside
`chrome://password-manager`; it is not a password-manager extension. Android
uses the native C++ bridge.

Password sync is additive/update-only. Local deletion removes the local entry
from that profile but does not publish a tombstone or delete it elsewhere.

The chroot CDP bridge must follow `chrome.passwordsPrivate` semantics. When
multiple remote records map to what Chromium considers the same origin and
username, the bridge updates the existing native entry and marks the remote
record applied in its state file instead of trying to create an unsupported
duplicate row.

`HELIUM_CHROOT_CDP_PASSWORD_SYNC=auto` is the default. In auto mode the launcher
starts `cdp-password-sync` for the chroot browser. Set it to `false` only when
debugging a Helium build with a verified native C++ chroot password-sync bridge.

Manual chroot password sync commands:

```sh
cdp-password-sync once --cdp http://127.0.0.1:9223 --server http://127.0.0.1:44719 --token-file "$HOME/.local/share/helium-sync/token" --device helium-chroot
cdp-password-sync daemon --cdp http://127.0.0.1:9223 --server http://127.0.0.1:44719 --token-file "$HOME/.local/share/helium-sync/token" --device helium-chroot
```

Config lookup is profile-first:

- `<profile>/helium-sync/token`
- `<user-data-dir>/helium-sync/token`
- `$HOME/.local/share/helium-sync/token`
- Android app-data `helium-sync/token`

The chroot launcher mirrors `$HOME/.local/share/helium-sync/token` into `$HOME/.config/helium-passwords/Default/helium-sync/token` and writes `base_url` and `device_name` beside it before starting Chromium. The local daemon keeps its passphrase and bearer token in `$HOME/.local/share/helium-sync`.

The Android uBO installer is disabled by default because it writes
`--load-extension` command-line flags and depends on Chromium's experimental
desktop-Android extension mode. Do not use it for the daily phone browser.
Keep only `--remote-debugging-socket-name=chrome_devtools_remote` in
`/data/local/tmp/chrome-command-line` and `/data/local/chrome-command-line` so
the local CookieCloud bridge can still reach Android Helium Sync through
`socat`. The installed Android app's main AI Overview blocker is the compiled
Java hook.

Local Android Chromium resumes should keep Siso memory-bounded. The Android
build helper defaults `CHROMIUM_ANDROID_SISO_GOMEMLIMIT=1536MiB`; raise it only
after checking that `vmstat` is not showing sustained swap-out. On existing
Siso output dirs, `CHROMIUM_ANDROID_SISO_FLAGS="--batch=false"` may be tested
for local non-interactive resumes, but keep it only if it does not create
sustained swap-out.

The local phone APK build also sets `android_static_analysis = "off"`. That is
intentional for this laptop path: Android Error Prone validation can create a
multi-gigabyte `chrome_java__errorprone` Java process and push the machine into
swap. Re-enable static analysis only for deliberate CI/release validation.

`configure-android-chromium-sync.sh` copies the same bearer token into Android Helium Sync's app-private `helium-sync` directories and writes `base_url=http://127.0.0.1:44719` with `device_name=helium-android`. It also marks the Android Chromium first-run flow complete and sets `EulaAccepted` in `Local State`; without that, Android stays in `FirstRunActivity` and the DevTools socket needed by CookieCloud does not come up. Android startup may briefly return an empty native password read before the built-in store is ready; the bridge retries empty startup reads and also does a delayed post-apply export after importing remote records.
