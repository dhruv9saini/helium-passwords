#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "$repo_root/.deployment-foundations.XXXXXX")
tmp_destination=$(mktemp -d "${TMPDIR:-/tmp}/helium-deploy-backup-a.XXXXXX")
shm_destination=$(mktemp -d /dev/shm/helium-deploy-backup-b.XXXXXX)
cleanup() { find "$test_root" "$tmp_destination" "$shm_destination" -depth -delete; }
trap cleanup EXIT
mkdir -p "$test_root/bin" "$test_root/home/.config/net.imput.helium/Default" \
  "$test_root/artifact/helium-sync-linux-x86_64/runtime"
printf 'SYNTHETIC-SSH-PRIVATE-KEY\n' >"$test_root/ssh-identity"
printf 'fixture-peer ssh-ed25519 SYNTHETIC\n' >"$test_root/known-hosts"
chmod 600 "$test_root/ssh-identity" "$test_root/known-hosts"

make_backup_receipt() {
  local source_path=$1 config=$2 generation=$3 profile_id=$4
  local archive=$test_root/archive-$profile_id archive_sha archive_size
  local topology_sha path_sha archive_root dest ns receipt tree_sha
  local fingerprint_kind
  printf 'synthetic archived profile %s\n' "$profile_id" >"$archive"
  archive_sha=$(sha256sum "$archive" | awk '{print $1}')
  archive_size=$(stat -c %s "$archive")
  topology_sha=$(
    printf '%s\n' \
      "nas-copy|nas|local|$(uname -n | cut -d. -f1)|$tmp_destination" \
      'fixture-peer-copy|device|ssh|fixture-peer|/synthetic/deploy-peer' |
      sort | sha256sum | awk '{print $1}'
  )
  path_sha=$(printf %s "$source_path" | sha256sum | awk '{print $1}')
  archive_root=${source_path##*/}
  if [[ "$profile_id" == android && -f "$test_root/android-profile.tar" ]]; then
    tree_sha=$(sha256sum "$test_root/android-profile.tar" | awk '{print $1}')
    fingerprint_kind='tar-stream-v1'
  elif [[ -d "$source_path" ]]; then
    tree_sha=$(tar --sort=name --format=posix \
      --pax-option=delete=atime,delete=ctime --mtime=@0 \
      --owner=0 --group=0 --numeric-owner -C "$source_path" -cf - . | \
      sha256sum | awk '{print $1}')
    fingerprint_kind='normalized-tree-v1'
  else
    tree_sha=$(printf 'synthetic-tree-%s' "$profile_id" | sha256sum | awk '{print $1}')
    fingerprint_kind='normalized-tree-v1'
  fi
  cat >"$config" <<EOF
version=3
source_device=fixture
profile_id=$profile_id
source_path=$source_path
ssh_user=d
ssh_identity=$test_root/ssh-identity
ssh_known_hosts=$test_root/known-hosts
retention_keep=2
destination_reserve_bytes=1
destination=nas-copy|nas|local|$(uname -n | cut -d. -f1)|-|$tmp_destination
destination=fixture-peer-copy|device|ssh|fixture-peer|fixture-peer|/synthetic/deploy-peer
EOF
  chmod 600 "$config"
  for dest in "$tmp_destination" "$shm_destination"; do
    ns=$dest/fixture/$profile_id/generations/$generation
    mkdir -p "$ns"
    cp "$archive" "$ns/profile.tar.zst"
    receipt=$ns/receipt.env
    cat >"$receipt" <<EOF
schema_version=3
source_device=fixture
profile_id=$profile_id
profile_path_sha256=$path_sha
source_tree_sha256=$tree_sha
source_fingerprint_kind=$fingerprint_kind
archive_root=$archive_root
generation=$generation
archive_sha256=$archive_sha
archive_size=$archive_size
source_bytes=123
topology_sha256=$topology_sha
created_at=2026-07-22T12:00:00Z
EOF
    chmod 600 "$receipt" "$ns/profile.tar.zst"
  done
  printf '%s\n' "$tmp_destination/fixture/$profile_id/generations/$generation/receipt.env"
}

commit=0123456789abcdef0123456789abcdef01234567
cat >"$test_root/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *'rev-parse HEAD'*) echo $commit ;;
  *) exit 0 ;;
esac
EOF
cat >"$test_root/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
done
cat >"$output" <<'INNER'
#!/usr/bin/env sh
exit 0
INNER
chmod 755 "$output"
EOF
cat >"$test_root/bin/adb" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>'$test_root/adb.log'
if [[ \${1:-} == shell ]]; then
  case \${2:-} in
    *'dumpsys package'*) echo '  dataDir=/data/user/0/computer.helium.sync' ;;
    *'cmd package list packages'*) echo 'package:computer.helium.sync uid:10234' ;;
    *'pidof computer.helium.sync'*) exit 1 ;;
    *'uname -m'*) echo x86_64 ;;
  esac
