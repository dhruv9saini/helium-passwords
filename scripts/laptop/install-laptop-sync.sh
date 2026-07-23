#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)
home_dir=${HOME:?HOME is required}
bin_dir=${HELIUM_LAPTOP_BIN_DIR:-$home_dir/.local/bin}
app_link=${HELIUM_LAPTOP_APP_DIR:-$home_dir/.local/opt/helium-sync-app}
release_root=${HELIUM_LAPTOP_RELEASE_ROOT:-$home_dir/.local/opt/helium-sync-releases}
profile=${HELIUM_LAPTOP_PROFILE:-$home_dir/.config/net.imput.helium}
replace_default=${HELIUM_LAPTOP_REPLACE_DEFAULT:-0}

usage() {
  cat >&2 <<'EOF'
usage:
  install-laptop-sync.sh install ARTIFACT ARTIFACT-RECEIPT PROFILE-BACKUP-CONFIG PROFILE-BACKUP-RECEIPT
  install-laptop-sync.sh rollback ARTIFACT-SHA256

Install is refused unless the exact artifact has build provenance and the
stopped personal profile has two verified encrypted backup copies.  Releases
are immutable generations; rollback only switches the current symlink.
EOF
}

target_for_host() {
  case $(uname -m) in
    x86_64) echo linux-x86_64 ;;
    *) echo "Helium Sync laptop packaging currently supports x86_64 only" >&2; return 1 ;;
  esac
}

atomic_link() {
  local target=$1 link=$2 temporary
  temporary="${link}.new.$$"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$link"
}

preserve_legacy_path() {
  local path=$1 label=$2 history="$release_root/preserved" stamp target
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    return 0
  fi
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$history"
  target="$history/$label-$stamp"
  [[ ! -e "$target" ]] || { echo "preservation target exists: $target" >&2; return 1; }
  mv -- "$path" "$target"
  printf 'preserved_path=%s\n' "$target"
}

rollback_release() {
  local release_id=$1 release
  [[ "$release_id" =~ ^[a-f0-9]{64}$ ]] || { echo "rollback release must be an artifact SHA-256" >&2; exit 64; }
  release="$release_root/browser/$release_id"
  [[ -x "$release/helium" && -f "$release/.helium-artifact-receipt.env" ]] || {
    echo "verified rollback release is unavailable: $release_id" >&2
    exit 1
  }
  mkdir -p "$(dirname "$app_link")"
  preserve_legacy_path "$app_link" helium-sync-app >/dev/null
  atomic_link "$release" "$app_link"
  "$app_link/helium" --version
  printf 'rollback=activated\nartifact_sha256=%s\nrelease=%s\n' "$release_id" "$release"
}

