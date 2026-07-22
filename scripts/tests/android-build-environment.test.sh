#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../chromium/android-build.lock
. "$repo_root/chromium/android-build.lock"
test_root=$(mktemp -d /tmp/helium-android-environment-test.XXXXXX)
cleanup() { find "$test_root" -depth -delete; }
trap cleanup EXIT

cat > "$test_root/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/00000000000000000000000000000000-helium-chromium-150-env
closure_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
closure_bytes=10737418240
chromium_commit=$HELIUM_ANDROID_CHROMIUM_COMMIT
nixpkgs_commit=$HELIUM_ANDROID_NIXPKGS_COMMIT
nix_version=nix (Nix) 2.33.0
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

echo 'Android build environment provenance passed'
