#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/android-local/install-chroot-helium.sh /path/to/helium-linux-arm64.tar.xz

Install a packaged Linux Helium Sync browser into the phone's Arch chroot and
expose it as /usr/local/bin/helium. The artifact must be built for the chroot
architecture.
EOF
}

adb_bin=${ADB:-adb}
root=${ARCH_CHROOT:-/data/local/chroots/arch}
artifact=${1:-${HELIUM_CHROOT_HELIUM_ARTIFACT:-}}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

normalize_arch() {
  case "$1" in
    aarch64|arm64|*AArch64*) printf '%s\n' arm64 ;;
    x86_64|amd64|*X86-64*) printf '%s\n' x86_64 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

if [ -z "$artifact" ]; then
  usage
  exit 2
fi

if [ ! -f "$artifact" ]; then
  echo "artifact not found: $artifact" >&2
  exit 1
fi

if ! command -v readelf >/dev/null 2>&1; then
  echo "readelf is required to verify the artifact architecture" >&2
  exit 1
fi

tar -tf "$artifact" >"$work_dir/members.txt"
if ! grep -qxE '(\./)?helium' "$work_dir/members.txt"; then
  echo "artifact does not contain a top-level helium executable: $artifact" >&2
  exit 1
fi

tar -xOf "$artifact" ./helium >"$work_dir/helium" 2>/dev/null ||
  tar -xOf "$artifact" helium >"$work_dir/helium"

artifact_machine=$(readelf -h "$work_dir/helium" |
  awk -F: '/Machine:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')
artifact_arch=$(normalize_arch "$artifact_machine")
chroot_machine=$("$adb_bin" shell 'su -c "chroot '"$root"' /usr/bin/uname -m"' |
  tr -d '\r')
chroot_arch=$(normalize_arch "$chroot_machine")

if [ "$artifact_arch" != "$chroot_arch" ]; then
  echo "artifact architecture $artifact_machine does not match chroot architecture $chroot_machine" >&2
  exit 1
fi

tmp_name=helium-sync-chroot.tar.xz
"$adb_bin" push "$artifact" "/data/local/tmp/$tmp_name" >/dev/null

"$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
ROOT='"$root"'
rm -rf \"\$ROOT/opt/helium-sync\"
mkdir -p \"\$ROOT/opt/helium-sync\" \"\$ROOT/tmp\" \"\$ROOT/usr/local/bin\"
cp /data/local/tmp/'"$tmp_name"' \"\$ROOT/tmp/'"$tmp_name"'\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/bin/tar -xf /tmp/'"$tmp_name"' -C /opt/helium-sync
rm -f \"\$ROOT/tmp/'"$tmp_name"'\"
chmod 0755 \"\$ROOT/opt/helium-sync/helium\"
cat > \"\$ROOT/usr/local/bin/helium\" <<'\''WRAPPER'\''
#!/usr/bin/env sh
exec /opt/helium-sync/helium \"\$@\"
WRAPPER
chmod 0755 \"\$ROOT/usr/local/bin/helium\"
/system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin /usr/local/bin/helium --version
"'
