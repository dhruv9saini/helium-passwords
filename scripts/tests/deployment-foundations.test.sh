#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "$repo_root/.deployment-foundations.XXXXXX")
tmp_destination=$(mktemp -d /tmp/helium-deploy-backup-a.XXXXXX)
shm_destination=$(mktemp -d /dev/shm/helium-deploy-backup-b.XXXXXX)
cleanup() { find "$test_root" "$tmp_destination" "$shm_destination" -depth -delete; }
trap cleanup EXIT
mkdir -p "$test_root/bin" "$test_root/home/.config/net.imput.helium/Default" \
  "$test_root/artifact"
printf 'age1fixture-a\nage1fixture-b\n' >"$test_root/recipients.txt"
printf 'AGE-SECRET-KEY-fixture\n' >"$test_root/identity.txt"
chmod 600 "$test_root/recipients.txt" "$test_root/identity.txt"

make_backup_receipt() {
  local source_path=$1 config=$2 generation=$3 profile_id=$4
  local cipher=$test_root/cipher-$profile_id cipher_sha cipher_size recipients_sha path_sha archive_root dest ns receipt
  printf 'synthetic encrypted profile %s\n' "$profile_id" >"$cipher"
  cipher_sha=$(sha256sum "$cipher" | awk '{print $1}')
  cipher_size=$(stat -c %s "$cipher")
  recipients_sha=$(sort -u "$test_root/recipients.txt" | sha256sum | awk '{print $1}')
  path_sha=$(printf %s "$source_path" | sha256sum | awk '{print $1}')
  archive_root=${source_path##*/}
  if [[ "$profile_id" == android && -f "$test_root/android-profile.tar" ]]; then
    tree_sha=$(sha256sum "$test_root/android-profile.tar" | awk '{print $1}')
  elif [[ -d "$source_path" ]]; then
    tree_sha=$(tar --sort=name --format=posix \
      --pax-option=delete=atime,delete=ctime --mtime=@0 \
      --owner=0 --group=0 --numeric-owner -C "$source_path" -cf - . | \
      sha256sum | awk '{print $1}')
  else
    tree_sha=$(printf 'synthetic-tree-%s' "$profile_id" | sha256sum | awk '{print $1}')
  fi
  cat >"$config" <<EOF
version=1
source_device=fixture
profile_id=$profile_id
source_path=$source_path
age_recipients=$test_root/recipients.txt
age_identity=$test_root/identity.txt
retention_keep=2
destination_reserve_bytes=1
destination=copy-a|$tmp_destination
destination=copy-b|$shm_destination
EOF
  chmod 600 "$config"
  for dest in "$tmp_destination" "$shm_destination"; do
    ns=$dest/helium-profile-backups/fixture/$profile_id/generations
    mkdir -p "$ns"
    cp "$cipher" "$ns/$generation.tar.zst.age"
    receipt=$ns/$generation.receipt.env
    cat >"$receipt" <<EOF
schema_version=1
source_device=fixture
profile_id=$profile_id
profile_path_sha256=$path_sha
source_tree_sha256=$tree_sha
archive_root=$archive_root
generation=$generation
cipher_sha256=$cipher_sha
cipher_size=$cipher_size
source_bytes=123
recipients_sha256=$recipients_sha
created_at=2026-07-22T12:00:00Z
EOF
    chmod 600 "$receipt" "$ns/$generation.tar.zst.age"
  done
  printf '%s\n' "$tmp_destination/helium-profile-backups/fixture/$profile_id/generations/$generation.receipt.env"
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
cat >"$test_root/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode= output= input=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --recipients-file|--identity) shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
case "$mode" in
  encrypt) openssl enc -aes-256-cbc -pbkdf2 -pass pass:synthetic-deploy-test -out "$output" ;;
  decrypt) openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:synthetic-deploy-test -in "$input" ;;
  *) exit 64 ;;
esac
EOF
chmod 700 "$test_root/bin/git" "$test_root/bin/go" "$test_root/bin/adb" "$test_root/bin/age"
PATH="$test_root/bin:$PATH"
export PATH

cat >"$test_root/artifact/helium" <<'EOF'
#!/usr/bin/env sh
echo 'Helium fixture 1'
EOF
cat >"$test_root/artifact/helium_crashpad_handler" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod 755 "$test_root/artifact/helium" "$test_root/artifact/helium_crashpad_handler"
printf icu >"$test_root/artifact/icudtl.dat"
printf resources >"$test_root/artifact/resources.pak"
tar -C "$test_root/artifact" -cJf "$test_root/helium-linux.tar.xz" .
artifact_sha=$(sha256sum "$test_root/helium-linux.tar.xz" | awk '{print $1}')
artifact_size=$(stat -c %s "$test_root/helium-linux.tar.xz")
write_artifact_receipt() {
  local target=$1 output=$2
  cat >"$output" <<EOF
schema_version=1
artifact_sha256=$artifact_sha
artifact_size=$artifact_size
target=$target
helium_sync_commit=$commit
helium_passwords_commit=$commit
helium_core_commit=$commit
chromium_commit=$commit
build_job_id=fixture-deployment-01
provenance_sha256=$(printf fixture-provenance | sha256sum | awk '{print $1}')
created_at=2026-07-22T12:00:00Z
EOF
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
  | grep -qx 'rollback=activated'

mkdir -p "$test_root/enrollment"
mkdir -p "$test_root/android-live/app_chrome/Default"
printf 'synthetic Android profile\n' >"$test_root/android-live/app_chrome/Default/Preferences"
tar -C "$test_root/android-live" -cf "$test_root/android-profile.tar" app_chrome
printf 'https://lm.tailnet.test:44719\n' >"$test_root/enrollment/base_url"
printf fixture-token >"$test_root/enrollment/token"
cat >"$test_root/enrollment/client.json" <<'EOF'
{"version":1,"device_id":"oneplus","role":"join","phase":"pending","active_key_id":"key-a","keys":{"key-a":"ciphertext"},"local_seal_key":"local"}
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
test ! -e "$tmp_destination/helium-profile-backups/fixture/android/generations/20260722T120300Z-dddddddddddddddd.receipt.env"

sed -i 's#https://lm.tailnet.test:44719#http://127.0.0.1:44719#' "$test_root/enrollment/base_url"
if ADB="$test_root/bin/adb" "$repo_root/scripts/android-local/configure-android-chromium-sync.sh" \
  install "$test_root/enrollment" "$android_config" "$android_receipt" >/dev/null 2>&1; then
  echo 'insecure Android sync URL passed configuration' >&2
  exit 1
fi

grep -q 'helium-sync-releases' "$repo_root/scripts/android-local/install-chroot-helium.sh"
! grep -Fq 'rm -rf \"\$ROOT/opt/helium-sync\"' "$repo_root/scripts/android-local/install-chroot-helium.sh"
grep -q 'verify-artifact-receipt.sh' "$repo_root/scripts/android-local/install-chroot-helium.sh"
grep -q 'verify-receipt' "$repo_root/scripts/android-local/install-chroot-helium.sh"

printf 'deployment_foundations=passed\n'
