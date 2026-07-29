#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d /tmp/helium-android-environment-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT
nix_source_sha256=$(sha256sum "$repo_root/chromium/nix/chromiumer-shell.nix" | awk '{ print $1 }')
environment_script="$repo_root/scripts/chromium/android-build-environment.sh"

grep -Fq "[[ \"\${HELIUM_BUILD_JOBS:-}\" == 1 ]]" "$environment_script"
grep -Fq 'Android build must inherit HELIUM_BUILD_JOBS=1' "$environment_script"
if grep -Fq 'Android build must inherit HELIUM_BUILD_JOBS=2' "$environment_script"; then
  echo "stale two-job Android build environment policy survived" >&2
  exit 1
fi

cat > "$test_root/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/00000000000000000000000000000000-helium-chromium-150-env
closure_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
closure_bytes=10737418240
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
nixpkgs_commit=$HELIUM_ANDROID_NIXPKGS_COMMIT
nix_version=nix (Nix) 2.33.0
environment_source_sha256=$nix_source_sha256
nix_derivation=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-helium-chromium-150-env.drv
grit_disable_multiprocessing=1
root_start_available_bytes=139586437120
root_end_available_bytes=118111600640
realise_consumed_bytes=21474836480
realise_budget_bytes=21474836480
post_realise_floor_bytes=107374182400
realise_start_gate_bytes=128849018880
EOF
printf 'bash scripts/chromium/build-android-ci.sh \n' > "$test_root/build-command.txt"

"$repo_root/scripts/chromium/android-build-environment.sh" verify "$test_root"

sed -i 's/realise_start_gate_bytes=128849018880/realise_start_gate_bytes=128849018879/' \
  "$test_root/chromiumer-nix.env"
if "$repo_root/scripts/chromium/android-build-environment.sh" verify "$test_root" \
  > "$test_root/rejected.out" 2>&1; then
  echo "inconsistent Chromiumer capacity arithmetic unexpectedly passed" >&2
  exit 1
fi
grep -q 'capacity arithmetic' "$test_root/rejected.out"
sed -i 's/realise_start_gate_bytes=128849018879/realise_start_gate_bytes=128849018880/' \
  "$test_root/chromiumer-nix.env"

sed -i 's/grit_disable_multiprocessing=1/grit_disable_multiprocessing=0/' \
  "$test_root/chromiumer-nix.env"
if "$repo_root/scripts/chromium/android-build-environment.sh" verify "$test_root" \
  > "$test_root/rejected-grit.out" 2>&1; then
  echo "parallel GRIT provenance unexpectedly passed" >&2
  exit 1
fi
grep -q 'GRIT serialization provenance' "$test_root/rejected-grit.out"
sed -i 's/grit_disable_multiprocessing=0/grit_disable_multiprocessing=1/' \
  "$test_root/chromiumer-nix.env"

sed -i "s/environment_source_sha256=$nix_source_sha256/environment_source_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" \
  "$test_root/chromiumer-nix.env"
if "$repo_root/scripts/chromium/android-build-environment.sh" verify "$test_root" \
  > "$test_root/rejected-source.out" 2>&1; then
  echo "foreign Chromiumer Nix expression hash unexpectedly passed" >&2
  exit 1
fi
grep -q 'expression hash does not match' "$test_root/rejected-source.out"
sed -i "s/environment_source_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/environment_source_sha256=$nix_source_sha256/" \
  "$test_root/chromiumer-nix.env"

sed -i 's#nix_derivation=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-helium-chromium-150-env.drv#nix_derivation=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-foreign-env.drv#' \
  "$test_root/chromiumer-nix.env"
if "$repo_root/scripts/chromium/android-build-environment.sh" verify "$test_root" \
  > "$test_root/rejected-derivation.out" 2>&1; then
  echo "foreign Chromiumer Nix derivation unexpectedly passed" >&2
  exit 1
fi
grep -q 'derivation path is invalid' "$test_root/rejected-derivation.out"

echo 'Android build environment provenance passed'
