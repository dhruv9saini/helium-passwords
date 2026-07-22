#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
artifact=${1:-}
home_dir=${HOME:?HOME is required}
bin_dir=${HELIUM_LAPTOP_BIN_DIR:-$home_dir/.local/bin}
app_dir=${HELIUM_LAPTOP_APP_DIR:-$home_dir/.local/opt/helium-sync-app}
replace_default=${HELIUM_LAPTOP_REPLACE_DEFAULT:-0}

mkdir -p "$bin_dir" "$(dirname "$app_dir")"

tmp_bin=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_bin" "${app_dir}.new"
}
trap cleanup EXIT

cd "$repo_root"
go build -o "$tmp_bin/helium-sync" ./cmd/helium-sync
go build -o "$tmp_bin/helium-tabs" ./cmd/helium-tabs

install -m 0755 "$tmp_bin/helium-sync" "$bin_dir/helium-sync"
install -m 0755 "$tmp_bin/helium-tabs" "$bin_dir/helium-tabs"
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
