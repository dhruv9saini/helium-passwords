#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
patch_file="$repo_root/patches/helium-passwords/onboarding-node22-typescript.patch"

grep -qx 'helium-passwords/onboarding-node22-typescript.patch' \
  "$repo_root/patches/series"
grep -Fq 'diff --git a/components/helium_onboarding/BUILD.gn' "$patch_file"
grep -Fq '+        "--experimental-strip-types",' "$patch_file"
grep -Fq 'rebase_path("util/generate-i18n.mts", root_build_dir)' "$patch_file"

echo 'Node 22 onboarding TypeScript runner patch passed'
