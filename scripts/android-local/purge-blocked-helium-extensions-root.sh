#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
BLOCKED_EXTENSION_IDS=${HELIUM_BLOCKED_EXTENSION_IDS:-eakpippijmmohmdlpgcjnipolcgciaga}
CHROOT_PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin

rewrite_prefs() {
  prefs=$1
  chroot_prefs=$2
  extension_id=$3
  [ -f "$prefs" ] || return 0
  cp -p "$prefs" "$prefs.before-blocked-extension-purge.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  if /system/bin/chroot "$ROOT" /usr/bin/env PATH="$CHROOT_PATH" jq --arg id "$extension_id" '
      del(.extensions.settings[$id])
      | del(.extensions.commands[$id])
      | del(.protection.macs.extensions.settings[$id])
      | if .extensions.pinned_extensions? then
          .extensions.pinned_extensions |= (
            if type == "array" then map(select(. != $id))
            elif type == "object" then del(.[$id])
            else .
            end
          )
        else .
        end
    ' "$chroot_prefs" >"$prefs.tmp"; then
    mv "$prefs.tmp" "$prefs"
  else
    rm -f "$prefs.tmp"
  fi
}

purge_profile() {
  profile=$1
  chroot_profile=$2
  [ -d "$profile" ] || return 0
  for extension_id in $BLOCKED_EXTENSION_IDS; do
    rm -rf \
      "$profile/Extensions/$extension_id" \
      "$profile/Local Extension Settings/$extension_id" \
      "$profile/Sync Extension Settings/$extension_id" \
      "$profile/Managed Extension Settings/$extension_id" \
      "$profile/Extension Rules/$extension_id" \
      "$profile/Extension Scripts/$extension_id" \
      "$profile/IndexedDB/chrome-extension_${extension_id}_0.indexeddb.leveldb" \
      "$profile/IndexedDB/chrome-extension_${extension_id}_0.indexeddb.blob"
    rewrite_prefs "$profile/Preferences" "$chroot_profile/Preferences" "$extension_id"
    rewrite_prefs "$profile/Secure Preferences" "$chroot_profile/Secure Preferences" "$extension_id"
  done
}

purge_unpacked_by_name() {
  for base in \
    "$ROOT/root/.local/share/helium-extensions" \
    "$ROOT/home/dhruv/.local/share/helium-extensions"; do
    [ -d "$base" ] || continue
    for extension_dir in "$base"/*; do
      [ -d "$extension_dir" ] || continue
      if [ -f "$extension_dir/manifest.json" ] &&
        grep -qi 'Pangram' "$extension_dir/manifest.json" "$extension_dir"/_locales/*/messages.json 2>/dev/null; then
        rm -rf "$extension_dir"
      fi
    done
  done
}

purge_profile "$ROOT/root/.config/helium-passwords/Default" "/root/.config/helium-passwords/Default"
purge_profile "$ROOT/home/dhruv/.config/helium-passwords/Default" "/home/dhruv/.config/helium-passwords/Default"
purge_unpacked_by_name
