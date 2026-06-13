#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}
ARCHIVE=${1:-/data/local/tmp/helium-laptop-extensions.tar}
STAGING=/tmp/helium-laptop-extension-migration

[ -f "$ARCHIVE" ] || {
  echo "missing archive: $ARCHIVE" >&2
  exit 1
}

cp "$ARCHIVE" "$ROOT/tmp/helium-laptop-extensions.tar"

/system/bin/chroot "$ROOT" /usr/bin/env \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  sh -s <<'EOF'
set -eu

profile=/root/.config/helium-passwords/Default
staging=/tmp/helium-laptop-extension-migration
archive=/tmp/helium-laptop-extensions.tar
mkdir -p "$profile" /root/.local/share
rm -rf "$staging"
mkdir -p "$staging"
tar -xf "$archive" -C "$staging"

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

chown -R 0:0 /root/.config/helium-passwords /root/.local/share/browserpass /root/.local/share/helium-extensions 2>/dev/null || true
rm -rf "$staging"
EOF
