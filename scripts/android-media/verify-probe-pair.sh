#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 SYNC_ACCEPTANCE SYNC_EVIDENCE CONTROL_ACCEPTANCE CONTROL_EVIDENCE NEW_RECEIPT" >&2
  exit 64
fi

sync_acceptance=$(realpath "$1")
sync_evidence=$(realpath "$2")
control_acceptance=$(realpath "$3")
control_evidence=$(realpath "$4")
receipt=$(realpath -m "$5")

command -v jq >/dev/null
command -v sha256sum >/dev/null
[[ ! -e "$receipt" && ! -L "$receipt" ]] || {
  echo "pair receipt already exists" >&2
  exit 1
}

metadata() {
  local file=$1
  local name=$2
  local value
  value=$(sed -n "s/^${name}=//p" "$file")
  [[ -n "$value" && "$(grep -c "^${name}=" "$file")" -eq 1 ]] || {
    echo "$file is missing unique $name" >&2
    exit 1
  }
  printf '%s\n' "$value"
}

verify_generation() {
  local acceptance=$1
  local evidence=$2
  local expected_package=$3
  local expected_socket=$4
  local acceptance_env="$acceptance/acceptance.env"
  local evidence_env="$evidence/acceptance.env"
  local actions="$evidence/actions.env"
  local result="$evidence/result.json"
  local package apk_sha chromium_commit sync_commit version_code version_name

  [[ -f "$acceptance/PACKAGE_SHA256SUMS" && -f "$evidence/EVIDENCE_SHA256SUMS" &&
      -f "$acceptance_env" && -f "$evidence_env" && -f "$actions" && -f "$result" &&
      -f "$evidence/fixture-provenance.json" &&
      -f "$acceptance/runtime-acceptance/SHA256SUMS" ]] || {
    echo "acceptance or evidence generation is incomplete" >&2
    exit 1
  }
  (cd "$acceptance" && sha256sum -c PACKAGE_SHA256SUMS >/dev/null)
  (cd "$evidence" && sha256sum -c EVIDENCE_SHA256SUMS >/dev/null)
  cmp -s "$acceptance_env" "$evidence_env" || {
    echo "device evidence is not bound to its acceptance generation" >&2
    exit 1
  }

  package=$(metadata "$acceptance_env" package)
  apk_sha=$(metadata "$acceptance_env" apk_sha256)
  chromium_commit=$(metadata "$acceptance_env" chromium_commit)
  sync_commit=$(metadata "$acceptance_env" helium_sync_commit)
  version_code=$(metadata "$acceptance_env" version_code)
  version_name=$(metadata "$acceptance_env" version_name)
  [[ "$package" == "$expected_package" && "$apk_sha" =~ ^[0-9a-f]{64}$ &&
      "$chromium_commit" =~ ^[0-9a-f]{40}$ && "$sync_commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "acceptance generation has the wrong role or invalid source identity" >&2
    exit 1
  }
  [[ "$(metadata "$acceptance_env" runtime_kit_sha256)" == \
      "$(sha256sum "$acceptance/runtime-acceptance/SHA256SUMS" | cut -d' ' -f1)" ]] || {
    echo "acceptance metadata does not identify its runtime kit" >&2
    exit 1
  }
  [[ "$(metadata "$actions" package)" == "$package" &&
      "$(metadata "$actions" installed_apk_sha256)" == "$apk_sha" &&
      "$(metadata "$actions" device_socket)" == "$expected_socket" &&
      "$(metadata "$actions" version_code)" == "$version_code" &&
      "$(metadata "$actions" version_name)" == "$version_name" &&
      "$(metadata "$actions" background_foreground)" == true &&
      "$(metadata "$actions" network_handoff)" == wifi-to-cellular ]] || {
    echo "device actions do not prove the full admitted lifecycle gate" >&2
    exit 1
  }

  jq -e \
    --arg package "$package" \
    --arg apk "$apk_sha" \
    --arg chromium "$chromium_commit" \
    --arg sync "$sync_commit" \
    --arg socket "$expected_socket" '
      .runtime.android_package == $package and
      .runtime.artifact_sha256 == $apk and
      .runtime.chromium_commit == $chromium and
      .runtime.helium_sync_commit == $sync and
      .runtime.device_socket == $socket and
      .required_transport_protocols == ["h2", "h3"] and
      .required_lifecycle == {"background_foreground":true,"network_handoff":true} and
      .service_worker.supported == true and
      .service_worker.controlled == true and
      .service_worker.script_url == "/service-worker.js" and
      (.drm.widevine.api_available | type) == "boolean" and
      (.drm.widevine.key_system_available | type) == "boolean" and
      .drm.widevine.key_system == "com.widevine.alpha"
    ' "$result" >/dev/null || {
    echo "probe result is not source-bound full Android evidence" >&2
    exit 1
  }

  local fixture_sha
  fixture_sha=$(sha256sum "$evidence/fixture-provenance.json" | cut -d' ' -f1)
  [[ "$(metadata "$actions" fixture_receipt_sha256)" == "$fixture_sha" ]] || {
    echo "fixture receipt is not bound to the device actions" >&2
    exit 1
  }
}

