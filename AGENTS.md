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
  that cannot load a CookieCloud extension directly. The CDP bridge is
  additive/update-only: uploads merge browser cookies into the existing remote
  payload and downloads skip expired records instead of propagating cookie
  deletions while the user is browsing.
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
  `cdp-password-sync` must create its password-manager CDP target in the
  background and must not navigate an existing user tab to
  `chrome://password-manager/passwords`; otherwise the daemon steals focus on
  every sync interval.
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
  the invoking user's `$HOME`. The installer also places the blank-new-tab and
  tab-pin helper extensions under both chroot users and installs
  `helium-prepare-profile` plus `helium-cleanup-startup-tabs` into each X11 bin
  directory. The launcher runs profile prep before Helium starts, sets Google
  search, requests Helium vertical layout through `helium.browser.layout = 2`,
  restores the last session, and loads the helper extensions. The chroot AI
  Overview blocker is a normal desktop Chromium extension loaded by that
  launcher. The launcher must not add already-installed profile extensions from
  `Default/Extensions` to `--load-extension`; doing so makes Chromium treat
  normal profile extensions like fresh unpacked installs and can reopen
  extension welcome pages on every Arch Desktop resume. The startup tab cleanup
  helper is intentionally startup-only and closes install/welcome/newtab pages
  during the first minute after launch without touching normal session tabs
  later. The launcher and laptop-extension migration both block Pangram
  (`eakpippijmmohmdlpgcjnipolcgciaga`) so an unpacked extension directory
  cannot make it reappear after uninstalling it in the browser UI. Use
  `scripts/android-local/purge-blocked-helium-extensions-root.sh` to remove
  blocked extension state from live chroot browser profiles.
