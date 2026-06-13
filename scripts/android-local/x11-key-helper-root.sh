#!/usr/bin/env bash
set -euo pipefail

release_modifiers() {
  local key
  for key in Super_L Super_R Meta_L Meta_R Alt_L Alt_R Control_L Control_R Shift_L Shift_R ISO_Level3_Shift ISO_Level5_Shift; do
    xdotool keyup "$key" >/dev/null 2>&1 || true
  done
}

trap release_modifiers EXIT HUP INT TERM
release_modifiers

while read -r action key _; do
  if [ "$action" = releaseall ]; then
    release_modifiers
    continue
  fi

  case "$action" in
    key|keydown|keyup) ;;
    *) continue ;;
  esac

  case "$key" in
    ''|*[!A-Za-z0-9_+-]*)
      continue
      ;;
  esac

  xdotool "$action" "$key" >/dev/null 2>&1 || true
done
