#!/usr/bin/env bash
set -euo pipefail

command -v xmodmap >/dev/null 2>&1 || exit 0

if command -v xset >/dev/null 2>&1; then
  xset r rate "${ARCH_X11_KEY_REPEAT_DELAY:-135}" "${ARCH_X11_KEY_REPEAT_RATE:-65}" >/dev/null 2>&1 || true
  xset m "${ARCH_X11_POINTER_ACCEL:-1}" "${ARCH_X11_POINTER_THRESHOLD:-0}" >/dev/null 2>&1 || true
fi

xmodmap -e 'clear mod1' >/dev/null 2>&1 || true
xmodmap -e 'clear mod4' >/dev/null 2>&1 || true

xmodmap -e 'keycode 64 = Alt_L Meta_L Alt_L Meta_L' >/dev/null 2>&1 || true
xmodmap -e 'keycode 108 = Super_R NoSymbol Super_R' >/dev/null 2>&1 || true

xmodmap -e 'keycode 133 = Super_L NoSymbol Super_L' >/dev/null 2>&1 || true
xmodmap -e 'keycode 134 = Super_R NoSymbol Super_R' >/dev/null 2>&1 || true
xmodmap -e 'keycode 204 = Super_L NoSymbol Super_L' >/dev/null 2>&1 || true
xmodmap -e 'keycode 205 = Super_R NoSymbol Super_R' >/dev/null 2>&1 || true
xmodmap -e 'keycode 206 = Super_L NoSymbol Super_L' >/dev/null 2>&1 || true
xmodmap -e 'keycode 207 = Super_R NoSymbol Super_R' >/dev/null 2>&1 || true

xmodmap -e 'add mod1 = Alt_L' >/dev/null 2>&1 || true
xmodmap -e 'add mod4 = Super_L Super_R' >/dev/null 2>&1 || true