- `scripts/android-local/arch-desktop-display-mode-root.sh` is installed at
  `/data/local/chroots/arch/arch-desktop-display-mode-root.sh`. It is the
  reversible external-display setup for Termux:X11: `apply` saves current
  Android display overrides, rotation, and Launcher3 prefs, uses Android
  display-manager output for a reported external display's resolution, and
  enables desktop/freeform hosting for Termux:X11 on the external display.
  The HDMI mirror approach leaves a centered sub-rectangle on the OnePlus
  13/crDroid path, so the default target is `extended`, not `mirror`. Do not set
  global `policy_control` for this flow; Termux:X11 fullscreen preference is
  the display-specific path, and global immersive state can leak back onto the
  phone launcher. `reset` restores saved display size/density/rotation, clears
  Arch Desktop's global desktop/freeform and immersive flags, and restores the
  saved Launcher3 prefs file if Android rewrote it. If Android only reports the
  built-in screen, it resets Android `wm size`/`wm density` to native and does
  not set immersive policy. If `cmd display get-displays` hides a connected but
  disabled external display, it may parse the disabled external logical display
  from `dumpsys display` so the target env does not fall back to phone mode
  while SystemUI/thermal policy is still deciding whether the display can be
  enabled. Do not use DRM/sysfs connector status as an external-display
  fallback on the OnePlus 13; it can report false positives such as `5120x2560`
  and corrupt Launcher3's layout scaling.
  Termux:X11's `exact` resolution preference only accepts a fixed preset list
  and rejects common monitor modes like `2560x1440`; startup must use custom
  resolution mode for the detected external resolution.
  Display apply may make a bounded `cmd display enable-display`/`power-reset`
  attempt and tap a visible SystemUI "Mirror display" sheet, but should not run
  a tight enable loop. The OS-wide mirror-confirmation fix lives in
  `scripts/android-local/android-connected-display-auto-enable-root.sh`, which
  the boot hook starts as
  `/data/local/chroots/arch/android-connected-display-auto-enable-root.sh`. It
  runs the `connected-display-auto-enable.jar` app_process helper, listens for
  Android's private display-connection event, and also uses a 1000 ms
  DisplayManagerGlobal binder poll because this OnePlus/crDroid path can churn
  pending external display ids without delivering a listener callback. It
  enables connected external displays through the same framework path as
  SystemUI's "Mirror display" button. Keep Arch Desktop display scripts limited
  to Android-reported display-manager ids plus `am start --display <external-id>`.
  The launcher also keeps Termux:X11's mouse helper and extra key bar disabled
  (`showMouseHelper=false`, `showAdditionalKbd=false`,
  `additionalKbdVisible=false`) so the external monitor shows only the chroot
  desktop. Phone UI preferences live in
  `scripts/android-local/android-ui-preferences-root.sh`; the installer deploys
  it to `/data/local/chroots/arch/android-ui-preferences-root.sh` and wires a
  `/data/adb/service.d/99-helium-phone-ui.sh` boot hook. It hides left-side app
  notification icons from the status bar while leaving notifications in the
  shade, keeps Termux:X11's own notification permission denied so its icon does
  not reappear, and starts the connected-display auto-enable service so the
  SystemUI "Mirror to external display?" prompt is handled OS-wide instead of
  inside Arch Desktop.
  `fingerprint` prints the target source/display/size/density without changing
  Android state, and `target` prints the corresponding target env. The current
  known-good Launcher3 backup is
  `/sdcard/Download/launcher3-home-backup-20260612-202958.tar.gz` on the phone
  and `/home/dhruv/phone-backups/launcher3-20260612-202958` on this computer;
  `/home/dhruv/phone-backups/launcher3-latest` points at it.
  `scripts/android-local/termux-x11-session-focus-root.sh` owns the
  Termux:X11 activity/prefs handoff. In external extended mode it hides the
  Termux mouse helper and extra key bar, enables pointer capture, uses custom
  resolution from the display target, and launches Termux:X11 on the external
  display. In phone-only mode it disables pointer capture and shows the normal
  Termux:X11 mouse helper/extra keyboard. Keep
  `hardwareKbdScancodesWorkaround=false` by default so Termux:X11 uses Android
  keycodes from the uinput Magic Keyboard remapper and the compatibility
  keylayout fallback, rather than bypassing them with raw scancodes.
  The focus script also kills stale raw pointer forwarders unless
  `ARCH_X11_RAW_POINTER=1`, because double injection causes random pointer
  speed changes. Do not send synthetic pointer-capture taps before the X server
  socket exists; doing so can leave Termux:X11 in an Android input-dispatch ANR.
  The focus helper waits for `/data/local/chroots/arch/tmp/.X11-unix/X1` before
  priming pointer capture.
  `scripts/android-local/arch-desktop-display-watch-root.sh` polls that
  fingerprint while Arch Desktop is running. When a monitor is plugged or
  unplugged after startup, it reapplies display mode and restarts the X11 layer
  so Termux:X11 reads the new resolution. The resume wiring starts both the
  session watcher and display watcher with `nohup`; otherwise manual root/ADB
  launch paths can leave watchers tied to their parent shell. Keep the display
  watcher poll interval conservative; `cmd display get-displays` can take
  several seconds on the phone, so the default interval is 30 seconds. On
  watcher startup and unchanged polls, it also compares the live fingerprint
  with `/root/.local/state/x11/android-display-target.env` and reapplies
  display mode if that env file is stale; otherwise Termux:X11 can fall back to
  phone-mode prefs and show its mouse helper/extra keyboard on the desktop.
  `scripts/android-local/arch-desktop-session-watch-root.sh` is installed as
  `/data/local/chroots/arch/arch-desktop-session-watch.sh`; it must detect
  Termux:X11 visibility across all Android displays, not just phone-screen
  focus, because the phone can be used as a trackpad while Termux:X11 remains
  resumed on the external monitor.
  `scripts/android-local/wire-arch-desktop-display-mode-root.sh` idempotently
  wires `apply` plus the display watcher into `arch-desktop-resume-root.sh` and
  watcher shutdown plus `reset` into `arch-desktop-hibernate-root.sh`.
  `scripts/android-local/arch-desktop-resume-root.sh` and
  `scripts/android-local/arch-desktop-hibernate-root.sh` are now canonical.
  Resume skips `stop-arch-x11-root.sh` when there are no Arch Desktop/X11
  processes or X socket, because cold start must not pay the stop script's
  grace sleep. Resume starts Termux:X11 from the Arch Desktop path itself,
  which is still user-initiated and avoids waiting for the controller app to
  open it after the root script returns.
  `scripts/android-local/input-display-assoc-root.sh` uses the tiny
  `android/input-display-assoc` `app_process` helper to call Android's runtime
  input/display association APIs. Resume and attach apply it asynchronously
  after display detection so cold start is not blocked by Android service
  calls; `start-arch-xmonad-root.sh` reapplies it after starting the Magic
  Keyboard remapper so the virtual keyboard descriptor is also tied to the
  external display. Stop and hibernate clear the associations. A healthy
  external-display session should show the external mouse/keyboard in
  `dumpsys input` with
  `AssociatedDisplayPort` set to the monitor port and
  `AssociatedDisplayUniqueIdByDescriptor` set to the monitor `local:...` unique
  id.