verify_generation \
  "$sync_acceptance" "$sync_evidence" \
  computer.helium.sync.test helium_sync_test_devtools_remote
verify_generation \
  "$control_acceptance" "$control_evidence" \
  computer.helium.control.test helium_control_test_devtools_remote

for name in fixture-server.mjs generate-fixtures.sh run-cdp-probe.mjs \
  run-device-probe.sh verify-probe-pair.sh; do
  cmp -s "$sync_acceptance/runtime-acceptance/$name" \
    "$control_acceptance/runtime-acceptance/$name" || {
    echo "Sync and control used different acceptance code: $name" >&2
    exit 1
  }
done

sync_env="$sync_acceptance/acceptance.env"
control_env="$control_acceptance/acceptance.env"
for name in helium_sync_commit chromium_commit version_code version_name; do
  [[ "$(metadata "$sync_env" "$name")" == "$(metadata "$control_env" "$name")" ]] || {
    echo "Sync and control do not share $name" >&2
    exit 1
  }
done

cmp -s "$sync_evidence/fixture-provenance.json" \
  "$control_evidence/fixture-provenance.json" || {
  echo "Sync and control did not use the same protocol fixture generation" >&2
  exit 1
}
sync_media=$(jq -cS '.media_manifest' "$sync_evidence/result.json")
control_media=$(jq -cS '.media_manifest' "$control_evidence/result.json")
[[ "$sync_media" == "$control_media" ]] || {
  echo "Sync and control did not exercise byte-identical media fixtures" >&2
  exit 1
}

receipt_parent=$(dirname "$receipt")
mkdir -p "$receipt_parent"
temporary=$(mktemp "$receipt_parent/.helium-media-pair.XXXXXX")
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT
chmod 600 "$temporary"
{
  printf 'schema_version=1\n'
  printf 'helium_sync_commit=%s\n' "$(metadata "$sync_env" helium_sync_commit)"
  printf 'chromium_commit=%s\n' "$(metadata "$sync_env" chromium_commit)"
  printf 'sync_archive_sha256=%s\n' "$(metadata "$sync_env" source_archive_sha256)"
  printf 'sync_apk_sha256=%s\n' "$(metadata "$sync_env" apk_sha256)"
  printf 'sync_result_sha256=%s\n' "$(sha256sum "$sync_evidence/result.json" | cut -d' ' -f1)"
  printf 'control_archive_sha256=%s\n' "$(metadata "$control_env" source_archive_sha256)"
  printf 'control_apk_sha256=%s\n' "$(metadata "$control_env" apk_sha256)"
  printf 'control_result_sha256=%s\n' "$(sha256sum "$control_evidence/result.json" | cut -d' ' -f1)"
  printf 'fixture_receipt_sha256=%s\n' \
    "$(sha256sum "$sync_evidence/fixture-provenance.json" | cut -d' ' -f1)"
  printf 'media_manifest_sha256=%s\n' "$(printf '%s' "$sync_media" | sha256sum | cut -d' ' -f1)"
  printf 'verified_at=%s\n' "$(date --iso-8601=seconds)"
} > "$temporary"
ln "$temporary" "$receipt"
rm "$temporary"
trap - EXIT
printf 'pair_receipt=%s\n' "$receipt"
printf 'pair_receipt_sha256=%s\n' "$(sha256sum "$receipt" | cut -d' ' -f1)"
