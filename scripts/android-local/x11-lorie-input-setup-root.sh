#!/usr/bin/env bash
set -euo pipefail

command -v xmodmap >/dev/null 2>&1 || exit 0

xmodmap -e 'remove mod1 = Meta_L' >/dev/null 2>&1 || true
xmodmap -e 'keycode 205 = Super_L NoSymbol Super_L' >/dev/null 2>&1 || true
xmodmap -e 'add mod4 = Super_L Super_R' >/dev/null 2>&1 || true