elif [[ \${1:-} == exec-out ]]; then
  if [[ -n \${ADB_STREAM_COUNTER:-} ]]; then
    count=0
    [[ ! -f \$ADB_STREAM_COUNTER ]] || count=\$(cat \$ADB_STREAM_COUNTER)
    count=\$((count + 1))
    printf '%s\n' \$count >\$ADB_STREAM_COUNTER
    if [[ \$count -ge 2 && -n \${ADB_STREAM_SECOND:-} ]]; then
      cat \$ADB_STREAM_SECOND
      exit 0
    fi
  fi
  cat '$test_root/android-profile.tar'
fi
EOF
cat >"$test_root/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '/synthetic-separate-nas\n'
EOF
cat >"$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -F) [[ "$2" == none ]]; shift 2 ;;
    -o) shift 2 ;;
    -i) [[ "$2" == "$DEPLOY_TEST_SSH_IDENTITY" ]]; shift 2 ;;
    -l) [[ "$2" == d ]]; shift 2 ;;
    *) exit 1 ;;
  esac
done
[[ "$1" == fixture-peer ]]
shift
command_text=$1
if [[ "$command_text" == "uname -n " ]]; then
  printf 'fixture-peer\n'
  exit
fi
command_text=${command_text//\/synthetic\/deploy-peer/${DEPLOY_TEST_PEER_ROOT}}
bash -c "$command_text"
EOF
cat >"$test_root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
[[ "$1" == -e && "$2" == *"-F none"* ]]
count=${#arguments[@]}
source_file=${arguments[count-2]}
target_file=${arguments[count-1]}
if [[ "$source_file" == fixture-peer:* ]]; then
  source_file=${source_file#fixture-peer:}
  source_file=${source_file/\/synthetic\/deploy-peer/${DEPLOY_TEST_PEER_ROOT}}
else
  [[ "$target_file" == fixture-peer:* ]]
  target_file=${target_file#fixture-peer:}
  target_file=${target_file/\/synthetic\/deploy-peer/${DEPLOY_TEST_PEER_ROOT}}
fi
cat "$source_file" >"$target_file"
chmod 600 "$target_file"
EOF
chmod 700 "$test_root/bin/git" "$test_root/bin/go" "$test_root/bin/adb" \
  "$test_root/bin/findmnt" "$test_root/bin/ssh" "$test_root/bin/rsync"
PATH="$test_root/bin:$PATH"
export PATH
export DEPLOY_TEST_SSH_IDENTITY="$test_root/ssh-identity"
export DEPLOY_TEST_PEER_ROOT="$shm_destination"

cat >"$test_root/artifact/helium-sync-linux-x86_64/runtime/helium" <<'EOF'
#!/usr/bin/env sh
echo 'Helium fixture 1'
EOF
cat >"$test_root/artifact/helium-sync-linux-x86_64/runtime/helium_crashpad_handler" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 755 \
  "$test_root/artifact/helium-sync-linux-x86_64/runtime/helium" \
  "$test_root/artifact/helium-sync-linux-x86_64/runtime/helium_crashpad_handler"
printf icu >"$test_root/artifact/helium-sync-linux-x86_64/runtime/icudtl.dat"
printf resources >"$test_root/artifact/helium-sync-linux-x86_64/runtime/resources.pak"
tar -C "$test_root/artifact" -cJf "$test_root/helium-linux.tar.xz" \
  helium-sync-linux-x86_64
artifact_sha=$(sha256sum "$test_root/helium-linux.tar.xz" | awk '{print $1}')
write_artifact_receipt() {
  local target=$1 output=$2
  "$repo_root/scripts/write-deployment-artifact-receipt.sh" \
    "$test_root/helium-linux.tar.xz" "$target" \
    "$commit" "$commit" "$commit" "$commit" \
    fixture-deployment-01 \
    "$(printf fixture-provenance | sha256sum | awk '{print $1}')" \
    "$(printf fixture-graph-receipt | sha256sum | awk '{print $1}')" \
    "$(printf fixture-graph-inventory | sha256sum | awk '{print $1}')" \
    "$output" >/dev/null
}

laptop_config=$test_root/laptop-backup.conf
laptop_generation=20260722T120000Z-aaaaaaaaaaaaaaaa
laptop_receipt=$(make_backup_receipt "$test_root/home/.config/net.imput.helium" \
  "$laptop_config" "$laptop_generation" laptop)
write_artifact_receipt linux-x86_64 "$test_root/laptop-artifact.receipt.env"
HOME="$test_root/home" HELIUM_LAPTOP_RELEASE_ROOT="$test_root/releases" \
  "$repo_root/scripts/laptop/install-laptop-sync.sh" install \
  "$test_root/helium-linux.tar.xz" "$test_root/laptop-artifact.receipt.env" \
  "$laptop_config" "$laptop_receipt" >"$test_root/laptop-install.out"
grep -qx 'install=activated' "$test_root/laptop-install.out"
test -L "$test_root/home/.local/opt/helium-sync-app"
test -d "$test_root/releases/browser/$artifact_sha"
test -f "$test_root/releases/browser/$artifact_sha/.helium-artifact-receipt.env"
HOME="$test_root/home" HELIUM_LAPTOP_RELEASE_ROOT="$test_root/releases" \
  "$repo_root/scripts/laptop/install-laptop-sync.sh" rollback "$artifact_sha" \
  >"$test_root/laptop-rollback.out"
grep -qx 'rollback=activated' "$test_root/laptop-rollback.out"

mkdir -p "$test_root/enrollment"
mkdir -p "$test_root/android-live/app_chrome/Default"
printf 'synthetic Android profile\n' >"$test_root/android-live/app_chrome/Default/Preferences"
tar -C "$test_root/android-live" -cf "$test_root/android-profile.tar" app_chrome
printf 'http://100.100.105.47:44719\n' >"$test_root/enrollment/base_url"
printf fixture-token >"$test_root/enrollment/token"
cat >"$test_root/enrollment/client.json" <<'EOF'
{"version":2,"device_id":"oneplus","role":"join","phase":"pending","revisions":{},"sequence":"0"}
EOF
chmod 600 "$test_root/enrollment/token" "$test_root/enrollment/client.json"
android_config=$test_root/android-backup.conf
android_generation=20260722T120100Z-bbbbbbbbbbbbbbbb
android_receipt=$(make_backup_receipt /data/user/0/computer.helium.sync/app_chrome \
  "$android_config" "$android_generation" android)
ADB="$test_root/bin/adb" "$repo_root/scripts/android-local/configure-android-chromium-sync.sh" \
  install "$test_root/enrollment" "$android_config" "$android_receipt" \
  >"$test_root/android-config.out"
grep -qx 'android_enrollment=installed' "$test_root/android-config.out"
grep -q 'app_chrome/Default/helium-sync' "$test_root/adb.log"
! grep -Eq 'first_run|EulaAccepted|ARCH_CHROOT|chroot' "$test_root/adb.log"

android_stream_generation=20260722T120200Z-cccccccccccccccc
ADB="$test_root/bin/adb" "$repo_root/scripts/android-local/backup-android-chromium-profile.sh" \
  "$android_config" "$android_stream_generation" >"$test_root/android-backup.out"
grep -qx 'backup=committed' "$test_root/android-backup.out"
"$repo_root/scripts/profile-backup/helium-profile-backup.sh" status \
  "$android_config" "$android_stream_generation" | grep -qx 'status=healthy'
printf 'different archive stream\n' >"$test_root/android-profile-changed.tar"
if ADB="$test_root/bin/adb" ADB_STREAM_COUNTER="$test_root/adb-stream-count" \
  ADB_STREAM_SECOND="$test_root/android-profile-changed.tar" \
  "$repo_root/scripts/android-local/backup-android-chromium-profile.sh" \
    "$android_config" 20260722T120300Z-dddddddddddddddd >/dev/null 2>&1; then
  echo 'changing Android profile stream committed a backup' >&2
  exit 1
fi
test ! -e "$tmp_destination/fixture/android/generations/20260722T120300Z-dddddddddddddddd"

sed -i 's#http://100.100.105.47:44719#https://100.100.105.47:44719#' "$test_root/enrollment/base_url"
if ADB="$test_root/bin/adb" "$repo_root/scripts/android-local/configure-android-chromium-sync.sh" \
  install "$test_root/enrollment" "$android_config" "$android_receipt" >/dev/null 2>&1; then
  echo 'inner TLS Android sync URL passed configuration' >&2
  exit 1
fi

grep -q 'helium-sync-releases' "$repo_root/scripts/android-local/install-chroot-helium.sh"
! grep -Fq 'rm -rf \"\$ROOT/opt/helium-sync\"' "$repo_root/scripts/android-local/install-chroot-helium.sh"
grep -q 'verify-deployment-artifact-receipt.sh' "$repo_root/scripts/android-local/install-chroot-helium.sh"
grep -q 'verify-receipt' "$repo_root/scripts/android-local/install-chroot-helium.sh"

printf 'deployment_foundations=passed\n'