install_release() {
  local artifact=$1 artifact_receipt=$2 backup_config=$3 backup_receipt=$4
  local admission backup_admission artifact_sha sync_commit head expected_profile_hash bundle_root
  local release staging tools tools_staging stamp desktop_dir desktop_file scripts_dir

  artifact=$(realpath -e -- "$artifact")
  artifact_receipt=$(realpath -e -- "$artifact_receipt")
  backup_config=$(realpath -e -- "$backup_config")
  backup_receipt=$(realpath -e -- "$backup_receipt")
  admission=$("$repo_root/scripts/verify-deployment-artifact-receipt.sh" \
    "$artifact" "$artifact_receipt" "$(target_for_host)")
  artifact_sha=$(awk -F= '$1 == "artifact_sha256" {print $2}' <<<"$admission")
  sync_commit=$(awk -F= '$1 == "helium_sync_commit" {print $2}' <<<"$admission")
  git -C "$repo_root" cat-file -e "$sync_commit^{commit}"
  head=$(git -C "$repo_root" rev-parse HEAD)
  git -C "$repo_root" merge-base --is-ancestor "$sync_commit" "$head" || {
    echo "artifact source commit is not in this repository history" >&2
    exit 1
  }

  backup_admission=$("$repo_root/scripts/profile-backup/helium-profile-backup.sh" \
    verify-receipt "$backup_config" "$backup_receipt")
  expected_profile_hash=$(printf '%s' "$(realpath -e -- "$profile")" | sha256sum | awk '{print $1}')
  [[ "$(awk -F= '$1 == "profile_path_sha256" {print $2}' <<<"$backup_admission")" == "$expected_profile_hash" ]] || {
    echo "profile backup receipt does not cover the configured Helium profile" >&2
    exit 1
  }

  mkdir -p "$release_root/browser" "$release_root/tools" "$release_root/preserved" \
    "$bin_dir" "$(dirname "$app_link")"
  release="$release_root/browser/$artifact_sha"
  staging="$release_root/browser/.incoming-$artifact_sha.$$"
  tools="$release_root/tools/$head"
  tools_staging="$release_root/tools/.incoming-$head.$$"
  cleanup() { rm -rf -- "$staging" "$tools_staging"; }
  trap cleanup EXIT

  if [[ ! -d "$release" ]]; then
    mkdir "$staging"
    bundle_root=helium-sync-linux-x86_64
    while IFS= read -r member; do
      case "$member" in /*|..|../*|*/../*|*/..) echo "unsafe artifact member: $member" >&2; exit 1 ;; esac
    done < <(tar -tf "$artifact")
    [[ "$(tar -tf "$artifact" | awk -F/ 'NF {print $1}' | sort -u)" == "$bundle_root" ]] || {
      echo "artifact root is not the Helium Sync x86_64 product" >&2
      exit 1
    }
    tar -xf "$artifact" -C "$staging" --strip-components=2 \
      "$bundle_root/runtime"
    missing=()
    for required in helium helium_crashpad_handler icudtl.dat resources.pak; do
      [[ -e "$staging/$required" && ! -L "$staging/$required" ]] || missing+=("$required")
    done
    [[ ${#missing[@]} -eq 0 ]] || {
      printf 'artifact is missing required Helium runtime files: %s\n' "${missing[*]}" >&2
      exit 1
    }
    chmod 0755 "$staging/helium" "$staging/helium_crashpad_handler"
    install -m 0600 "$artifact_receipt" "$staging/.helium-artifact-receipt.env"
    mv "$staging" "$release"
  else
    [[ -x "$release/helium" && -f "$release/.helium-artifact-receipt.env" ]] || {
      echo "existing release generation is incomplete" >&2
      exit 1
    }
    cmp "$artifact_receipt" "$release/.helium-artifact-receipt.env"
  fi

  if [[ ! -d "$tools" ]]; then
    git -C "$repo_root" diff --quiet && git -C "$repo_root" diff --cached --quiet || {
      echo "refusing to build deployment tools from a dirty repository" >&2
      exit 1
    }
    mkdir "$tools_staging"
    (cd "$repo_root" && go build -o "$tools_staging/helium-sync" ./cmd/helium-sync)
    (cd "$repo_root" && go build -o "$tools_staging/helium-tabs" ./cmd/helium-tabs)
    install -m 0755 "$repo_root/scripts/laptop/start-helium-sync-local.sh" "$tools_staging/start-helium-sync-local"
    cat >"$tools_staging/helium-sync-browser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "${HOME:?HOME is required}/.local/bin/start-helium-sync-local" "$@"
EOF
    chmod 0755 "$tools_staging/helium-sync-browser"
    mv "$tools_staging" "$tools"
  fi

  preserve_legacy_path "$app_link" helium-sync-app >/dev/null
  atomic_link "$release" "$app_link"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$release_root/preserved/bin-$stamp"
  for name in helium-sync helium-tabs start-helium-sync-local helium-sync-browser; do
    [[ ! -e "$bin_dir/$name" && ! -L "$bin_dir/$name" ]] || mv "$bin_dir/$name" "$release_root/preserved/bin-$stamp/$name"
    atomic_link "$tools/$name" "$bin_dir/$name"
  done

  if [[ "$replace_default" == 1 ]]; then
    scripts_dir="$home_dir/.config/scripts"
    mkdir -p "$scripts_dir"
    [[ ! -e "$scripts_dir/helium-browser" && ! -L "$scripts_dir/helium-browser" ]] || \
      mv "$scripts_dir/helium-browser" "$release_root/preserved/helium-browser-$stamp"
    atomic_link "$tools/helium-sync-browser" "$scripts_dir/helium-browser"
  fi

  desktop_dir=${XDG_DATA_HOME:-$home_dir/.local/share}/applications
  desktop_file=$desktop_dir/helium-sync.desktop
  mkdir -p "$desktop_dir"
  [[ ! -e "$desktop_file" ]] || mv "$desktop_file" "$release_root/preserved/helium-sync.desktop-$stamp"
  cat >"$desktop_file.new.$$" <<EOF
[Desktop Entry]
Name=Helium Sync
Exec=$bin_dir/helium-sync-browser %U
Terminal=false
Type=Application
Icon=helium
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;
EOF
  mv "$desktop_file.new.$$" "$desktop_file"
  "$app_link/helium" --version
  trap - EXIT
  printf 'install=activated\nartifact_sha256=%s\nrelease=%s\nprofile_backup_generation=%s\n' \
    "$artifact_sha" "$release" "$(awk -F= '$1 == "generation" {print $2}' <<<"$backup_admission")"
}

case ${1:-} in
  install) [[ $# -eq 5 ]] || { usage; exit 64; }; install_release "$2" "$3" "$4" "$5" ;;
  rollback) [[ $# -eq 2 ]] || { usage; exit 64; }; rollback_release "$2" ;;
  *) usage; exit 64 ;;
esac
