# Arch Desktop Fixes

- [x] Fix Super/Command in both paths: Termux:X11 direct hardware input and Arch Desktop controller forwarding.
- [x] Make Ctrl/shortcut chaining reliable without needing to click the display first.
- [x] Make key repeat faster in X11 and in the Arch Desktop controller.
- [x] Stabilize mouse speed by avoiding repeated pointer transforms and pinning X11 acceleration.
- [x] Make the phone-screen trackpad faster for pointing, slower for natural scrolling.
- [x] Reopening Arch Desktop from home attaches to a running session and waits during hibernate/stop instead of starting a second session.
- [x] With no external monitor, Arch Desktop opens normal phone Termux:X11 with Termux's mouse helper and extra keyboard visible.
- [x] Install/load the current laptop Helium extension set and settings in chroot Helium.
- [x] Stop CookieCloud/CDP cookie sync from deleting or expiring cookies while browsing.
- [x] Stop repeated mirror/extend prompts by removing display-enable calls from attach/focus polling.
- [x] Prevent duplicate Arch Desktop resume requests from queueing and restarting the chroot.
- [ ] Deploy the latest keyboard/display-association and dark-mode scripts to the phone after ADB reconnects, then verify live state.

Verification snapshot:

- External display target detected as display 36 at 2560x1440, with Termux:X11 fullscreen on that display and the controller on display 0.
- Termux:X11 external prefs hide the mouse helper/extra keyboard, enable pointer capture, set custom resolution 2560x1440, and use pointer speed 145.
- `dumpsys input` showed Termux:X11 as the current pointer-capture window with `Pointer Capture: ABSOLUTE`.
- Magic Keyboard Command/Super now uses the root uinput remapper: it grabs the physical Magic Keyboard event device, republishes it as `Arch Magic Keyboard Remap`, and rewrites Linux keycodes 125/126 to `KEY_RIGHTALT` so Termux:X11 can map Android right-Alt to X11 Super/mod4.
- X11 maps left Option as `Alt_L`; keycode 108 plus 133/134/204/205/206/207 are all Super/mod4 for the Termux:X11 Command-key paths.
- Verified on the live phone before ADB dropped that the remapper process was running, Android registered the virtual `Arch Magic Keyboard Remap` input device, and synthetic input through the physical Magic Keyboard event device emitted `KEY_RIGHTALT` on the virtual device. Full XMonad hotkey verification still needs ADB reconnect.
- Arch Desktop controller stays visible on display 0 after attach and no longer runs root hibernate work from `onDestroy`.
- Cold external start after hibernate reached `session.state=running` in 7791 ms.
- Reopening Arch Desktop while the session was already running completed the attach path without starting a second session.
- Chroot Helium started with the migrated laptop extension directories plus the local CookieCloud, uBO, AI Overview blocker, blank new tab, pinned-tab, and tab-sync helpers.
- XMonad config is managed by `xmonad-desktop-config-root.sh`: single BSP layout, BSP control bindings, dark hotkey list wrapper, Dolphin dark wrapper, and KDE/Qt dark config for root plus `dhruv`.
