#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
adb_bin=${ADB:-adb}
root=${ARCH_CHROOT:-/data/local/chroots/arch}
profile=${HELIUM_CHROOT_PROFILE:-/root/.config/helium-passwords}

usage() {
  cat >&2 <<'EOF'
usage:
  install-chroot-helium.sh install ARTIFACT ARTIFACT-RECEIPT PROFILE-BACKUP-CONFIG PROFILE-BACKUP-RECEIPT
  install-chroot-helium.sh rollback ARTIFACT-SHA256

The browser must be stopped.  Install requires build provenance and two
verified encrypted copies of the exact chroot profile.  Releases are retained
under /opt/helium-sync-releases; rollback only changes a symlink.
EOF
}

normalize_arch() {
  case "$1" in
    aarch64|arm64|*AArch64*) printf '%s\n' arm64 ;;
    x86_64|amd64|*X86-64*) printf '%s\n' x86_64 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

validate_root() {
  [[ "$root" =~ ^/data/local/chroots/[A-Za-z0-9._-]+$ ]] || {
    echo "unsafe ARCH_CHROOT path" >&2
    exit 64
  }
  [[ "$profile" =~ ^/[A-Za-z0-9._/-]+$ && "$profile" != *'/../'* ]] || {
    echo "unsafe HELIUM_CHROOT_PROFILE path" >&2
    exit 64
  }
}

rollback_release() {
  local release_id=$1
  [[ "$release_id" =~ ^[a-f0-9]{64}$ ]] || { echo "rollback release must be an artifact SHA-256" >&2; exit 64; }
  validate_root
  "$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
ROOT='"'"$root"'"'
RELEASE='"'"$release_id"'"'
test ! -e \"\$ROOT/opt/helium-sync\" -o -L \"\$ROOT/opt/helium-sync\"
test -x \"\$ROOT/opt/helium-sync-releases/\$RELEASE/helium\"
test -f \"\$ROOT/opt/helium-sync-releases/\$RELEASE/.helium-artifact-receipt.env\"
! /system/bin/chroot \"\$ROOT\" /usr/bin/pgrep -f \"(/opt/helium-sync|/opt/helium-sync-releases|/usr/local/bin/helium)\" >/dev/null
ln -s /opt/helium-sync-releases/\$RELEASE \"\$ROOT/opt/helium-sync.new.\$\$\"
mv -T \"\$ROOT/opt/helium-sync.new.\$\$\" \"\$ROOT/opt/helium-sync\"
/system/bin/chroot \"\$ROOT\" /usr/local/bin/helium --version
"'
  printf 'rollback=activated\nartifact_sha256=%s\n' "$release_id"
}

