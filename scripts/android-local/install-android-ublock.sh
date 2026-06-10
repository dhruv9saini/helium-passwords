#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
adb_bin=${ADB:-adb}
package=${CHROMIUM_ANDROID_PACKAGE:-computer.helium.sync}
restart=${HELIUM_ANDROID_UBLOCK_RESTART:-true}
default_ai_overview_filters=$(cat <<'EOF'
www.google.*##:matches-path(/^\/search/) .dRpWwb.M8OgIe.bzXtMb
www.google.*##:matches-path(/^\/search/) .GcKpu
www.google.*##:matches-path(/^\/search/) .hdzaWe
www.google.*##:matches-path(/^\/search/) .YzCcne
www.google.*##:matches-path(/^\/search/) div[data-mcpr]:has-text(/^AI Overview$/i)
www.google.*##:matches-path(/^\/search/) [data-aquarium]
www.google.*##:matches-path(/^\/search/) [data-subtree="mfc"]
www.google.*##:matches-path(/^\/search/) style + div[data-mcpr][style^="margin-bottom:"]:has(div[data-async-type="folsrch"])
www.google.*##:matches-path(/^\/search/) style + div[data-mcpr][style^="margin-bottom:"] div[data-async-type="folsrch"]
EOF
)

if [[ -n "${HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS+x}" ]]; then
  ai_overview_filters=$HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS
else
  ai_overview_filters=$default_ai_overview_filters
fi

if [[ -n "${HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS_FILE:-}" ]]; then
  ai_overview_filters=$(<"$HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTERS_FILE")
elif [[ -n "${HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTER+x}" ]]; then
  ai_overview_filters=$HELIUM_ANDROID_UBLOCK_AI_OVERVIEW_FILTER
fi

