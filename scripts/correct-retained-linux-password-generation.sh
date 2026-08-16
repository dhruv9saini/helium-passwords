#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/correct-retained-linux-password-generation.sh PRODUCT ARCH TARGET ARTIFACT-JOB BASELINE-BUILD-JOB BASELINE-RETURN-JOB
EOF
}

[[ $# -eq 6 ]] || {
  usage
  exit 2
}

product=$1
arch=$2
target=$3
artifact_job=$4
baseline_build_job=$5
baseline_return_job=$6
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_root=${HELIUM_CHROMIUMER_STATE_ROOT:-/home/d/.local/state/helium-builds}
work_root=${HELIUM_CHROMIUMER_WORK_ROOT:-/home/d/helium-builds/work}
expected_baseline_commit=77ecad17303225cbfdf9043a4bab040f411402b7
expected_baseline_tree=f434ae597adc7a4bb297a79e985785c39107e80b
expected_chromium_commit=24b04c927b23c39cf9c5227cc8dc6f64a744c8e9
expected_core_commit=81bb0219ad6df2adefd12f42ca79198f049f1497
expected_platform_commit=9fbdff55283c9275f285c49dc054a1ff38dcdc96
expected_patch_sha256=64e81e3a1315b831f1aa1cb4da54b78bf2082bef7da72c894a9f2f7c29249383
expected_before_sha256=35d0a50bcb4f5eeb86a56133d80f8500c49b8691c7e955c9236753e98c5037a9
expected_after_sha256=fb547a2df142dbe6ae5838fcfa172e86b966214e869e6cbe4f876f6e4cb399d0
patch_relative=patches/helium-passwords/enable-password-generation-without-google-sync.patch
target_relative=components/password_manager/core/browser/password_feature_manager_impl.cc
series_entry=helium/passwords/enable-password-generation-without-google-sync.patch
restore_entry=helium/passwords/restore-password-autofill.patch

[[ "${product}" == helium-passwords && "${arch}" == x86_64 &&
    "${target}" == linux-x86_64 ]] || {
  echo "correction requires the public x86_64 Linux Passwords target" >&2
  exit 2
}
for job in "${artifact_job}" "${baseline_build_job}" "${baseline_return_job}"; do
  [[ "${job}" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || {
    echo "invalid correction job: ${job}" >&2
    exit 2
  }
done
[[ "${artifact_job}" != "${baseline_build_job}" &&
    "${artifact_job}" != "${baseline_return_job}" &&
    "${baseline_build_job}" != "${baseline_return_job}" ]] || {
  echo "correction jobs must be distinct" >&2
  exit 2
}

exact_value() {
  local file=$1
  local key=$2
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  awk -F= -v key="${key}" '
    $1 == key { count++; value=substr($0,length(key)+2) }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "${file}"
}

workspace_owner() {
  local job=$1
  local stage="${state_root}/${job}/stage.env"
  [[ -f "${stage}" && ! -L "${stage}" ]] || return 1
  exact_value "${stage}" workspace_owner
}

require_contained() {
  local path=$1
  local root=$2
  case "${path}" in
    "${root}"/*) ;;
    *) echo "path is outside its admitted root: ${path}" >&2; exit 1 ;;
  esac
}

require_hash() {
  local file=$1
  local expected=$2
  [[ -f "${file}" && ! -L "${file}" &&
      "$(sha256sum "${file}" | awk '{print $1}')" == "${expected}" ]] || {
    echo "file hash mismatch: ${file}" >&2
    exit 1
  }
}

[[ "$(uname -n | cut -d. -f1)" == chromiumer ]] || {
  echo "correction runs only on chromiumer" >&2
  exit 1
}
for variable in HELIUM_BUILD_JOBS AUTONINJA_JOBS NINJA_JOBS GCLIENT_JOBS; do
  [[ "${!variable:-}" == 1 ]] || {
    echo "correction requires ${variable}=1" >&2
    exit 1
  }
done
[[ "${HELIUM_LINUX_PHASE:-}" == retained &&
    "${CCC_OVERRIDE_OPTIONS:-}" == '# +-Wl,--threads=1' ]] || {
  echo "correction requires its exact retained single-thread linker environment" >&2
  exit 1
}
grep -Eq '/helium-job-[a-z0-9-]+\.service(/|$)' /proc/self/cgroup || {
  echo "correction is outside an isolated Helium cgroup" >&2
  exit 1
}

artifact_state="${state_root}/${artifact_job}"
artifact_owner=$(workspace_owner "${artifact_job}") || {
  echo "artifact job has no safe staged owner" >&2
  exit 1
}
[[ "${artifact_owner}" == "${artifact_job}" ]] || {
  echo "artifact job must own its staged source" >&2
  exit 1
}
admitted_root=$(realpath -e "${work_root}/${artifact_owner}/source")
[[ "$(realpath -e "${root_dir}")" == "${admitted_root}" &&
    "${TMPDIR:-}" == "${work_root}/${artifact_owner}/tmp" ]] || {
  echo "correction source or temporary directory left the artifact workspace" >&2
  exit 1
}

baseline_owner=$(workspace_owner "${baseline_build_job}") || {
  echo "baseline build job has no safe staged owner" >&2
  exit 1
}
[[ "$(workspace_owner "${baseline_return_job}")" == "${baseline_owner}" &&
    "${baseline_owner}" != "${artifact_owner}" ]] || {
  echo "baseline jobs do not share one separate retained workspace" >&2
  exit 1
}
baseline_root=$(realpath -e "${work_root}/${baseline_owner}/source")
require_contained "${baseline_root}" "$(realpath -e "${work_root}")"
checkout=$(realpath -e "${baseline_root}/build/platforms/linux")
source_root=$(realpath -e "${checkout}/build/src")
out=$(realpath -e "${source_root}/out/Default")
target_file="${source_root}/${target_relative}"
overlay_patch="${checkout}/patches/helium/passwords/$(basename "${patch_relative}")"
platform_series="${checkout}/patches/series"
patch_file="${root_dir}/${patch_relative}"
baseline_artifact="${baseline_root}/.build/artifacts/${product}-linux-${arch}.tar.xz"
baseline_receipt="${baseline_root}/.build/artifacts/${product}-linux-${arch}.receipt.env"
baseline_graph="${baseline_root}/.build/artifacts/${product}-linux-${arch}.full-graph"
baseline_boundary="${state_root}/${baseline_build_job}/full-graph-boundary.env"
baseline_returned="${state_root}/${baseline_return_job}/artifact-returned.env"
baseline_terminal="${state_root}/${baseline_return_job}/terminal.env"
intent="${artifact_state}/password-generation-correction-intent.env"
preflight="${artifact_state}/password-generation-correction-preflight.env"
boundary="${artifact_state}/full-graph-boundary.env"
artifact_dir="${root_dir}/.build/artifacts"
artifact="${artifact_dir}/${product}-linux-${arch}.tar.xz"
receipt="${artifact_dir}/${product}-linux-${arch}.receipt.env"
full_graph="${artifact_dir}/${product}-linux-${arch}.full-graph"

for required in "${target_file}" "${platform_series}" "${baseline_artifact}" \
    "${baseline_receipt}" "${baseline_boundary}" "${baseline_terminal}" \
    "${baseline_returned}" "${baseline_graph}/receipt.env" \
    "${baseline_graph}/SHA256SUMS"; do
  [[ -e "${required}" && ! -L "${required}" ]] || {
    echo "missing or unsafe correction input: ${required}" >&2
    exit 1
  }
done
[[ -d "${baseline_graph}" && ! -L "${baseline_graph}" ]] || {
  echo "baseline full-graph evidence is unsafe" >&2
  exit 1
}
[[ "$(stat -c %a "${baseline_boundary}")" == 400 &&
    "$(exact_value "${baseline_terminal}" state)" == terminal &&
    "$(exact_value "${baseline_terminal}" result)" == success &&
    "$(exact_value "${baseline_terminal}" exit_code)" == 0 ]] || {
  echo "baseline build return is not an exact terminal success" >&2
  exit 1
}
systemctl --user --quiet is-active "helium-job-${baseline_return_job}.service" && {
  echo "baseline return job is still active" >&2
  exit 1
}

source_info=$("${root_dir}/scripts/linux-product-provenance.sh" \
  "${product}" "${arch}" "${target}")
source_value() {
  awk -F= -v key="$1" \
    '$1 == key {count++; value=substr($0,length(key)+2)}
     END {if (count == 1 && value != "") print value; else exit 1}' \
    <<<"${source_info}"
}
corrected_commit=$(source_value source_commit)
corrected_tree=$(source_value source_tree)
[[ "${corrected_commit}" == "$(git -C "${root_dir}" rev-parse HEAD)" &&
    "${corrected_tree}" == "$(git -C "${root_dir}" rev-parse 'HEAD^{tree}')" &&
    "${corrected_commit}" != "${expected_baseline_commit}" &&
    "$(source_value chromium_commit)" == "${expected_chromium_commit}" &&
    "$(source_value helium_core_commit)" == "${expected_core_commit}" &&
    -z "$(git -C "${root_dir}" status --porcelain --untracked-files=all)" ]] || {
  echo "corrected product source is not clean or provenance-bound" >&2
  exit 1
}
artifact_manifest="${artifact_state}/source.manifest"
[[ "$(exact_value "${artifact_manifest}" commit)" == "${corrected_commit}" &&
    "$(exact_value "${artifact_manifest}" tree)" == "${corrected_tree}" &&
    "$(exact_value "${artifact_manifest}" helium_submodule)" == \
      "${expected_core_commit}" ]] || {
  echo "artifact source manifest does not match the corrected source" >&2
  exit 1
}

baseline_manifest="${state_root}/${baseline_owner}/source.manifest"
[[ "$(exact_value "${baseline_manifest}" commit)" == \
      "${expected_baseline_commit}" &&
    "$(exact_value "${baseline_manifest}" tree)" == "${expected_baseline_tree}" &&
    "$(exact_value "${baseline_manifest}" helium_submodule)" == \
      "${expected_core_commit}" &&
    "$(git -C "${baseline_root}" rev-parse HEAD)" == \
      "${expected_baseline_commit}" &&
    "$(git -C "${baseline_root}" rev-parse 'HEAD^{tree}')" == \
      "${expected_baseline_tree}" &&
    -z "$(git -C "${baseline_root}" status --porcelain --untracked-files=no)" &&
    "$(git -C "${checkout}" rev-parse HEAD)" == "${expected_platform_commit}" &&
    "$(git -C "${checkout}/helium-chromium" rev-parse HEAD)" == \
      "${expected_core_commit}" &&
    "$(git -C "${source_root}" rev-parse HEAD)" == \
      "${expected_chromium_commit}" ]] || {
  echo "baseline retained source identity changed" >&2
  exit 1
}

[[ "$(git -C "${root_dir}" remote get-url origin)" == \
    https://github.com/dhruv9saini/helium-passwords.git ]] || {
  echo "corrected source has an unexpected public origin" >&2
  exit 1
}
git -C "${root_dir}" fetch --quiet --no-tags --depth=64 \
  origin "${corrected_commit}"
git -C "${root_dir}" merge-base --is-ancestor \
  "${expected_baseline_commit}" "${corrected_commit}" || {
  echo "corrected source is not a descendant of the baseline source" >&2
  exit 1
}

require_hash "${patch_file}" "${expected_patch_sha256}"
baseline_artifact_sha256=$(sha256sum "${baseline_artifact}" | awk '{print $1}')
baseline_receipt_sha256=$(sha256sum "${baseline_receipt}" | awk '{print $1}')
baseline_boundary_sha256=$(sha256sum "${baseline_boundary}" | awk '{print $1}')
baseline_graph_receipt_sha256=$(sha256sum \
  "${baseline_graph}/receipt.env" | awk '{print $1}')
[[ "$(exact_value "${baseline_returned}" sha256)" == \
      "${baseline_artifact_sha256}" &&
    "$(exact_value "${baseline_receipt}" artifact_sha256)" == \
      "${baseline_artifact_sha256}" &&
    "$(exact_value "${baseline_receipt}" build_job_id)" == \
      "${baseline_build_job}" &&
    "$(exact_value "${baseline_receipt}" helium_passwords_commit)" == \
      "${expected_baseline_commit}" &&
    "$(exact_value "${baseline_receipt}" chromium_commit)" == \
      "${expected_chromium_commit}" &&
    "$(exact_value "${baseline_receipt}" full_graph_receipt_sha256)" == \
      "${baseline_graph_receipt_sha256}" ]] || {
  echo "baseline returned artifact does not match its source or graph" >&2
  exit 1
}
"${baseline_root}/scripts/verify-deployment-artifact-receipt.sh" \
  "${baseline_artifact}" "${baseline_receipt}" "${target}" >/dev/null
node "${root_dir}/scripts/linux-full-graph-audit.mjs" \
  "${baseline_graph}" >/dev/null

validate_corrected_source() {
  require_hash "${target_file}" "${expected_after_sha256}"
  cmp --silent "${patch_file}" "${overlay_patch}" || return 1
  [[ "$(grep -Fxc "${series_entry}" "${platform_series}")" == 1 ]] || return 1
  awk -v restore="${restore_entry}" -v correction="${series_entry}" '
    previous == restore && $0 == correction { adjacent++ }
    { previous=$0 }
    END { exit adjacent == 1 ? 0 : 1 }
  ' "${platform_series}" || return 1
  local function_body
  function_body=$(sed -n \
    '/bool PasswordFeatureManagerImpl::IsGenerationEnabled()/,/^}/p' \
    "${target_file}")
  [[ "${function_body}" == *'return true;'* &&
      "${function_body}" != *'GetPasswordSyncState'* &&
      "${function_body}" == *'native password bridge does not activate Google Sync'* ]]
}

if [[ -e "${preflight}" ]]; then
  if ! { [[ -f "${preflight}" && ! -L "${preflight}" &&
      "$(stat -c %a "${preflight}")" == 400 &&
      "$(exact_value "${preflight}" schema)" == \
        helium-retained-password-generation-correction-preflight-v1 &&
      "$(exact_value "${preflight}" artifact_job)" == "${artifact_job}" &&
      "$(exact_value "${preflight}" baseline_build_job)" == \
        "${baseline_build_job}" &&
      "$(exact_value "${preflight}" baseline_return_job)" == \
        "${baseline_return_job}" &&
      "$(exact_value "${preflight}" baseline_artifact_sha256)" == \
        "${baseline_artifact_sha256}" &&
      "$(exact_value "${preflight}" baseline_deployment_receipt_sha256)" == \
        "${baseline_receipt_sha256}" &&
      "$(exact_value "${preflight}" baseline_boundary_sha256)" == \
        "${baseline_boundary_sha256}" &&
      "$(exact_value "${preflight}" baseline_full_graph_receipt_sha256)" == \
        "${baseline_graph_receipt_sha256}" &&
      "$(exact_value "${preflight}" baseline_source_commit)" == \
        "${expected_baseline_commit}" &&
      "$(exact_value "${preflight}" baseline_source_tree)" == \
        "${expected_baseline_tree}" &&
      "$(exact_value "${preflight}" corrected_source_commit)" == \
        "${corrected_commit}" &&
      "$(exact_value "${preflight}" corrected_source_tree)" == \
        "${corrected_tree}" &&
      "$(exact_value "${preflight}" correction_patch_sha256)" == \
        "${expected_patch_sha256}" &&
      "$(exact_value "${preflight}" correction_before_sha256)" == \
        "${expected_before_sha256}" &&
      "$(exact_value "${preflight}" correction_after_sha256)" == \
        "${expected_after_sha256}" &&
      "$(exact_value "${preflight}" correction_validation)" == passed ]] &&
    validate_corrected_source; }; then
    echo "existing correction preflight is inconsistent" >&2
    exit 1
  fi
else
  if [[ ! -e "${intent}" ]]; then
    require_hash "${target_file}" "${expected_before_sha256}"
    [[ ! -e "${overlay_patch}" &&
        "$(grep -Fxc "${series_entry}" "${platform_series}" || true)" == 0 &&
        "$(grep -Fxc "${restore_entry}" "${platform_series}")" == 1 ]] || {
      echo "prepared platform does not have the exact baseline patch inventory" >&2
      exit 1
    }

    verification="${root_dir}/.build/baseline-verification-${artifact_job}"
    [[ ! -e "${verification}" ]] || {
      echo "baseline verification destination already exists" >&2
      exit 1
    }
    HELIUM_PRODUCT_SOURCE_ROOT="${baseline_root}" \
      "${baseline_root}/scripts/verify-linux-runtime.sh" \
        "${product}" "${arch}" "${target}" "${baseline_artifact}" \
        "${baseline_receipt}" "${verification}" >/dev/null
    baseline_verification_receipt_sha256=$(sha256sum \
      "${verification}/artifact-receipt.env" | awk '{print $1}')
    require_contained "$(realpath -e "${verification}")" \
      "$(realpath -e "${root_dir}/.build")"
    find "${verification}" -depth -delete
    baseline_browser_sha256=$(sha256sum "${out}/helium" | awk '{print $1}')

    intent_temp=$(mktemp "${artifact_state}/.password-generation-intent.XXXXXX")
    {
      printf 'schema=helium-retained-password-generation-correction-intent-v1\n'
      printf 'artifact_job=%s\n' "${artifact_job}"
      printf 'baseline_build_job=%s\n' "${baseline_build_job}"
      printf 'baseline_return_job=%s\n' "${baseline_return_job}"
      printf 'baseline_artifact_sha256=%s\n' "${baseline_artifact_sha256}"
      printf 'baseline_deployment_receipt_sha256=%s\n' \
        "${baseline_receipt_sha256}"
      printf 'baseline_boundary_sha256=%s\n' "${baseline_boundary_sha256}"
      printf 'baseline_full_graph_receipt_sha256=%s\n' \
        "${baseline_graph_receipt_sha256}"
      printf 'baseline_verification_receipt_sha256=%s\n' \
        "${baseline_verification_receipt_sha256}"
      printf 'baseline_browser_sha256=%s\n' "${baseline_browser_sha256}"
      printf 'baseline_source_commit=%s\n' "${expected_baseline_commit}"
      printf 'baseline_source_tree=%s\n' "${expected_baseline_tree}"
      printf 'corrected_source_commit=%s\n' "${corrected_commit}"
      printf 'corrected_source_tree=%s\n' "${corrected_tree}"
      printf 'correction_patch_sha256=%s\n' "${expected_patch_sha256}"
      printf 'correction_before_sha256=%s\n' "${expected_before_sha256}"
      printf 'correction_after_sha256=%s\n' "${expected_after_sha256}"
      printf 'admitted_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"${intent_temp}"
    chmod 400 "${intent_temp}"
    mv "${intent_temp}" "${intent}"
  else
    [[ -f "${intent}" && ! -L "${intent}" &&
        "$(stat -c %a "${intent}")" == 400 &&
        "$(exact_value "${intent}" schema)" == \
          helium-retained-password-generation-correction-intent-v1 &&
        "$(exact_value "${intent}" artifact_job)" == "${artifact_job}" &&
        "$(exact_value "${intent}" baseline_build_job)" == \
          "${baseline_build_job}" &&
        "$(exact_value "${intent}" baseline_return_job)" == \
          "${baseline_return_job}" &&
        "$(exact_value "${intent}" baseline_artifact_sha256)" == \
          "${baseline_artifact_sha256}" &&
        "$(exact_value "${intent}" baseline_deployment_receipt_sha256)" == \
          "${baseline_receipt_sha256}" &&
        "$(exact_value "${intent}" baseline_boundary_sha256)" == \
          "${baseline_boundary_sha256}" &&
        "$(exact_value "${intent}" baseline_full_graph_receipt_sha256)" == \
          "${baseline_graph_receipt_sha256}" &&
        "$(exact_value "${intent}" baseline_source_commit)" == \
          "${expected_baseline_commit}" &&
        "$(exact_value "${intent}" baseline_source_tree)" == \
          "${expected_baseline_tree}" &&
        "$(exact_value "${intent}" corrected_source_commit)" == \
          "${corrected_commit}" &&
        "$(exact_value "${intent}" corrected_source_tree)" == \
          "${corrected_tree}" &&
        "$(exact_value "${intent}" correction_patch_sha256)" == \
          "${expected_patch_sha256}" &&
        "$(exact_value "${intent}" correction_before_sha256)" == \
          "${expected_before_sha256}" &&
        "$(exact_value "${intent}" correction_after_sha256)" == \
          "${expected_after_sha256}" ]] || {
      echo "existing correction intent is inconsistent" >&2
      exit 1
    }
    baseline_verification_receipt_sha256=$(exact_value \
      "${intent}" baseline_verification_receipt_sha256)
    baseline_browser_sha256=$(exact_value "${intent}" baseline_browser_sha256)
  fi

  current_target_sha256=$(sha256sum "${target_file}" | awk '{print $1}')
  if [[ "${current_target_sha256}" == "${expected_before_sha256}" ]]; then
    git -C "${source_root}" apply --check "${patch_file}"
    git -C "${source_root}" apply "${patch_file}"
  elif [[ "${current_target_sha256}" != "${expected_after_sha256}" ]]; then
    echo "correction intent found an unexpected target state" >&2
    exit 1
  fi
  if [[ ! -e "${overlay_patch}" ]]; then
    install -m 644 "${patch_file}" "${overlay_patch}"
  else
    cmp --silent "${patch_file}" "${overlay_patch}" || {
      echo "correction intent found an unexpected overlay patch" >&2
      exit 1
    }
  fi
  series_count=$(grep -Fxc "${series_entry}" "${platform_series}" || true)
  if [[ "${series_count}" == 0 ]]; then
    series_temp=$(mktemp "${platform_series}.correction.XXXXXX")
    awk -v restore="${restore_entry}" -v correction="${series_entry}" '
      { print }
      $0 == restore { print correction }
    ' "${platform_series}" >"${series_temp}"
    mv "${series_temp}" "${platform_series}"
  elif [[ "${series_count}" != 1 ]]; then
    echo "correction intent found duplicate series entries" >&2
    exit 1
  fi
  validate_corrected_source || {
    echo "password generation correction validation failed" >&2
    exit 1
  }

  preflight_temp=$(mktemp "${artifact_state}/.password-generation-preflight.XXXXXX")
  {
    printf 'schema=helium-retained-password-generation-correction-preflight-v1\n'
    printf 'artifact_job=%s\n' "${artifact_job}"
    printf 'baseline_build_job=%s\n' "${baseline_build_job}"
    printf 'baseline_return_job=%s\n' "${baseline_return_job}"
    printf 'baseline_artifact_sha256=%s\n' "${baseline_artifact_sha256}"
    printf 'baseline_deployment_receipt_sha256=%s\n' \
      "${baseline_receipt_sha256}"
    printf 'baseline_boundary_sha256=%s\n' "${baseline_boundary_sha256}"
    printf 'baseline_full_graph_receipt_sha256=%s\n' \
      "${baseline_graph_receipt_sha256}"
    printf 'baseline_verification_receipt_sha256=%s\n' \
      "${baseline_verification_receipt_sha256}"
    printf 'baseline_source_commit=%s\n' "${expected_baseline_commit}"
    printf 'baseline_source_tree=%s\n' "${expected_baseline_tree}"
    printf 'corrected_source_commit=%s\n' "${corrected_commit}"
    printf 'corrected_source_tree=%s\n' "${corrected_tree}"
    printf 'correction_patch=%s\n' "${patch_relative}"
    printf 'correction_patch_sha256=%s\n' "${expected_patch_sha256}"
    printf 'correction_target=%s\n' "${target_relative}"
    printf 'correction_before_sha256=%s\n' "${expected_before_sha256}"
    printf 'correction_after_sha256=%s\n' "${expected_after_sha256}"
    printf 'baseline_browser_sha256=%s\n' "${baseline_browser_sha256}"
    printf 'correction_applied_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'correction_validation=passed\n'
  } >"${preflight_temp}"
  chmod 400 "${preflight_temp}"
  mv "${preflight_temp}" "${preflight}"
fi

baseline_verification_receipt_sha256=$(exact_value \
  "${preflight}" baseline_verification_receipt_sha256)
baseline_browser_sha256=$(exact_value "${preflight}" baseline_browser_sha256)
build_started_at=$(exact_value "${preflight}" correction_applied_at)
[[ "${baseline_verification_receipt_sha256}" =~ ^[0-9a-f]{64}$ &&
    "${baseline_browser_sha256}" =~ ^[0-9a-f]{64}$ &&
    "${build_started_at}" =~ \
      ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
  echo "correction preflight has invalid evidence values" >&2
  exit 1
}

mkdir -p "${artifact_dir}"
for tool in git node ninja; do
  command -v "${tool}" >/dev/null || {
    echo "correction environment is missing ${tool}" >&2
    exit 1
  }
done
real_ninja=$(realpath -e "$(command -v ninja)")
ninja_shim="${root_dir}/scripts/chromiumer-bin/ninja"
[[ -x "${real_ninja}" && -x "${ninja_shim}" &&
    "${real_ninja}" != "$(realpath -e "${ninja_shim}")" &&
    "$(node --version)" == v22.14.0 ]] || {
  echo "correction did not resolve its exact Node and Ninja tools" >&2
  exit 1
}

baseline_boundary_value() {
  exact_value "${baseline_boundary}" "$1"
}

validate_existing_boundary() {
  [[ -f "${boundary}" && ! -L "${boundary}" &&
      "$(stat -c %a "${boundary}")" == 400 &&
      "$(exact_value "${boundary}" schema)" == \
        helium-retained-password-generation-correction-boundary-v1 &&
      "$(exact_value "${boundary}" job)" == "${artifact_job}" &&
      "$(exact_value "${boundary}" source_root)" == "${source_root}" &&
      "$(exact_value "${boundary}" baseline_artifact_sha256)" == \
        "${baseline_artifact_sha256}" &&
      "$(exact_value "${boundary}" baseline_boundary_sha256)" == \
        "${baseline_boundary_sha256}" &&
      "$(exact_value "${boundary}" baseline_browser_sha256)" == \
        "${baseline_browser_sha256}" &&
      "$(exact_value "${boundary}" baseline_build_job)" == \
        "${baseline_build_job}" &&
      "$(exact_value "${boundary}" baseline_deployment_receipt_sha256)" == \
        "${baseline_receipt_sha256}" &&
      "$(exact_value "${boundary}" baseline_full_graph_receipt_sha256)" == \
        "${baseline_graph_receipt_sha256}" &&
      "$(exact_value "${boundary}" baseline_return_job)" == \
        "${baseline_return_job}" &&
      "$(exact_value "${boundary}" baseline_source_commit)" == \
        "${expected_baseline_commit}" &&
      "$(exact_value "${boundary}" baseline_source_tree)" == \
        "${expected_baseline_tree}" &&
      "$(exact_value "${boundary}" baseline_verification_receipt_sha256)" == \
        "${baseline_verification_receipt_sha256}" &&
      "$(exact_value "${boundary}" build_exit_code)" == 0 &&
      "$(exact_value "${boundary}" build_started_at)" == \
        "${build_started_at}" &&
      "$(exact_value "${boundary}" corrected_source_commit)" == \
        "${corrected_commit}" &&
      "$(exact_value "${boundary}" corrected_source_tree)" == \
        "${corrected_tree}" &&
      "$(exact_value "${boundary}" correction_after_sha256)" == \
        "${expected_after_sha256}" &&
      "$(exact_value "${boundary}" correction_before_sha256)" == \
        "${expected_before_sha256}" &&
      "$(exact_value "${boundary}" correction_patch)" == \
        "${patch_relative}" &&
      "$(exact_value "${boundary}" correction_patch_sha256)" == \
        "${expected_patch_sha256}" &&
      "$(exact_value "${boundary}" correction_target)" == \
        "${target_relative}" &&
      "$(exact_value "${boundary}" correction_validation)" == passed &&
      "$(exact_value "${boundary}" reuse_scope)" == \
        one-source-file-existing-completed-graph ]] || return 1
  local field
  for field in node_version full_targets build_ninja_sha256 \
      toolchain_ninja_sha256 generate_css_gni_sha256 generate_css_js_sha256 \
      build_ai_skills_sha256 css_action_edges \
      css_action_edges_without_tsconfig \
      ui_css_outputs_materialized_before_full_build \
      ui_css_phony_orders_all_outputs ui_downstream_orders_css_phony \
      ai_skill_action_present ninja_query_sha256 graph_validation; do
    [[ "$(exact_value "${boundary}" "${field}")" == \
        "$(baseline_boundary_value "${field}")" ]] || return 1
  done
  local corrected_hash completed
  corrected_hash=$(exact_value "${boundary}" corrected_browser_sha256)
  completed=$(exact_value "${boundary}" build_completed_at)
  [[ "${corrected_hash}" =~ ^[0-9a-f]{64}$ &&
      "${corrected_hash}" != "${baseline_browser_sha256}" &&
      "$(sha256sum "${out}/helium" | awk '{print $1}')" == \
        "${corrected_hash}" &&
      "${completed}" =~ \
        ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

if [[ -e "${artifact}" || -e "${receipt}" ]]; then
  [[ -f "${artifact}" && ! -L "${artifact}" &&
      -f "${receipt}" && ! -L "${receipt}" &&
      -d "${full_graph}" && ! -L "${full_graph}" ]] || {
    echo "correction found incomplete artifact outputs" >&2
    exit 1
  }
  validate_existing_boundary || {
    echo "completed correction boundary is inconsistent" >&2
    exit 1
  }
  verification="${root_dir}/.build/corrected-verification-${artifact_job}"
  [[ ! -e "${verification}" ]] || {
    echo "corrected verification destination already exists" >&2
    exit 1
  }
  HELIUM_PRODUCT_SOURCE_ROOT="${root_dir}" \
    "${root_dir}/scripts/verify-linux-runtime.sh" \
      "${product}" "${arch}" "${target}" "${artifact}" "${receipt}" \
      "${verification}" >/dev/null
  find "${verification}" -depth -delete
  printf 'linux_artifact=%s\nlinux_receipt=%s\nlinux_full_graph=%s\ncorrection_boundary=%s\n' \
    "${artifact#"${root_dir}/"}" "${receipt#"${root_dir}/"}" \
    "${full_graph#"${root_dir}/"}" "${boundary}"
  exit 0
fi

if [[ -e "${boundary}" ]]; then
  validate_existing_boundary || {
    echo "existing correction boundary is inconsistent" >&2
    exit 1
  }
  corrected_browser_sha256=$(exact_value "${boundary}" \
    corrected_browser_sha256)
else
  [[ ! -e "${full_graph}" ]] || {
    echo "correction evidence exists without its boundary" >&2
    exit 1
  }
  "${real_ninja}" -j 1 -C "${out}" chrome chromedriver
  build_completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  corrected_browser_sha256=$(sha256sum "${out}/helium" | awk '{print $1}')
  [[ "${corrected_browser_sha256}" =~ ^[0-9a-f]{64}$ &&
      "${corrected_browser_sha256}" != "${baseline_browser_sha256}" ]] || {
    echo "corrected browser output did not change" >&2
    exit 1
  }

  for binding in \
      "build_ninja_sha256:${out}/build.ninja" \
      "toolchain_ninja_sha256:${out}/toolchain.ninja" \
      "generate_css_gni_sha256:${source_root}/third_party/devtools-frontend/src/scripts/build/ninja/generate_css.gni" \
      "generate_css_js_sha256:${source_root}/third_party/devtools-frontend/src/scripts/build/generate_css_js_files.js" \
      "build_ai_skills_sha256:${source_root}/third_party/devtools-frontend/src/scripts/build/build_ai_skills.mjs"; do
    field=${binding%%:*}
    file=${binding#*:}
    require_hash "${file}" "$(baseline_boundary_value "${field}")"
  done
  query_temp=$(mktemp "${artifact_state}/.password-generation-query.XXXXXX")
  "${real_ninja}" -C "${out}" -t query \
    gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json \
    gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json \
    >"${query_temp}"
  require_hash "${query_temp}" "$(baseline_boundary_value ninja_query_sha256)"
  find "${query_temp}" -delete

  boundary_temp=$(mktemp "${artifact_state}/.password-generation-boundary.XXXXXX")
  {
    printf 'schema=helium-retained-password-generation-correction-boundary-v1\n'
    printf 'job=%s\n' "${artifact_job}"
    printf 'source_root=%s\n' "${source_root}"
    printf 'boundary_epoch=%s\n' "$(date +%s)"
    printf 'validated_at=%s\n' "${build_completed_at}"
    for field in node_version full_targets build_ninja_sha256 \
        toolchain_ninja_sha256 generate_css_gni_sha256 generate_css_js_sha256 \
        build_ai_skills_sha256 css_action_edges \
        css_action_edges_without_tsconfig \
        ui_css_outputs_materialized_before_full_build \
        ui_css_phony_orders_all_outputs ui_downstream_orders_css_phony \
        ai_skill_action_present ninja_query_sha256 graph_validation; do
      printf '%s=%s\n' "${field}" "$(baseline_boundary_value "${field}")"
    done
    printf 'baseline_artifact_sha256=%s\n' "${baseline_artifact_sha256}"
    printf 'baseline_boundary_sha256=%s\n' "${baseline_boundary_sha256}"
    printf 'baseline_browser_sha256=%s\n' "${baseline_browser_sha256}"
    printf 'baseline_build_job=%s\n' "${baseline_build_job}"
    printf 'baseline_deployment_receipt_sha256=%s\n' \
      "${baseline_receipt_sha256}"
    printf 'baseline_full_graph_receipt_sha256=%s\n' \
      "${baseline_graph_receipt_sha256}"
    printf 'baseline_return_job=%s\n' "${baseline_return_job}"
    printf 'baseline_source_commit=%s\n' "${expected_baseline_commit}"
    printf 'baseline_source_tree=%s\n' "${expected_baseline_tree}"
    printf 'baseline_verification_receipt_sha256=%s\n' \
      "${baseline_verification_receipt_sha256}"
    printf 'build_completed_at=%s\n' "${build_completed_at}"
    printf 'build_exit_code=0\n'
    printf 'build_started_at=%s\n' "${build_started_at}"
    printf 'corrected_browser_sha256=%s\n' "${corrected_browser_sha256}"
    printf 'corrected_source_commit=%s\n' "${corrected_commit}"
    printf 'corrected_source_tree=%s\n' "${corrected_tree}"
    printf 'correction_after_sha256=%s\n' "${expected_after_sha256}"
    printf 'correction_before_sha256=%s\n' "${expected_before_sha256}"
    printf 'correction_patch=%s\n' "${patch_relative}"
    printf 'correction_patch_sha256=%s\n' "${expected_patch_sha256}"
    printf 'correction_target=%s\n' "${target_relative}"
    printf 'correction_validation=passed\n'
    printf 'reuse_scope=one-source-file-existing-completed-graph\n'
  } >"${boundary_temp}"
  chmod 400 "${boundary_temp}"
  mv "${boundary_temp}" "${boundary}"
fi

if [[ -e "${full_graph}" ]]; then
  if ! { [[ -d "${full_graph}" && ! -L "${full_graph}" ]] &&
    node "${root_dir}/scripts/linux-full-graph-audit.mjs" \
      "${full_graph}" >/dev/null; }; then
    echo "existing correction full-graph evidence is inconsistent" >&2
    exit 1
  fi
  HELIUM_PRODUCT_SOURCE_ROOT="${root_dir}" \
    "${root_dir}/scripts/package-linux-runtime.sh" \
      "${product}" "${arch}" "${target}" "${artifact_job}" \
      "${checkout}" "${full_graph}" "${artifact}" "${receipt}"
else
  HELIUM_PRODUCT_SOURCE_ROOT="${root_dir}" \
  HELIUM_BUILD_OPERATOR="${root_dir}/scripts/correct-retained-linux-password-generation.sh" \
  HELIUM_NINJA_SHIM="${ninja_shim}" \
  HELIUM_REAL_NINJA="${real_ninja}" \
    "${root_dir}/scripts/finalize-retained-linux-full-graph.sh" \
      "${product}" "${arch}" "${target}" "${artifact_job}" \
      "${root_dir}" "${checkout}" "${boundary}" "${artifact}" "${receipt}"
fi

printf 'linux_artifact=%s\nlinux_receipt=%s\nlinux_full_graph=%s\ncorrection_boundary=%s\n' \
  "${artifact#"${root_dir}/"}" "${receipt#"${root_dir}/"}" \
  "${full_graph#"${root_dir}/"}" "${boundary}"