install_release() {
  local artifact=$1 artifact_receipt=$2 backup_config=$3 backup_receipt=$4
  local admission backup_admission artifact_sha sync_commit expected_tree_sha work_dir helium_member
  local normalized_member strip_components artifact_machine artifact_arch chroot_machine chroot_arch
  local tmp_name receipt_name

  validate_root
  command -v readelf >/dev/null || { echo "readelf is required" >&2; exit 1; }
  artifact=$(realpath -e -- "$artifact")
  artifact_receipt=$(realpath -e -- "$artifact_receipt")
  admission=$("$repo_root/scripts/deployment/verify-artifact-receipt.sh" \
    "$artifact" "$artifact_receipt" linux-arm64-chroot)
  artifact_sha=$(awk -F= '$1 == "artifact_sha256" {print $2}' <<<"$admission")
  sync_commit=$(awk -F= '$1 == "helium_sync_commit" {print $2}' <<<"$admission")
  git -C "$repo_root" cat-file -e "$sync_commit^{commit}"
  git -C "$repo_root" merge-base --is-ancestor "$sync_commit" HEAD || {
    echo "artifact source commit is not in this repository history" >&2
    exit 1
  }
  backup_admission=$("$repo_root/scripts/profile-backup/helium-profile-backup.sh" \
    verify-receipt "$backup_config" "$backup_receipt" "$profile")
  [[ "$(awk -F= '$1 == "profile_backup_admission" {print $2}' <<<"$backup_admission")" == verified ]] || exit 1
  expected_tree_sha=$(awk -F= '$1 == "source_tree_sha256" {print $2}' <<<"$backup_admission")
  [[ "$expected_tree_sha" =~ ^[a-f0-9]{64}$ ]] || { echo "backup admission omitted the source fingerprint" >&2; exit 1; }

  work_dir=$(mktemp -d)
  trap 'rm -rf -- "$work_dir"; "$adb_bin" shell "rm -f /data/local/tmp/${tmp_name:-missing} /data/local/tmp/${receipt_name:-missing}" >/dev/null 2>&1 || true' EXIT
  tar -tf "$artifact" >"$work_dir/members.txt"
  while IFS= read -r member; do
    case "$member" in /*|..|../*|*/../*|*/..) echo "unsafe artifact member: $member" >&2; exit 1 ;; esac
  done <"$work_dir/members.txt"
  helium_member=$(awk '$0 !~ /\/$/ && ($0 == "helium" || $0 == "./helium" || $0 ~ /\/helium$/) {print; exit}' "$work_dir/members.txt")
  [[ -n "$helium_member" ]] || { echo "artifact does not contain a helium executable" >&2; exit 1; }
  tar -xOf "$artifact" "$helium_member" >"$work_dir/helium"
  normalized_member=${helium_member#./}
  if [[ "$normalized_member" == helium ]]; then strip_components=0; else strip_components=$(awk -F/ '{print NF - 1}' <<<"$normalized_member"); fi
  artifact_machine=$(readelf -h "$work_dir/helium" | awk -F: '/Machine:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  artifact_arch=$(normalize_arch "$artifact_machine")
  chroot_machine=$("$adb_bin" shell 'su -c "chroot '"$root"' /usr/bin/uname -m"' | tr -d '\r')
  chroot_arch=$(normalize_arch "$chroot_machine")
  [[ "$artifact_arch" == "$chroot_arch" ]] || { echo "artifact architecture does not match chroot" >&2; exit 1; }

  tmp_name="helium-sync-$artifact_sha.tar.xz"
  receipt_name="helium-sync-$artifact_sha.receipt.env"
  "$adb_bin" push "$artifact" "/data/local/tmp/$tmp_name" >/dev/null
  "$adb_bin" push "$artifact_receipt" "/data/local/tmp/$receipt_name" >/dev/null
  "$adb_bin" shell '/debug_ramdisk/su -c "
set -eu
ROOT='"'"$root"'"'
SHA='"'"$artifact_sha"'"'
STRIP='"'"$strip_components"'"'
ARCHIVE=/data/local/tmp/'"'"$tmp_name"'"'
RECEIPT=/data/local/tmp/'"'"$receipt_name"'"'
PROFILE='"'"$profile"'"'
EXPECTED_TREE='"'"$expected_tree_sha"'"'
RELEASES=\"\$ROOT/opt/helium-sync-releases\"
RELEASE=\"\$RELEASES/\$SHA\"
STAGING=\"\$RELEASES/.incoming-\$SHA.\$\$\"
PRESERVED=\"\$RELEASES/preserved\"
mkdir -p \"\$RELEASES\" \"\$PRESERVED\" \"\$ROOT/tmp\" \"\$ROOT/usr/local/bin\"
! /system/bin/chroot \"\$ROOT\" /usr/bin/pgrep -f \"(/opt/helium-sync|/opt/helium-sync-releases|/usr/local/bin/helium)\" >/dev/null
ACTUAL_TREE=\$(/system/bin/chroot \"\$ROOT\" /usr/bin/tar --sort=name --format=posix --pax-option=delete=atime,delete=ctime --mtime=@0 --owner=0 --group=0 --numeric-owner -C \"\$PROFILE\" -cf - . | /system/bin/chroot \"\$ROOT\" /usr/bin/sha256sum | /system/bin/chroot \"\$ROOT\" /usr/bin/awk \"{print \\\$1}\")
test \"\$ACTUAL_TREE\" = \"\$EXPECTED_TREE\"
if [ ! -d \"\$RELEASE\" ]; then
  test ! -e \"\$STAGING\"
  mkdir \"\$STAGING\"
  cp \"\$ARCHIVE\" \"\$ROOT/tmp/\$SHA.tar.xz\"
  /system/bin/chroot \"\$ROOT\" /usr/bin/env PATH=/usr/bin:/bin /usr/bin/tar -xf \"/tmp/\$SHA.tar.xz\" -C \"/opt/helium-sync-releases/.incoming-\$SHA.\$\$\" --strip-components=\"\$STRIP\"
  rm -f \"\$ROOT/tmp/\$SHA.tar.xz\"
  test -x \"\$STAGING/helium\"
  test -x \"\$STAGING/helium_crashpad_handler\"
  test -f \"\$STAGING/icudtl.dat\"
  test -f \"\$STAGING/resources.pak\"
  cp \"\$RECEIPT\" \"\$STAGING/.helium-artifact-receipt.env\"
  chmod 0600 \"\$STAGING/.helium-artifact-receipt.env\"
  mv \"\$STAGING\" \"\$RELEASE\"
else
  test -x \"\$RELEASE/helium\"
  cmp \"\$RECEIPT\" \"\$RELEASE/.helium-artifact-receipt.env\"
fi
if [ -e \"\$ROOT/opt/helium-sync\" ] && [ ! -L \"\$ROOT/opt/helium-sync\" ]; then
  STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
  mv \"\$ROOT/opt/helium-sync\" \"\$PRESERVED/legacy-\$STAMP\"
fi
if [ -e \"\$ROOT/usr/local/bin/helium\" ] && [ ! -L \"\$ROOT/usr/local/bin/helium\" ]; then
  STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
  mv \"\$ROOT/usr/local/bin/helium\" \"\$PRESERVED/helium-launcher-\$STAMP\"
fi
ln -s /opt/helium-sync-releases/\$SHA \"\$ROOT/opt/helium-sync.new.\$\$\"
mv -T \"\$ROOT/opt/helium-sync.new.\$\$\" \"\$ROOT/opt/helium-sync\"
ln -s /opt/helium-sync/helium \"\$ROOT/usr/local/bin/helium.new.\$\$\"
mv -T \"\$ROOT/usr/local/bin/helium.new.\$\$\" \"\$ROOT/usr/local/bin/helium\"
/system/bin/chroot \"\$ROOT\" /usr/local/bin/helium --version
"'
  printf 'install=activated\nartifact_sha256=%s\nrelease=/opt/helium-sync-releases/%s\nprofile_backup_generation=%s\n' \
    "$artifact_sha" "$artifact_sha" "$(awk -F= '$1 == "generation" {print $2}' <<<"$backup_admission")"
}

case ${1:-} in
  install) [[ $# -eq 5 ]] || { usage; exit 64; }; install_release "$2" "$3" "$4" "$5" ;;
  rollback) [[ $# -eq 2 ]] || { usage; exit 64; }; rollback_release "$2" ;;
  *) usage; exit 64 ;;
esac