- `scripts/android-local/start-arch-xmonad-root.sh` and
  `scripts/android-local/stop-arch-x11-root.sh` are also installed by
  `install-phone-sync.sh`. Startup reads
  `/root/.local/state/x11/android-display-target.env` before launching
  Termux:X11. The default external-display mode is `extended`, so startup
  enables Android desktop/freeform globals and launches Termux:X11 on the
  detected external display. Startup and
  stop both lazily unmount `/data/local/chroots/arch/tmp/.X11-unix` before
  removing it because that socket path may be a live mount. The old Jelly web
  trackpad relay is off by default; only enable it deliberately with
  `ARCH_X11_WEB_TRACKPAD=1` for extended-display experiments. Pointer speed is
  controlled by `ARCH_X11_POINTER_SPEED` and defaults to `145`; the controller
  app handles its own phone-trackpad movement separately. X11 key repeat is
  set by `x11-lorie-input-setup` and defaults to delay `135` / rate `65`.
  Magic Keyboard Command/Super is handled by
  `cmd/android-magic-keyboard-remap` plus
  `scripts/android-local/android-magic-keyboard-remap-root.sh`: the root helper
  grabs the physical Magic Keyboard event device, republishes it through
  `/dev/uinput`, and rewrites Linux keycodes `125`/`126` to `KEY_RIGHTALT`.
  Termux:X11 then sees Android right-Alt, and X11 maps that keycode to
  Super/mod4. This avoids Android 16/crDroid intercepting Meta before it reaches
  X11. Keep `fix-magic-keyboard-layout-root.sh` as a compatibility fallback,
  but do not rely on it as the primary fix.
  The same setup keeps left Option as X keycode `64` / `Alt_L`, but maps X
  keycode `108` plus `133`, `134`, and `204` through `207` to Super/mod4; this
  preserves the observed Termux:X11/Lorie Command-key paths.
  Startup reapplies that X11 input setup after short delays because Termux:X11
  can reset key repeat and modifier maps while external devices finish
  enumerating.
  The canonical phone XMonad config and hotkey documentation are installed by
  `scripts/android-local/xmonad-desktop-config-root.sh`; it keeps BSP as the
  only layout, adds the documented BSP controls, and writes dark wrappers for
  Dolphin and the hotkey list under `.config/x11/bin`. It also writes
  `/root/.config/xmonad/build` so `xmonad --recompile` uses the chroot's
  ghcup/cabal GHC path and `/tmp`, avoiding Android `TMPDIR` leakage. Terminals
  launch through `.config/x11/bin/x11-zutty`, which must remain Zutty-only. Use
  Zutty's filename-prefix font lookup, not a fontconfig family string: the
  configured Iosevka font name is `Iosevka-Regular` from the upstream
  `ttc-iosevka` package under `/usr/share/fonts`. The Nerd-patched Iosevka
  TTFs load in Zutty but render blank glyphs on this Termux:X11 stack; do not
  switch back to them without a pixel screenshot proving they render. External
  X11 DPI should default to 96, matching normal desktop scale on the 2560x1440
  Acer display more closely than the previous oversized 120 DPI. Terminal color
  repair should use tmux `window-style`/`window-active-style`; tmux 3.6b rejects
  the old `default-style` option. It must not write a replacement Starship
  prompt; copy the user's real Starship config instead.
  If Termux:X11 is closed, the display watcher must hibernate instead of
  reopening it. XMonad
  startup uses the cached compiled binary unless
  `/root/.config/xmonad/xmonad.hs` is newer or `ARCH_X11_RECOMPILE=1` is set;
  do not recompile on every cold start.
  Do not start Termux:X11 with `--activity-no-user-action`; on the OnePlus
  13/crDroid external-display path that leaves the external window
  `NOT_FOCUSABLE`, so hardware mouse/keyboard events never reach it. After
  setting Termux:X11 preferences, startup primes pointer capture only after the
  X socket exists so Android grants Termux:X11 pointer capture without sending
  MotionEvents to an unready activity.
  Verify with `dumpsys input`: `FocusedWindows` should list
  `com.termux.x11/.MainActivity` on the external display and `Pointer Capture`
  should be `ABSOLUTE` with Termux:X11 as the current capture window.
  `scripts/android-local/phone-thermal-guard-root.sh` is the phone-level
  thermal guard deployed to `/data/local/helium-phone-thermal-guard-root.sh`.
  The old
  `/data/local/chroots/arch/arch-desktop-thermal-guard-root.sh` path is only a
  compatibility wrapper. The boot hook starts the phone-level guard before the
  connected-display auto-enable helper, and Arch Desktop resume starts it
  idempotently. It saves original CPU/devfreq max frequencies under
  `/data/local/helium-phone-thermal-guard`, applies conservative caps
  immediately, and tightens them before skin thermal status reaches critical so
  Android does not block external display hosting. Do not use
  `cmd thermalservice override-status` as a fix; that hides the framework state
  instead of reducing heat. By default hibernate leaves this guard running
  because the user prefers global throttling over losing external display. Set
  `ARCH_DESKTOP_THERMAL_GUARD_ALWAYS=0` only if hibernate should restore the
  original max frequencies.
