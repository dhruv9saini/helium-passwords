#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
action=${1:-}
state_arg=${2:-}

[[ "$action" == begin || "$action" == verify ]] && [[ $# -eq 2 ]] || {
  echo "usage: $0 begin|verify ABSOLUTE_STATE_DIRECTORY" >&2
  exit 64
}
[[ "$state_arg" == /* ]] || {
  echo "Serve acceptance state directory must be absolute" >&2
  exit 64
}
state=$(realpath -m "$state_arg")
[[ "$state" == "$state_arg" ]] || {
  echo "Serve acceptance state directory must be canonical" >&2
  exit 1
}

capture_config() {
  local output=$1 temporary
  temporary=$(mktemp "$(dirname "$output")/.serve-config.XXXXXX")
  tailscale serve status --json | jq -S -c . >"$temporary"
  "$repo_root/scripts/verify-tailnet-exposure.sh" "$temporary" >/dev/null
  chmod 0400 "$temporary"
  mv -T "$temporary" "$output"
}

metadata() {
  local file=$1 key=$2 value
  value=$(sed -n "s/^${key}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${key}=" "$file")" -eq 1 ]] || {
    echo "Serve acceptance metadata is missing unique $key" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

case "$action" in
  begin)
    [[ ! -e "$state" && ! -L "$state" ]] || {
      echo "Serve acceptance state already exists" >&2
      exit 1
    }
    parent=$(dirname "$state")
    install -d -m0700 "$parent"
    mkdir -m0700 "$state"
    cleanup_begin() {
      [[ ! -e "$state" ]] || find "$state" -depth -delete
    }
    trap cleanup_begin EXIT
    capture_config "$state/serve-before.json"
    config_sha=$(sha256sum "$state/serve-before.json" | cut -d' ' -f1)
    helper_sha=$(sha256sum "$repo_root/scripts/verify-tailnet-exposure.sh" | cut -d' ' -f1)
    temporary=$(mktemp "$state/.begin.XXXXXX")
    {
      printf 'schema_version=1\n'
      printf 'sync_port=44719\n'
      printf 'serve_config_sha256=%s\n' "$config_sha"
      printf 'exposure_verifier_sha256=%s\n' "$helper_sha"
      printf 'began_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary"
    chmod 0400 "$temporary"
    mv -T "$temporary" "$state/begin.env"
    trap - EXIT
    printf 'serve_gate=%s\n' "$state"
    printf 'serve_config_sha256=%s\n' "$config_sha"
    ;;
  verify)
    [[ -d "$state" && ! -L "$state" && "$(stat -c %a "$state")" == 700 &&
        -f "$state/serve-before.json" && ! -L "$state/serve-before.json" &&
        "$(stat -c %a "$state/serve-before.json")" == 400 &&
        -f "$state/begin.env" && ! -L "$state/begin.env" &&
        "$(stat -c %a "$state/begin.env")" == 400 &&
        ! -e "$state/receipt.env" ]] || {
      echo "Serve acceptance state is incomplete, unsafe, or already verified" >&2
      exit 1
    }
    [[ "$(metadata "$state/begin.env" schema_version)" == 1 &&
        "$(metadata "$state/begin.env" sync_port)" == 44719 ]] || {
      echo "Serve acceptance begin metadata is incompatible" >&2
      exit 1
    }
    before_sha=$(sha256sum "$state/serve-before.json" | cut -d' ' -f1)
    [[ "$before_sha" == "$(metadata "$state/begin.env" serve_config_sha256)" &&
        "$(sha256sum "$repo_root/scripts/verify-tailnet-exposure.sh" | cut -d' ' -f1)" == \
          "$(metadata "$state/begin.env" exposure_verifier_sha256)" ]] || {
      echo "Serve acceptance begin evidence or verifier changed" >&2
      exit 1
    }
    capture_config "$state/serve-after.json"
    after_sha=$(sha256sum "$state/serve-after.json" | cut -d' ' -f1)
    if [[ "$after_sha" != "$before_sha" ]] ||
       ! cmp -s "$state/serve-before.json" "$state/serve-after.json"; then
      echo "Tailscale Serve configuration changed during acceptance" >&2
      exit 1
    fi
    temporary=$(mktemp "$state/.receipt.XXXXXX")
    {
      printf 'schema_version=1\n'
      printf 'result=passed\n'
      printf 'sync_port=44719\n'
      printf 'before_serve_config_sha256=%s\n' "$before_sha"
      printf 'after_serve_config_sha256=%s\n' "$after_sha"
      printf 'exposure_verifier_sha256=%s\n' \
        "$(metadata "$state/begin.env" exposure_verifier_sha256)"
      printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$temporary"
    chmod 0400 "$temporary"
    mv -T "$temporary" "$state/receipt.env"
    printf 'serve_receipt=%s\n' "$state/receipt.env"
    printf 'serve_receipt_sha256=%s\n' \
      "$(sha256sum "$state/receipt.env" | cut -d' ' -f1)"
    ;;
esac
