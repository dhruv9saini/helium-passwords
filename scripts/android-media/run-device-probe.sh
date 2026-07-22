#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-device-probe.sh ACCEPTANCE_DIRECTORY ADB_SERIAL NEW_EVIDENCE_DIRECTORY [OPTIONS]

Options:
  --h2 URL                         Require the exact HTTPS HTTP/2 fixture endpoint.
  --h3 URL                         Require the exact HTTPS HTTP/3 fixture endpoint.
  --background-foreground true    Exercise and require one background/resume cycle.
  --network-handoff none          Do not change device networking (default).
  --network-handoff wifi-to-cellular
                                   Disable Wi-Fi during the probe, require a browser
                                   connection-change event, and restore Wi-Fi on exit.
EOF
}

[[ $# -ge 3 ]] || { usage; exit 64; }
acceptance=$(realpath "$1")
serial=$2
evidence=$(realpath -m "$3")
shift 3

h2=
h3=
background_foreground=false
network_handoff=none
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage; exit 64; }
  case "$1" in
    --h2) h2=$2 ;;
    --h3) h3=$2 ;;
    --background-foreground) background_foreground=$2 ;;
    --network-handoff) network_handoff=$2 ;;
    *) echo "unknown device probe option: $1" >&2; exit 64 ;;
  esac
  shift 2
done

case "$background_foreground" in true|false) ;; *) echo 'background/foreground must be true or false' >&2; exit 64 ;; esac
case "$network_handoff" in none|wifi-to-cellular) ;; *) echo 'unsupported network handoff' >&2; exit 64 ;; esac
[[ -d "$acceptance" && -f "$acceptance/PACKAGE_SHA256SUMS" ]] || {
  echo "acceptance directory is incomplete" >&2
  exit 1
}
[[ ! -e "$evidence" ]] || { echo "evidence directory already exists" >&2; exit 1; }
command -v adb >/dev/null
command -v node >/dev/null
command -v sha256sum >/dev/null

metadata() {
  local name=$1
  local file=$2
  local value
  value=$(sed -n "s/^${name}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${name}=" "$file")" -eq 1 ]] || {
    echo "acceptance metadata is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

(cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS)
package=$(metadata package "$acceptance/acceptance.env")
case "$package" in
  computer.helium.sync.test|computer.helium.control.test) ;;
  *) echo "device probe requires a disposable package" >&2; exit 1 ;;