- `android/arch-desktop-controller` is the phone-side controller app installed
  as `net.dhruv.archdesktop` / "Arch Desktop". It runs
  `/data/local/chroots/arch/arch-desktop-resume-root.sh` for cold starts and
  `/data/local/chroots/arch/arch-desktop-attach-root.sh` when the X11/chroot
  session is already running. In external-display mode it stays open as the
  phone trackpad/control surface; in phone-only mode it backgrounds itself so
  normal Termux:X11 mouse helper and extra keyboard controls remain available.
  In external-display mode, closing or backgrounding the Arch Desktop
  controller app must request hibernate so X11/browser/watchers disappear
  without needing the explicit Hibernate button. Back and the Hibernate button
  still run `/data/local/chroots/arch/arch-desktop-hibernate-root.sh`. Do not
  start root hibernate work from raw `onDestroy`; Android can destroy or cache
  the activity while binder transactions are restricted, and doing root work
  there can get the controller killed for excessive binder traffic. `onStop` is
  allowed to request hibernate only in external/trackpad mode. Do not call
  `startActivity()` for `com.termux.x11` from this
  app; the root resume script starts Termux:X11 with
  `am start --display <external-id>`, and a normal app-level launch moves
  Termux:X11 back onto the phone display, causing the external monitor to show
  a scaled mirror. The controller sends pointer events by keeping one root
  `x11-pointer-helper` process open and writing commands to its stdin. Hardware
  keyboard events go through `/root/.local/bin/x11-key-helper`, a tiny stdin
  wrapper around `xdotool key/key{down,up}`. Do not route native controller
  input through the old HTTP trackpad server, because Android app UIDs on this
  ROM cannot reach the root/chroot loopback listener.
  The old Jelly/web trackpad relay remains off by default; only enable it
  deliberately with `ARCH_X11_WEB_TRACKPAD=1`. Build the controller with
  `scripts/android-local/build-arch-desktop-controller.sh`; the private signing
  key stays outside the repo at
  `/home/dhruv/.local/state/arch-desktop-controller/debug.keystore`.
  Termux:X11 is still the external-display renderer, but launch it with
  `--activity-exclude-from-recents` from root scripts and never launch it from
  the controller app. The display allow flags
  `force_desktop_mode_on_external_displays` and `force_allow_on_external` are
  persistent phone preferences in `android-ui-preferences-root.sh`; hibernate
  only resets Arch-session freeform/windowing keys.
  Running-session detection must use the real Termux:X11 process/socket, not
  only `session.state`, because a stale `resuming` state can otherwise queue
  repeated full restarts. Resume and attach return exit `75` while the session
  is hibernating/stopping or the controller lock is busy, and the controller
  retries instead of queueing another full start.
- Arch Desktop startup also keeps Android Helium Sync
  (`computer.helium.sync`) out of inactive/idle background states and sticky
  unfreezes the running native browser process when present. CookieCloud uses
  that app's DevTools socket through the local `socat` bridge on `127.0.0.1:9222`,
  and Android can otherwise freeze the native browser as soon as Termux:X11 is
  foregrounded.
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
