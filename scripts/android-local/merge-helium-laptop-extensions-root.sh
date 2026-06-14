#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
ARCHIVE=${1:-/data/local/tmp/helium-laptop-extensions.tar}
STAGING=/tmp/helium-laptop-extension-migration
BLOCKED_EXTENSION_IDS=${HELIUM_BLOCKED_EXTENSION_IDS:-eakpippijmmohmdlpgcjnipolcgciaga}

[ -f "$ARCHIVE" ] || {
  echo "missing archive: $ARCHIVE" >&2
  exit 1
}

cp "$ARCHIVE" "$ROOT/tmp/helium-laptop-extensions.tar"

/system/bin/chroot "$ROOT" /usr/bin/env \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  HELIUM_BLOCKED_EXTENSION_IDS="$BLOCKED_EXTENSION_IDS" \
  sh -s <<'EOF'
set -eu

profile=/root/.config/helium-passwords/Default
staging=/tmp/helium-laptop-extension-migration
archive=/tmp/helium-laptop-extensions.tar
blocked_extension_ids=${HELIUM_BLOCKED_EXTENSION_IDS:-eakpippijmmohmdlpgcjnipolcgciaga}
mkdir -p "$profile" /root/.local/share
rm -rf "$staging"
mkdir -p "$staging"
tar -xf "$archive" -C "$staging"

remove_blocked_extensions() {
  prefs=$profile/Preferences
  for extension_id in $blocked_extension_ids; do
    rm -rf \
      "$profile/Extensions/$extension_id" \
      "$profile/Local Extension Settings/$extension_id" \
      "$profile/Sync Extension Settings/$extension_id" \
      "$profile/Managed Extension Settings/$extension_id" \
      "$profile/Extension Rules/$extension_id" \
      "$profile/Extension Scripts/$extension_id" \
      "$profile/IndexedDB/chrome-extension_${extension_id}_0.indexeddb.leveldb" \
      "$profile/IndexedDB/chrome-extension_${extension_id}_0.indexeddb.blob"
    if [ -f "$prefs" ] && command -v jq >/dev/null 2>&1; then
      jq --arg id "$extension_id" '
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
      ' "$prefs" >"$prefs.tmp" && mv "$prefs.tmp" "$prefs"
    fi
  done
  for base in /root/.local/share/helium-extensions /home/dhruv/.local/share/helium-extensions; do
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

for dir in \
  Extensions \
  "Local Extension Settings" \
  "Sync Extension Settings" \
  "Managed Extension Settings" \
  "Extension State" \
  "Extension Rules" \
  "Extension Scripts" \
  IndexedDB \
  "Local Storage"; do
  if [ -e "$staging/profile/Default/$dir" ]; then
    rsync -a "$staging/profile/Default/$dir" "$profile/"
  fi
done

if [ -d "$staging/root-home/.local/share/browserpass" ]; then
  mkdir -p /root/.local/share/browserpass
  rsync -a "$staging/root-home/.local/share/browserpass/" /root/.local/share/browserpass/
fi
if [ -d "$staging/root-home/.local/share/helium-extensions" ]; then
  mkdir -p /root/.local/share/helium-extensions
  rsync -a "$staging/root-home/.local/share/helium-extensions/" /root/.local/share/helium-extensions/
fi

if [ -d /home/dhruv ]; then
  mkdir -p /home/dhruv/.local/share
  [ ! -d /root/.local/share/browserpass ] || rsync -a /root/.local/share/browserpass /home/dhruv/.local/share/
  [ ! -d /root/.local/share/helium-extensions ] || rsync -a /root/.local/share/helium-extensions /home/dhruv/.local/share/
  chown -R 1000:1000 /home/dhruv/.local/share/browserpass /home/dhruv/.local/share/helium-extensions 2>/dev/null || true
fi

prefs="$profile/Preferences"
laptop="$staging/profile/Default/Preferences.laptop"
[ -f "$prefs" ] || printf '{}\n' >"$prefs"
if [ -f "$laptop" ]; then
  cp -p "$prefs" "$prefs.before-laptop-extension-merge.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  jq --slurpfile src "$laptop" '
    def rewrite_path:
      if type != "string" then .
      elif startswith("/home/dhruv/.local/share/browserpass/") then sub("^/home/dhruv"; "/root")
      elif startswith("/home/dhruv/.local/share/helium-extensions/") then sub("^/home/dhruv"; "/root")
      elif startswith("/home/dhruv/.local/opt/helium-app/opt/helium/resources/") then sub("^/home/dhruv/.local/opt/helium-app/opt/helium"; "/opt/helium-sync")
      else .
      end;
    .extensions = ((.extensions // {}) * ($src[0].extensions // {}))
    | if (.extensions.settings? // null) != null then
        .extensions.settings |= with_entries(
          .value.path = ((.value.path // "") | rewrite_path)
        )
      else .
      end
  ' "$prefs" >"$prefs.tmp"
  mv "$prefs.tmp" "$prefs"
fi

remove_blocked_extensions

chown -R 0:0 /root/.config/helium-passwords /root/.local/share/browserpass /root/.local/share/helium-extensions 2>/dev/null || true
rm -rf "$staging"
EOF
