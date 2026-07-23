#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
boundary=$repo_root/scripts/android-media/disposable-browser.sh
test_root=$(mktemp -d /tmp/helium-disposable-browser-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'adb'
  printf ' %q' "$@"
  printf '\n'
} >> "$HELIUM_TEST_ADB_LOG"

[[ "$1" == -s && "$2" =~ ^[A-Za-z0-9._:-]+$ ]]
shift 2
device=$HELIUM_TEST_DEVICE_ROOT
installed="$device/data/app/test/base.apk"
installed_package_file="$device/installed-package"
debug_app_file="$device/debug-app"
wait_file="$device/wait-for-debugger"
running_file="$device/running-package"

remote_path() {
  case "$1" in
    /data/local/tmp/chrome-command-line)
      printf '%s/data/local/tmp/chrome-command-line' "$device"
      ;;
    /data/local/chrome-command-line)
      printf '%s/data/local/chrome-command-line' "$device"
      ;;
    /data/app/test/base.apk)
      printf '%s' "$installed"
      ;;
    *) return 1 ;;
  esac
}

command=${1-}
shift || true
case "$command" in
  get-state)
    [[ $# -eq 0 ]]
    printf 'device\n'
    ;;
  install)
    [[ "$1" == -r && "$2" == --user && "$3" == 0 && $# -eq 4 ]]
    mkdir -p "$(dirname "$installed")"
    cp "$4" "$installed"
    printf '%s\n' "$HELIUM_TEST_PACKAGE" > "$installed_package_file"
    printf 'Performing Streamed Install\nSuccess\n'
    ;;
  push)
    [[ $# -eq 2 ]]
    source_file=$1
    destination=$(remote_path "$2")
    if [[ "${HELIUM_TEST_FAIL_PUSH_PATH:-}" == "$2" &&
          ! -e "$device/push-failed-once" ]]; then
      : > "$device/push-failed-once"
      exit 1
    fi
    mkdir -p "$(dirname "$destination")"
    cp "$source_file" "$destination"
    printf '%s: 1 file pushed\n' "$source_file"
    ;;
  exec-out)
    [[ "$1" == cat && $# -eq 2 ]]
    cat "$(remote_path "$2")"
    ;;
  shell)
    if [[ $# -eq 1 ]]; then
      remote=$1
      path=
      for candidate in \
        /data/local/tmp/chrome-command-line \
        /data/local/chrome-command-line; do
        if [[ "$remote" == *"'$candidate'"* ]]; then
          path=$candidate
          break
        fi
      done
      [[ -n "$path" ]]
      host_path=$(remote_path "$path")
      case "$remote" in
        "if [ -L "*)
          if [[ -L "$host_path" ]]; then
            printf unsafe
          elif [[ -f "$host_path" ]]; then
            printf file
          elif [[ -e "$host_path" ]]; then
            printf unsafe
          else
            printf absent
          fi
          ;;
        "stat -c %a -- "*)
          stat -c %a "$host_path"
          ;;
        "chmod "*)
          mode=${remote#chmod }
          mode=${mode%% *}
          chmod "$mode" "$host_path"
          ;;
        "rm -f -- "*)
          if [[ -e "$host_path" || -L "$host_path" ]]; then
            find "$host_path" -depth -delete
          fi
          ;;
        *) printf 'unexpected remote shell command: %s\n' "$remote" >&2; exit 1 ;;
      esac
      exit 0
    fi

    subcommand=$1
    shift
    case "$subcommand" in
      pm)
        [[ "$1" == path && $# -eq 2 ]]
        if [[ -f "$installed_package_file" &&
              "$(<"$installed_package_file")" == "$2" ]]; then
          printf 'package:/data/app/test/base.apk\n'
        fi
        ;;
      dumpsys)
        [[ "$1" == package && $# -eq 2 &&
            "$(<"$installed_package_file")" == "$2" ]]
        printf '  userId=10123\n'
        printf '  versionCode=787500005 minSdk=29 targetSdk=36\n'
        printf '  versionName=150.0.7871.181\n'
        ;;
      settings)
        [[ "$1" == get && "$2" == global && $# -eq 3 ]]
        case "$3" in
          debug_app) cat "$debug_app_file" ;;
          wait_for_debugger) cat "$wait_file" ;;
          *) exit 1 ;;
        esac
        ;;
      am)
        action=$1
        shift
        case "$action" in
          force-stop)
            [[ $# -eq 1 && "$1" == "$HELIUM_TEST_PACKAGE" ]]
            if [[ -f "$running_file" &&
                  "$(<"$running_file")" == "$1" ]]; then
              find "$running_file" -depth -delete
            fi
            ;;
          set-debug-app)
            [[ "$1" == --persistent && $# -eq 2 &&
                "$2" == "$HELIUM_TEST_PACKAGE" ]]
            printf '%s\n' "$2" > "$debug_app_file"
            printf '0\n' > "$wait_file"
            ;;
          clear-debug-app)
            [[ $# -eq 0 ]]
            printf 'null\n' > "$debug_app_file"
            printf '0\n' > "$wait_file"
            ;;
          *) exit 1 ;;
        esac
        ;;
      monkey)
        [[ "$1" == -p && "$2" == "$HELIUM_TEST_PACKAGE" &&
            "$3" == -c && "$4" == android.intent.category.LAUNCHER &&
            "$5" == 1 && $# -eq 5 ]]
        for source in \
          /data/local/tmp/chrome-command-line \
          /data/local/chrome-command-line; do
          suffix=${source#/data/local/}
          suffix=${suffix//\//-}
          cp "$(remote_path "$source")" "$device/launched-$suffix"
        done
        [[ "${HELIUM_TEST_MONKEY_FAIL:-false}" != true ]] || exit 9
        printf '%s\n' "$HELIUM_TEST_PACKAGE" > "$running_file"
        printf 'Events injected: 1\n'
        ;;
      pidof)
        [[ $# -eq 1 && "$1" == "$HELIUM_TEST_PACKAGE" ]]
        if [[ -f "$running_file" && "$(<"$running_file")" == "$1" ]]; then
          printf '1234\n'
        fi
        ;;
      cat)
        [[ $# -eq 1 && "$1" == /proc/net/unix ]]
        if [[ -f "$running_file" ]]; then
          case "$(<"$running_file")" in
            computer.helium.sync.test) socket=helium_sync_test_devtools_remote ;;
            computer.helium.control.test) socket=helium_control_test_devtools_remote ;;
            *) exit 1 ;;
          esac
          printf '00000000: 00000002 00000000 00010000 0001 01 12345 @%s\n' \
            "$socket"
        fi
        ;;
      *) printf 'unexpected fake adb shell command: %s\n' "$subcommand" >&2; exit 1 ;;
    esac
    ;;
  *) printf 'unexpected fake adb command: %s\n' "$command" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/adb"

make_acceptance() {
  local directory=$1
  local package=$2
  local checksum_file
  mkdir -p "$directory/runtime-acceptance" "$directory/media"
  printf 'admitted disposable APK for %s\n' "$package" \
    > "$directory/Browser-test.apk"
  printf 'runtime\n' > "$directory/runtime-acceptance/runner"
  printf 'fixture\n' > "$directory/media/synthetic"
  local apk_sha256
  apk_sha256=$(sha256sum "$directory/Browser-test.apk" | awk '{print $1}')
  cat > "$directory/acceptance.env" <<EOF
schema_version=2
package=$package
helium_sync_commit=1111111111111111111111111111111111111111
chromium_commit=2222222222222222222222222222222222222222
version_code=787500005
version_name=150.0.7871.181
source_archive_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
apk_sha256=$apk_sha256
runtime_kit_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
prepared_at=2026-07-22T00:00:00+00:00
EOF
  checksum_file=$(mktemp "$test_root/package-sums.XXXXXX")
  (
    cd "$directory"
    find . -type f ! -name PACKAGE_SHA256SUMS -print0 |
      sort -z | xargs -0 sha256sum
  ) > "$checksum_file"
  mv "$checksum_file" "$directory/PACKAGE_SHA256SUMS"
}

new_device() {
  local directory=$1
  mkdir -p "$directory/data/local/tmp" "$directory/data/local"
  printf 'null\n' > "$directory/debug-app"
  printf '0\n' > "$directory/wait-for-debugger"
}

run_boundary() {
  PATH="$test_root/bin:$PATH" "$boundary" "$@"
}

assert_clean_globals() {
  local device=$1
  [[ "$(<"$device/debug-app")" == null ]]
  [[ "$(<"$device/wait-for-debugger")" == 0 ]]
}

acceptance_sync="$test_root/acceptance-sync"
make_acceptance "$acceptance_sync" computer.helium.sync.test
device_sync="$test_root/device-sync"
new_device "$device_sync"
printf 'old tmp\0command\n' > "$device_sync/data/local/tmp/chrome-command-line"
printf 'old local\0command\n' > "$device_sync/data/local/chrome-command-line"
cp "$device_sync/data/local/tmp/chrome-command-line" "$test_root/original-tmp"
cp "$device_sync/data/local/chrome-command-line" "$test_root/original-local"
chmod 0600 "$device_sync/data/local/tmp/chrome-command-line"
chmod 0640 "$device_sync/data/local/chrome-command-line"

export HELIUM_TEST_DEVICE_ROOT=$device_sync
export HELIUM_TEST_ADB_LOG="$test_root/sync-adb.log"
export HELIUM_TEST_PACKAGE=computer.helium.sync.test
run_boundary install "$acceptance_sync" USB-SERIAL > "$test_root/sync-install.out"
grep -qx 'operation=install' "$test_root/sync-install.out"
grep -qx 'package=computer.helium.sync.test' "$test_root/sync-install.out"
cmp "$acceptance_sync/Browser-test.apk" "$device_sync/data/app/test/base.apk"

run_boundary launch "$acceptance_sync" USB-SERIAL > "$test_root/sync-launch.out"
grep -qx 'operation=launch' "$test_root/sync-launch.out"
grep -qx 'device_socket=helium_sync_test_devtools_remote' \
  "$test_root/sync-launch.out"
printf '%s\n' \
  'chrome --enable-automation --remote-debugging-socket-name=helium_sync_test_devtools_remote' \
  > "$test_root/expected-sync-command"
cmp "$test_root/expected-sync-command" \
  "$device_sync/launched-tmp-chrome-command-line"
cmp "$test_root/expected-sync-command" \
  "$device_sync/launched-chrome-command-line"
cmp "$test_root/original-tmp" \
  "$device_sync/data/local/tmp/chrome-command-line"
cmp "$test_root/original-local" \
  "$device_sync/data/local/chrome-command-line"
[[ "$(stat -c %a "$device_sync/data/local/tmp/chrome-command-line")" == 600 ]]
[[ "$(stat -c %a "$device_sync/data/local/chrome-command-line")" == 640 ]]
assert_clean_globals "$device_sync"
[[ "$(<"$device_sync/running-package")" == computer.helium.sync.test ]]
grep -Fq "install -r --user 0 $acceptance_sync/Browser-test.apk" \
  "$test_root/sync-adb.log"
if grep -Fq -- '--ignore-certificate-errors' \
  "$device_sync/launched-tmp-chrome-command-line"; then
  echo 'launch without a fixture receipt gained a certificate override' >&2
  exit 1
fi

spki=$(printf 'A%.0s' {1..43})=
fixture_receipt="$test_root/fixture-provenance.json"
printf '%s\n' \
  "{\"schema_version\":1,\"disposable_only\":true,\"tls_mode\":\"private-ca-spki\",\"hostname\":\"lm.tail0168aa.ts.net\",\"h2_port\":44723,\"h3_port\":44724,\"leaf_spki_sha256_base64\":\"$spki\",\"leaf_cert_sha256\":\"$(printf 'a%.0s' {1..64})\",\"required_chromium_switch\":\"--ignore-certificate-errors-spki-list=$spki\"}" \
  > "$fixture_receipt"

acceptance_control="$test_root/acceptance-control"
make_acceptance "$acceptance_control" computer.helium.control.test
device_control="$test_root/device-control"
new_device "$device_control"
export HELIUM_TEST_DEVICE_ROOT=$device_control
export HELIUM_TEST_ADB_LOG="$test_root/control-adb.log"
export HELIUM_TEST_PACKAGE=computer.helium.control.test
run_boundary install "$acceptance_control" USB-SERIAL > "$test_root/control-install.out"
run_boundary launch "$acceptance_control" USB-SERIAL \
  --fixture-receipt "$fixture_receipt" > "$test_root/control-launch.out"
grep -qx 'device_socket=helium_control_test_devtools_remote' \
  "$test_root/control-launch.out"
grep -Eq '^fixture_receipt_sha256=[0-9a-f]{64}$' \
  "$test_root/control-launch.out"
printf '%s\n' \
  "chrome --enable-automation --remote-debugging-socket-name=helium_control_test_devtools_remote --ignore-certificate-errors-spki-list=$spki" \
  > "$test_root/expected-control-command"
cmp "$test_root/expected-control-command" \
  "$device_control/launched-tmp-chrome-command-line"
cmp "$test_root/expected-control-command" \
  "$device_control/launched-chrome-command-line"
[[ ! -e "$device_control/data/local/tmp/chrome-command-line" ]]
[[ ! -e "$device_control/data/local/chrome-command-line" ]]
assert_clean_globals "$device_control"

device_failure="$test_root/device-launch-failure"
new_device "$device_failure"
printf 'restore tmp\n' > "$device_failure/data/local/tmp/chrome-command-line"
printf 'restore local\n' > "$device_failure/data/local/chrome-command-line"
export HELIUM_TEST_DEVICE_ROOT=$device_failure
export HELIUM_TEST_ADB_LOG="$test_root/launch-failure-adb.log"
export HELIUM_TEST_PACKAGE=computer.helium.sync.test
run_boundary install "$acceptance_sync" USB-SERIAL >/dev/null
export HELIUM_TEST_MONKEY_FAIL=true
if run_boundary launch "$acceptance_sync" USB-SERIAL \
  >"$test_root/launch-failure.out" 2>&1; then
  echo 'failed Android launch unexpectedly passed' >&2
  exit 1
fi
unset HELIUM_TEST_MONKEY_FAIL
grep -qx 'restore tmp' "$device_failure/data/local/tmp/chrome-command-line"
grep -qx 'restore local' "$device_failure/data/local/chrome-command-line"
assert_clean_globals "$device_failure"
[[ ! -e "$device_failure/running-package" ]]
grep -Fq 'shell am force-stop computer.helium.sync.test' \
  "$test_root/launch-failure-adb.log"

device_partial="$test_root/device-partial-push"
new_device "$device_partial"
printf 'partial tmp\n' > "$device_partial/data/local/tmp/chrome-command-line"
printf 'partial local\n' > "$device_partial/data/local/chrome-command-line"
export HELIUM_TEST_DEVICE_ROOT=$device_partial
export HELIUM_TEST_ADB_LOG="$test_root/partial-adb.log"
run_boundary install "$acceptance_sync" USB-SERIAL >/dev/null
export HELIUM_TEST_FAIL_PUSH_PATH=/data/local/chrome-command-line
if run_boundary launch "$acceptance_sync" USB-SERIAL \
  >"$test_root/partial.out" 2>&1; then
  echo 'partial Android command-line write unexpectedly passed' >&2
  exit 1
fi
unset HELIUM_TEST_FAIL_PUSH_PATH
grep -qx 'partial tmp' "$device_partial/data/local/tmp/chrome-command-line"
grep -qx 'partial local' "$device_partial/data/local/chrome-command-line"
assert_clean_globals "$device_partial"
[[ ! -e "$device_partial/running-package" ]]

device_busy="$test_root/device-busy-debug"
new_device "$device_busy"
export HELIUM_TEST_DEVICE_ROOT=$device_busy
export HELIUM_TEST_ADB_LOG="$test_root/busy-adb.log"
run_boundary install "$acceptance_sync" USB-SERIAL >/dev/null
printf 'com.example.existing\n' > "$device_busy/debug-app"
if run_boundary launch "$acceptance_sync" USB-SERIAL \
  >"$test_root/busy.out" 2>&1; then
  echo 'pre-existing Android debug app unexpectedly replaced' >&2
  exit 1
fi
grep -q 'refusing to replace an existing Android debug-app selection' \
  "$test_root/busy.out"
[[ "$(<"$device_busy/debug-app")" == com.example.existing ]]
if grep -Fq 'shell am force-stop' "$test_root/busy-adb.log"; then
  echo 'existing Android debug-app rejection touched a package' >&2
  exit 1
fi

device_wait="$test_root/device-busy-wait"
new_device "$device_wait"
export HELIUM_TEST_DEVICE_ROOT=$device_wait
export HELIUM_TEST_ADB_LOG="$test_root/wait-adb.log"
run_boundary install "$acceptance_sync" USB-SERIAL >/dev/null
printf '1\n' > "$device_wait/wait-for-debugger"
if run_boundary launch "$acceptance_sync" USB-SERIAL \
  >"$test_root/wait.out" 2>&1; then
  echo 'pre-existing Android wait-for-debugger unexpectedly replaced' >&2
  exit 1
fi
grep -q 'refusing an existing wait-for-debugger state' "$test_root/wait.out"
[[ "$(<"$device_wait/wait-for-debugger")" == 1 ]]

device_symlink="$test_root/device-symlink"
new_device "$device_symlink"
export HELIUM_TEST_DEVICE_ROOT=$device_symlink
export HELIUM_TEST_ADB_LOG="$test_root/symlink-adb.log"
run_boundary install "$acceptance_sync" USB-SERIAL >/dev/null
printf 'outside\n' > "$device_symlink/outside"
ln -s "$device_symlink/outside" \
  "$device_symlink/data/local/tmp/chrome-command-line"
if run_boundary launch "$acceptance_sync" USB-SERIAL \
  >"$test_root/symlink.out" 2>&1; then
  echo 'symlink Android command-line path unexpectedly passed' >&2
  exit 1
fi
grep -q 'refusing unsafe Android Chromium command-line path' \
  "$test_root/symlink.out"
[[ -L "$device_symlink/data/local/tmp/chrome-command-line" ]]
grep -qx 'outside' "$device_symlink/outside"

: > "$test_root/no-adb.log"
export HELIUM_TEST_ADB_LOG="$test_root/no-adb.log"
printf 'tamper\n' >> "$acceptance_sync/Browser-test.apk"
if run_boundary install "$acceptance_sync" USB-SERIAL \
  >"$test_root/tamper.out" 2>&1; then
  echo 'tampered admitted APK unexpectedly installed' >&2
  exit 1
fi
[[ ! -s "$test_root/no-adb.log" ]]

acceptance_production="$test_root/acceptance-production"
make_acceptance "$acceptance_production" computer.helium.sync
: > "$test_root/no-adb.log"
if run_boundary install "$acceptance_production" USB-SERIAL \
  >"$test_root/production.out" 2>&1; then
  echo 'normal Helium package unexpectedly admitted' >&2
  exit 1
fi
grep -q 'only disposable Helium test packages are admitted' \
  "$test_root/production.out"
[[ ! -s "$test_root/no-adb.log" ]]

printf '%s\n' \
  '{"schema_version":1,"disposable_only":true,"tls_mode":"private-ca-spki","hostname":"lm.tail0168aa.ts.net","h2_port":44723,"h3_port":44724,"leaf_spki_sha256_base64":"wrong","leaf_cert_sha256":"wrong","required_chromium_switch":"--ignore-certificate-errors"}' \
  > "$test_root/bad-fixture-receipt.json"
: > "$test_root/no-adb.log"
if run_boundary launch "$acceptance_control" USB-SERIAL \
  --fixture-receipt "$test_root/bad-fixture-receipt.json" \
  >"$test_root/bad-fixture.out" 2>&1; then
  echo 'malformed fixture receipt unexpectedly admitted' >&2
  exit 1
fi
grep -q 'invalid or mismatched SPKI override' "$test_root/bad-fixture.out"
[[ ! -s "$test_root/no-adb.log" ]]

bash -n "$boundary"
shellcheck "$boundary" "$repo_root/scripts/tests/android-disposable-browser.test.sh"
grep -Fq 'computer.helium.sync.test)' "$boundary"
grep -Fq 'computer.helium.control.test)' "$boundary"
grep -Fq -- '--enable-automation --remote-debugging-socket-name=%s' "$boundary"
grep -Fq -- '--ignore-certificate-errors-spki-list=' "$boundary"
if grep -Fq -- '--ignore-certificate-errors ' "$boundary"; then
  echo 'broad certificate bypass entered the disposable boundary' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(uninstall|pm clear)([[:space:]]|$)' "$boundary"; then
  echo 'destructive package operation entered the disposable boundary' >&2
  exit 1
fi
if grep -Eq 'computer\.helium\.(sync|control)([^.]|$)' "$boundary"; then
  echo 'normal package identity entered the disposable boundary' >&2
  exit 1
fi

printf 'Android disposable install/launch boundary passed\n'