esac
artifact_sha256=$(metadata source_archive_sha256 "$acceptance/acceptance.env")
apk_sha256=$(metadata apk_sha256 "$acceptance/acceptance.env")
chromium_commit=$(metadata chromium_commit "$acceptance/acceptance.env")
helium_sync_commit=$(metadata helium_sync_commit "$acceptance/acceptance.env")
version_code=$(metadata version_code "$acceptance/acceptance.env")
version_name=$(metadata version_name "$acceptance/acceptance.env")
[[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ && "$apk_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$chromium_commit" =~ ^[0-9a-f]{40}$ && "$helium_sync_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$version_code" =~ ^[1-9][0-9]*$ && "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]

if [[ "$network_handoff" == wifi-to-cellular && "$serial" == *:* ]]; then
  echo "wifi-to-cellular requires a non-network ADB transport" >&2
  exit 1
fi
[[ "$(adb -s "$serial" get-state)" == device ]]
mapfile -t package_paths < <(adb -s "$serial" shell pm path "$package" | tr -d '\r')
[[ ${#package_paths[@]} -gt 0 && "${package_paths[0]}" == package:* ]] || {
  echo "disposable browser package is not installed" >&2
  exit 1
}
package_dump=$(adb -s "$serial" shell dumpsys package "$package" | tr -d '\r')
installed_version_code=$(sed -n 's/^[[:space:]]*versionCode=\([^ ]*\).*/\1/p' <<<"$package_dump" | head -n 1)
installed_version_name=$(sed -n 's/^[[:space:]]*versionName=//p' <<<"$package_dump" | head -n 1)
[[ "$installed_version_code" == "$version_code" ]] || {
  echo "installed package versionCode does not match the admitted artifact" >&2
  exit 1
}
[[ "$installed_version_name" == "$version_name" ]] || {
  echo "installed package versionName does not match the admitted artifact" >&2
  exit 1
}

evidence_parent=$(dirname "$evidence")
mkdir -p "$evidence_parent"
temporary=$(mktemp -d "$evidence_parent/.helium-device-probe.XXXXXX")
staged="$temporary/staged"
mkdir -p "$staged"
fixture_log="$staged/fixture-server.log"
result="$staged/result.json"
ready="$temporary/ready.json"
action_log="$staged/actions.env"
fixture_pid=
probe_pid=
reverse_created=false
forward_created=false
wifi_changed=false

cleanup() {
  local status=$?
  if [[ "$wifi_changed" == true ]]; then
    adb -s "$serial" shell svc wifi enable >/dev/null 2>&1 || true
  fi
  if [[ "$probe_pid" ]]; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
  fi
  if [[ "$forward_created" == true ]]; then
    adb -s "$serial" forward --remove tcp:9222 >/dev/null 2>&1 || true
  fi
  if [[ "$reverse_created" == true ]]; then
    adb -s "$serial" reverse --remove tcp:44721 >/dev/null 2>&1 || true
  fi
  if [[ "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ -d "$temporary" ]]; then
    find "$temporary" -depth -delete
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

node "$acceptance/runtime-acceptance/fixture-server.mjs" \
  --host 127.0.0.1 --port 44721 --media-dir "$acceptance/media" \
  > "$fixture_log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 100); do
  grep -q '"event":"listening"' "$fixture_log" && break
  kill -0 "$fixture_pid" 2>/dev/null || { cat "$fixture_log" >&2; exit 1; }
  sleep 0.1
done
grep -q '"event":"listening"' "$fixture_log" || { echo "fixture server did not become ready" >&2; exit 1; }

adb -s "$serial" reverse --no-rebind tcp:44721 tcp:44721 >/dev/null
reverse_created=true
adb -s "$serial" forward --no-rebind tcp:9222 localabstract:chrome_devtools_remote >/dev/null
forward_created=true

probe_args=(
  --cdp http://127.0.0.1:9222
  --fixture http://127.0.0.1:44721/probe
  --output "$result"
  --ready-file "$ready"
  --require-lifecycle "$background_foreground"
  --require-network-handoff "$([[ "$network_handoff" == none ]] && echo false || echo true)"
)
[[ -z "$h2" ]] || probe_args+=(--h2 "$h2")
[[ -z "$h3" ]] || probe_args+=(--h3 "$h3")
node "$acceptance/runtime-acceptance/run-cdp-probe.mjs" "${probe_args[@]}" &
probe_pid=$!
for _ in $(seq 1 200); do
  [[ -f "$ready" ]] && break
  kill -0 "$probe_pid" 2>/dev/null || { wait "$probe_pid"; exit 1; }
  sleep 0.1
done
[[ -f "$ready" ]] || { echo "browser probe did not become ready" >&2; exit 1; }

{
  printf 'schema_version=1\n'
  printf 'package=%s\n' "$package"
  printf 'background_foreground=%s\n' "$background_foreground"
  printf 'network_handoff=%s\n' "$network_handoff"
  printf 'version_code=%s\n' "$installed_version_code"
  printf 'version_name=%s\n' "$installed_version_name"
  printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
} > "$action_log"

if [[ "$background_foreground" == true ]]; then
  adb -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null
  sleep 1
  adb -s "$serial" shell monkey -p "$package" \
    -c android.intent.category.LAUNCHER 1 >/dev/null
  sleep 1
fi

if [[ "$network_handoff" == wifi-to-cellular ]]; then
  wifi_on=$(adb -s "$serial" shell settings get global wifi_on | tr -d '\r')
  mobile_data=$(adb -s "$serial" shell settings get global mobile_data | tr -d '\r')
  [[ "$wifi_on" == 1 ]] || { echo "wifi-to-cellular requires Wi-Fi to start enabled" >&2; exit 1; }
  [[ "$mobile_data" == 1 ]] || { echo "wifi-to-cellular requires mobile data to start enabled" >&2; exit 1; }
  adb -s "$serial" shell svc wifi disable >/dev/null
  wifi_changed=true
  sleep 3
fi

wait "$probe_pid"
probe_pid=
[[ -f "$result" ]]
if [[ "$wifi_changed" == true ]]; then
  adb -s "$serial" shell svc wifi enable >/dev/null
  wifi_changed=false
fi
printf 'completed_at=%s\n' "$(date --iso-8601=seconds)" >> "$action_log"
cp "$acceptance/acceptance.env" "$staged/acceptance.env"
(
  cd "$staged"
  sha256sum result.json actions.env acceptance.env > EVIDENCE_SHA256SUMS
)
mv "$staged" "$evidence"
cleanup
trap - EXIT INT TERM
printf 'evidence_directory=%s\n' "$evidence"
printf 'result_sha256=%s\n' "$(sha256sum "$evidence/result.json" | cut -d' ' -f1)"
