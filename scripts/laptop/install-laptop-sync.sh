#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
artifact=${1:-}
home_dir=${HOME:?HOME is required}
bin_dir=${HELIUM_LAPTOP_BIN_DIR:-$home_dir/.local/bin}
app_dir=${HELIUM_LAPTOP_APP_DIR:-$home_dir/.local/opt/helium-sync-app}
profile=${HELIUM_LAPTOP_PROFILE:-$home_dir/.config/net.imput.helium}
replace_default=${HELIUM_LAPTOP_REPLACE_DEFAULT:-0}

mkdir -p "$bin_dir" "$(dirname "$app_dir")"

tmp_bin=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_bin" "${app_dir}.new"
}
trap cleanup EXIT

cd "$repo_root"
go build -o "$tmp_bin/helium-sync" ./cmd/helium-sync
go build -o "$tmp_bin/helium-syncd" ./cmd/helium-syncd
go build -o "$tmp_bin/helium-local-syncd" ./cmd/helium-local-syncd

install -m 0755 "$tmp_bin/helium-sync" "$bin_dir/helium-sync"
install -m 0755 "$tmp_bin/helium-syncd" "$bin_dir/helium-syncd"
install -m 0755 "$tmp_bin/helium-local-syncd" "$bin_dir/helium-local-syncd"
install -m 0755 "$repo_root/scripts/android-local/cdp-cookiecloud.mjs" "$bin_dir/cdp-cookiecloud"
install -m 0755 "$repo_root/scripts/android-local/cdp-password-sync.mjs" "$bin_dir/cdp-password-sync"
install -m 0644 "$repo_root/scripts/android-local/password-reconcile.mjs" "$bin_dir/password-reconcile.mjs"
install -m 0755 "$repo_root/scripts/laptop/start-helium-sync-local.sh" "$bin_dir/start-helium-sync-local"

if [[ -n "$artifact" ]]; then
  rm -rf "${app_dir}.new"
  mkdir -p "${app_dir}.new"
  tar -xf "$artifact" -C "${app_dir}.new"
  missing=()
  for required in helium helium_crashpad_handler icudtl.dat resources.pak; do
    [[ -e "${app_dir}.new/$required" ]] || missing+=("$required")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'artifact is missing required Helium runtime files: %s\n' "${missing[*]}" >&2
    printf 'use a packaged helium-linux tarball, not a minimal staging archive\n' >&2
    exit 1
  fi
  rm -rf "${app_dir}.previous"
  if [[ -d "$app_dir" ]]; then
    mv "$app_dir" "${app_dir}.previous"
  fi
  mv "${app_dir}.new" "$app_dir"
fi

cat >"$bin_dir/helium-sync-browser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "${HOME:?HOME is required}/.local/bin/start-helium-sync-local" "$@"
EOF
chmod 0755 "$bin_dir/helium-sync-browser"

if [[ "$replace_default" == 1 ]]; then
  scripts_dir="$home_dir/.config/scripts"
  mkdir -p "$scripts_dir"
  if [[ -e "$scripts_dir/helium-browser" && ! -e "$scripts_dir/helium-browser.pre-helium-sync" ]]; then
    cp -a "$scripts_dir/helium-browser" "$scripts_dir/helium-browser.pre-helium-sync"
  fi
  cat >"$scripts_dir/helium-browser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "${HOME:?HOME is required}/.local/bin/start-helium-sync-local" "$@"
EOF
  chmod 0755 "$scripts_dir/helium-browser"
fi

"$bin_dir/helium-sync" init >/dev/null
mkdir -p "$profile/Default/helium-sync"
cp "$home_dir/.local/share/helium-sync/token" "$profile/Default/helium-sync/token"
printf '%s\n' "${HELIUM_PASSWORD_SYNC_BASE_URL:-http://127.0.0.1:44719}" >"$profile/Default/helium-sync/base_url"
printf '%s\n' "${HELIUM_SYNC_DEVICE_NAME:-helium-laptop}" >"$profile/Default/helium-sync/device_name"
chmod 0600 "$profile/Default/helium-sync/token" "$profile/Default/helium-sync/base_url" "$profile/Default/helium-sync/device_name"

"$bin_dir/start-helium-sync-local" --services-only

desktop_dir=${XDG_DATA_HOME:-$home_dir/.local/share}/applications
mkdir -p "$desktop_dir"
cat >"$desktop_dir/helium-sync.desktop" <<EOF
[Desktop Entry]
Name=Helium Sync
Exec=$bin_dir/helium-sync-browser %U
Terminal=false
Type=Application
Icon=helium
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;
EOF
