#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 SYNC_ACCEPTANCE_DIRECTORY ADB_SERIAL" >&2
  exit 64
fi

acceptance=$(realpath "$1")
serial=$2
package=computer.helium.sync.test
marker=app_chrome/Default/.helium-cookie-disposable-profile-v1

command -v adb >/dev/null
command -v sha256sum >/dev/null
[[ -d "$acceptance" && -f "$acceptance/PACKAGE_SHA256SUMS" &&
    -f "$acceptance/acceptance.env" && -f "$acceptance/Browser-test.apk" ]] || {
  echo "Sync acceptance directory is incomplete" >&2
  exit 1
}
(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS >/dev/null)

metadata() {
  local name=$1
  local value
  value=$(sed -n "s/^${name}=//p" "$acceptance/acceptance.env")
  [[ -n "$value" && "$(grep -c "^${name}=" "$acceptance/acceptance.env")" -eq 1 ]] || {
    echo "acceptance metadata is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

[[ "$(metadata package)" == "$package" ]] || {
  echo "cookie acceptance preparation requires the disposable Sync package" >&2
  exit 1
}
expected_apk_sha256=$(metadata apk_sha256)
[[ "$expected_apk_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$(adb -s "$serial" get-state)" == device ]]

mapfile -t package_paths < <(adb -s "$serial" shell pm path "$package" | tr -d '\r')
[[ ${#package_paths[@]} -eq 1 && "${package_paths[0]}" == package:/data/app/*/base.apk ]] || {
  echo "disposable Sync browser must be one installed monolithic base APK" >&2
  exit 1
}
installed_apk=${package_paths[0]#package:}
[[ "$installed_apk" != *[[:space:]]* && "$installed_apk" != *"'"* &&
    "$installed_apk" != *'"'* ]] || {
  echo "installed disposable APK path is unsafe" >&2
  exit 1
}
installed_apk_sha256=$(
  adb -s "$serial" exec-out cat "$installed_apk" |
    sha256sum | cut -d' ' -f1
)
[[ "$installed_apk_sha256" == "$expected_apk_sha256" ]] || {
  echo "installed disposable Sync APK does not match the admitted artifact" >&2
  exit 1
}

if adb -s "$serial" shell pidof "$package" | tr -d '\r' | grep -q .; then
  echo "stop the disposable Sync package before preparing its new profile" >&2
  exit 1
fi

remote_script='
  set -eu
  test ! -e app_chrome/Default
  umask 077
  mkdir -p app_chrome/Default
  printf "%s\n" helium-cookie-disposable-profile-v1 > app_chrome/Default/.helium-cookie-disposable-profile-v1
  chmod 600 app_chrome/Default/.helium-cookie-disposable-profile-v1
'
adb -s "$serial" shell "run-as $package sh -c '$remote_script'"
mode=$(adb -s "$serial" exec-out run-as "$package" \
  stat -c %a "$marker" | tr -d '\r')
contents=$(adb -s "$serial" exec-out run-as "$package" \
  cat "$marker" | tr -d '\r')
[[ "$mode" == 600 && "$contents" == helium-cookie-disposable-profile-v1 ]] || {
  echo "disposable cookie profile marker verification failed" >&2
  exit 1
}

printf 'package=%s\n' "$package"
printf 'apk_sha256=%s\n' "$installed_apk_sha256"
printf 'marker=%s\n' "$marker"
printf 'next=launch only this disposable package with its admitted automation and fixture switches\n'