section_value() {
  local key=$1
  awk -F' *= *' -v key="$key" '
    $0 == "[ublock_origin]" { in_section = 1; next }
    /^\[/ { in_section = 0 }
    in_section && $1 == key { print $2; exit }
  ' "$repo_root/helium-chromium/deps.ini"
}

version=$(section_value version)
url=$(section_value url)
expected_sha=$(section_value sha256)
download_name=$(section_value download_filename)

if [[ -z "$version" || -z "$url" || -z "$expected_sha" || -z "$download_name" ]]; then
  echo "Could not read uBlock Origin metadata from helium-chromium/deps.ini" >&2
  exit 1
fi

url=${url//%(version)s/$version}
download_name=${download_name//%(version)s/$version}

command -v sha256sum >/dev/null
command -v tar >/dev/null
command -v unzip >/dev/null

cache_dir=${XDG_CACHE_HOME:-"$HOME/.cache"}/helium-sync
mkdir -p "$cache_dir"

zip_path=${UBLOCK_ZIP:-}
if [[ -z "$zip_path" ]]; then
  for candidate in \
    "$cache_dir/$download_name" \
    "$repo_root/build/download_cache/$download_name" \
    "$repo_root/../helium-sync-local/helium-linux/build/download_cache/$download_name"; do
    if [[ -f "$candidate" ]]; then
      zip_path=$candidate
      break
    fi
  done
fi

if [[ -z "$zip_path" ]]; then
  zip_path="$cache_dir/$download_name"
  if command -v curl >/dev/null; then
    curl -L --fail --output "$zip_path" "$url"
  else
    command -v wget >/dev/null
    wget -O "$zip_path" "$url"
  fi
fi

actual_sha=$(sha256sum "$zip_path" | awk '{ print $1 }')
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "uBlock Origin SHA256 mismatch for $zip_path" >&2
  echo "expected: $expected_sha" >&2
  echo "actual:   $actual_sha" >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

unzip -q "$zip_path" -d "$work_dir/unpacked"
extension_dir=$work_dir/unpacked
if [[ ! -f "$extension_dir/manifest.json" ]]; then
  mapfile -t manifests < <(find "$work_dir/unpacked" -mindepth 2 -maxdepth 2 -name manifest.json -print)
  if [[ ${#manifests[@]} -ne 1 ]]; then
    echo "Could not find a single unpacked uBlock manifest in $zip_path" >&2
    exit 1
  fi
  extension_dir=$(dirname "${manifests[0]}")
fi

helium_annoyances="$extension_dir/assets/helium/annoyances.txt"
if [[ -n "$ai_overview_filters" && -f "$helium_annoyances" ]]; then
  header='! Local laptop uBO filters: hide Google AI Overviews.'
  grep -Fqx "$header" "$helium_annoyances" || printf '\n%s\n' "$header" >> "$helium_annoyances"
  while IFS= read -r ai_overview_filter; do
    [[ -z "${ai_overview_filter//[[:space:]]/}" ]] && continue
    [[ "$ai_overview_filter" == '!'* ]] && continue
    grep -Fqx "$ai_overview_filter" "$helium_annoyances" || printf '%s\n' "$ai_overview_filter" >> "$helium_annoyances"
  done <<< "$ai_overview_filters"
fi

tar -C "$extension_dir" -cf "$work_dir/ublock-origin.tar" .
"$adb_bin" push "$work_dir/ublock-origin.tar" /data/local/tmp/helium-ublock-origin.tar >/dev/null

"$adb_bin" shell "su -c '
set -eu
package=\"$package\"
data_dir=\$(dumpsys package \"\$package\" | sed -n \"s/.*dataDir=//p\" | head -n1)
if [ -z \"\$data_dir\" ]; then
  data_dir=\"/data/user/0/\$package\"
fi
uid=\$(cmd package list packages -U | sed -n \"s/^package:\$package uid://p\" | head -n1)
if [ -z \"\$uid\" ]; then
  echo \"Could not resolve package uid for \$package\" >&2
  exit 1
fi
ext_dir=\"\$data_dir/app_chrome/helium-extensions/ublock-origin\"
rm -rf \"\$ext_dir\"
mkdir -p \"\$ext_dir\"
tar -xf /data/local/tmp/helium-ublock-origin.tar -C \"\$ext_dir\"
rm -f /data/local/tmp/helium-ublock-origin.tar
chown -R \"\$uid:\$uid\" \"\$data_dir/app_chrome/helium-extensions\"
find \"\$data_dir/app_chrome/helium-extensions\" -type d -exec chmod 0700 {} +
find \"\$data_dir/app_chrome/helium-extensions\" -type f -exec chmod 0600 {} +
restorecon -R \"\$data_dir/app_chrome/helium-extensions\" >/dev/null 2>&1 || true
write_command_line() {
  file=\$1
  flags=\"_\"
  if [ -f \"\$file\" ]; then
    for flag in \$(cat \"\$file\"); do
      case \"\$flag\" in
        _|--load-extension=*|--disable-extensions-except=*|--extensions-on-chrome-urls|--remote-debugging-socket-name=*) continue ;;
      esac
      case \" \$flags \" in
        *\" \$flag \"*) ;;
        *) flags=\"\$flags \$flag\" ;;
      esac
    done
  fi
  flags=\"\$flags --remote-debugging-socket-name=chrome_devtools_remote --load-extension=\$ext_dir --extensions-on-chrome-urls\"
  printf \"%s\n\" \"\$flags\" >\"\$file\"
}
write_command_line /data/local/tmp/chrome-command-line
write_command_line /data/local/chrome-command-line
chmod 0644 /data/local/tmp/chrome-command-line /data/local/chrome-command-line
restorecon /data/local/tmp/chrome-command-line /data/local/chrome-command-line >/dev/null 2>&1 || true
'"

if [[ "$restart" == true ]]; then
  "$adb_bin" shell "am force-stop '$package'" >/dev/null
  "$adb_bin" shell "monkey -p '$package' 1" >/dev/null
fi

echo "Installed pinned uBlock Origin $version for $package and preserved remote debugging flags in /data/local/chrome-command-line."
