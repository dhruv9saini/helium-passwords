#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
grep -Fqx '/.build/' "${repo_root}/.gitignore"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/helium-linux-artifact-test.XXXXXX")
cleanup() {
    find "${temporary}" -depth -delete
}
trap cleanup EXIT

# shellcheck source=../../linux-product.conf
# shellcheck disable=SC1091
. "${repo_root}/linux-product.conf"
product=${HELIUM_LINUX_PRODUCT}
nix_source=$(sha256sum "${repo_root}/chromium/nix/chromiumer-shell.nix" |
    awk '{ print $1 }')

source_value() {
    local source_info=$1
    local key=$2
    awk -F= -v key="${key}" \
        '$1 == key { print substr($0, length(key) + 2); exit }' \
        <<<"${source_info}"
}

make_fixture() {
    local arch=$1
    local target=$2
    local stage="${temporary}/stage-${arch}"
    local bundle_name="${product}-linux-${arch}"
    local bundle="${stage}/${bundle_name}"
    local runtime="${bundle}/runtime"
    local provenance="${bundle}/provenance"
    local graph="${provenance}/full-graph"
    local source_info source_commit source_tree passwords_commit sync_commit
    local core_commit chromium_version chromium_commit target_cpu job
    local artifact receipt verification output provenance_sha graph_receipt_sha
    local graph_inventory_sha packaging_tool_sha packaging_tool_commit

    source_info=$("${repo_root}/scripts/linux-product-provenance.sh" \
        "${product}" "${arch}" "${target}")
    source_commit=$(source_value "${source_info}" source_commit)
    source_tree=$(source_value "${source_info}" source_tree)
    passwords_commit=$(source_value "${source_info}" helium_passwords_commit)
    sync_commit=$(source_value "${source_info}" helium_sync_commit)
    core_commit=$(source_value "${source_info}" helium_core_commit)
    chromium_version=$(source_value "${source_info}" chromium_version)
    chromium_commit=$(source_value "${source_info}" chromium_commit)
    case "${arch}" in
        x86_64) target_cpu=x64 ;;
        arm64) target_cpu=arm64 ;;
        *) exit 2 ;;
    esac
    job="synthetic-${arch}-01"

    mkdir -p "${runtime}/locales" "${provenance}" "${graph}"
    chmod 700 "${graph}"
    for file in \
        chrome_100_percent.pak chrome_200_percent.pak chromedriver \
        helium_crashpad_handler icudtl.dat libEGL.so libGLESv2.so \
        libqt5_shim.so libqt6_shim.so libvk_swiftshader.so libvulkan.so.1 \
        product_logo_256.png resources.pak v8_context_snapshot.bin \
        vk_swiftshader_icd.json xdg-mime xdg-settings; do
        printf 'synthetic %s %s\n' "${arch}" "${file}" >"${runtime}/${file}"
    done
    printf '#!/bin/sh\nexit 0\n' >"${runtime}/helium"
    chmod 755 "${runtime}/helium"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nexec "$(dirname "$0")/helium" "$@"\n' \
        >"${runtime}/helium-wrapper"
    chmod 755 "${runtime}/helium-wrapper"
    printf 'synthetic desktop entry\n' >"${runtime}/helium.desktop"
    printf 'synthetic apparmor policy\n' >"${runtime}/apparmor.cfg"
    printf 'synthetic locale\n' >"${runtime}/locales/en-US.pak"
    ln -s helium "${runtime}/chrome"
    printf 'target_cpu = "%s"\n' "${target_cpu}" >"${provenance}/gn-args.txt"
    cat >"${provenance}/chromiumer-nix.env" <<EOF
nix_environment=/nix/store/aaaaaaaaaaaaaaaa-synthetic
nix_derivation=/nix/store/bbbbbbbbbbbbbbbb-synthetic.drv
closure_sha256=$(printf 'a%.0s' {1..64})
closure_bytes=1
chromium_commit=${chromium_commit}
environment_source_sha256=${nix_source}
EOF
    "${repo_root}/scripts/patch-inventory.sh" \
        >"${provenance}/patches.sha256"
    (
        cd "${bundle}"
        find runtime -type f -print0 | sort -z |
            xargs -0 sha256sum >provenance/runtime.sha256
    )
    printf 'synthetic build graph\n' >"${graph}/build.ninja"
    cat >"${graph}/toolchain.ninja" <<'EOF'
build gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json gen/third_party/devtools-frontend/src/front_end/ui/kit/cards/card.css.js gen/third_party/devtools-frontend/src/front_end/ui/kit/icons/icon.css.js gen/third_party/devtools-frontend/src/front_end/ui/kit/link/link.css.js: __third_party_devtools-frontend_src_front_end_ui_kit_css_files___build_toolchain_linux_clang_x64__rule
build phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files: phony gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json gen/third_party/devtools-frontend/src/front_end/ui/kit/cards/card.css.js gen/third_party/devtools-frontend/src/front_end/ui/kit/icons/icon.css.js gen/third_party/devtools-frontend/src/front_end/ui/kit/link/link.css.js
build gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json : synthetic_rule || phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files
build gen/third_party/devtools-frontend/src/front_end/models/ai_assistance/skills/styling.skill.js: synthetic_rule
EOF
    printf 'synthetic gni source\n' >"${graph}/generate_css.gni"
    printf 'synthetic css generator\n' >"${graph}/generate_css_js_files.js"
    printf 'synthetic AI skills builder\n' >"${graph}/build_ai_skills.mjs"
    printf 'synthetic platform shared\n' >"${graph}/platform-shared.sh"
    printf 'synthetic operator\n' >"${graph}/build-operator.sh"
    printf 'synthetic shim\n' >"${graph}/ninja-shim"
    printf 'synthetic ninja binary\n' >"${graph}/ninja-binary"
    printf '1.11.1\n' >"${graph}/ninja-version.txt"
    cat >"${graph}/ninja-query.txt" <<'EOF'
gen/third_party/devtools-frontend/src/front_end/ui/kit/css_files-tsconfig.json
gen/third_party/devtools-frontend/src/front_end/ui/kit/devtools_entrypoint-bundle-tsconfig-tsconfig.json
  outputs:
    phony/third_party/devtools-frontend/src/front_end/ui/kit/css_files
EOF
    printf 'chrome:\n  outputs:\nchromedriver:\n  outputs:\n' \
        >"${graph}/full-targets-query.txt"
    cp "${repo_root}/scripts/capture-linux-full-graph-evidence.sh" \
        "${graph}/capture-tool.sh"
    cp "${repo_root}/scripts/package-linux-runtime.sh" \
        "${graph}/packaging-tool.sh"
    cp "${repo_root}/scripts/write-deployment-artifact-receipt.sh" \
        "${graph}/deployment-receipt-tool.sh"
    cp "${repo_root}/scripts/finalize-retained-linux-full-graph.sh" \
        "${graph}/finalizer-tool.sh"
    cp "${repo_root}/scripts/linux-full-graph-audit.mjs" \
        "${graph}/full-graph-audit-tool.mjs"
    cp "${repo_root}/scripts/continue-retained-linux-full-graph-failure.sh" \
        "${graph}/repair-tool.sh"
    printf '%s\n' "${source_commit}" >"${graph}/product-commit.txt"
    printf '%s\n' "${chromium_commit}" >"${graph}/chromium-commit.txt"
    printf '%s\n' 9fbdff55283c9275f285c49dc054a1ff38dcdc96 \
        >"${graph}/platform-commit.txt"
    cat >"${graph}/boundary-receipt.env" <<EOF
schema=helium-fresh-full-graph-boundary-v1
job=${job}
source_root=${temporary}/synthetic/build/src
boundary_epoch=1
validated_at=2026-07-22T11:59:59+00:00
node_version=v22.14.0
full_targets=chrome,chromedriver
build_ninja_sha256=$(sha256sum "${graph}/build.ninja" | awk '{print $1}')
toolchain_ninja_sha256=$(sha256sum "${graph}/toolchain.ninja" | awk '{print $1}')
generate_css_gni_sha256=$(sha256sum "${graph}/generate_css.gni" | awk '{print $1}')
generate_css_js_sha256=$(sha256sum "${graph}/generate_css_js_files.js" | awk '{print $1}')
build_ai_skills_sha256=$(sha256sum "${graph}/build_ai_skills.mjs" | awk '{print $1}')
css_action_edges=1
css_action_edges_without_tsconfig=0
ui_css_outputs_materialized_before_full_build=false
ui_css_phony_orders_all_outputs=true
ui_downstream_orders_css_phony=true
ai_skill_action_present=true
ninja_query_sha256=$(sha256sum "${graph}/ninja-query.txt" | awk '{print $1}')
graph_validation=passed
EOF
    cat >"${graph}/receipt.env" <<EOF
schema=helium-linux-full-graph-evidence-v3
job=${job}
product=${product}
arch=${arch}
target=${target}
helium_sync_commit=${sync_commit}
helium_passwords_commit=${passwords_commit}
helium_core_commit=${core_commit}
chromium_commit=${chromium_commit}
platform_commit=9fbdff55283c9275f285c49dc054a1ff38dcdc96
node_version=v22.14.0
full_targets=chrome,chromedriver
build_ninja_sha256=$(sha256sum "${graph}/build.ninja" | awk '{print $1}')
toolchain_ninja_sha256=$(sha256sum "${graph}/toolchain.ninja" | awk '{print $1}')
generate_css_gni_sha256=$(sha256sum "${graph}/generate_css.gni" | awk '{print $1}')
generate_css_js_sha256=$(sha256sum "${graph}/generate_css_js_files.js" | awk '{print $1}')
build_ai_skills_sha256=$(sha256sum "${graph}/build_ai_skills.mjs" | awk '{print $1}')
platform_shared_sha256=$(sha256sum "${graph}/platform-shared.sh" | awk '{print $1}')
build_operator_sha256=$(sha256sum "${graph}/build-operator.sh" | awk '{print $1}')
ninja_shim_sha256=$(sha256sum "${graph}/ninja-shim" | awk '{print $1}')
ninja_binary_sha256=$(sha256sum "${graph}/ninja-binary" | awk '{print $1}')
ninja_version_sha256=$(sha256sum "${graph}/ninja-version.txt" | awk '{print $1}')
ninja_query_sha256=$(sha256sum "${graph}/ninja-query.txt" | awk '{print $1}')
full_targets_query_sha256=$(sha256sum "${graph}/full-targets-query.txt" | awk '{print $1}')
boundary_receipt_sha256=$(sha256sum "${graph}/boundary-receipt.env" | awk '{print $1}')
capture_tool_sha256=$(sha256sum "${graph}/capture-tool.sh" | awk '{print $1}')
packaging_tool_sha256=$(sha256sum "${graph}/packaging-tool.sh" | awk '{print $1}')
deployment_receipt_tool_sha256=$(sha256sum "${graph}/deployment-receipt-tool.sh" | awk '{print $1}')
finalizer_tool_sha256=$(sha256sum "${graph}/finalizer-tool.sh" | awk '{print $1}')
full_graph_audit_tool_sha256=$(sha256sum "${graph}/full-graph-audit-tool.mjs" | awk '{print $1}')
repair_tool_sha256=$(sha256sum "${graph}/repair-tool.sh" | awk '{print $1}')
css_action_edges=1
css_action_edges_without_tsconfig=0
ui_css_outputs_materialized_before_full_build=false
ui_css_phony_orders_all_outputs=true
ui_downstream_orders_css_phony=true
ai_skill_action_present=true
graph_validation=passed
captured_at=2026-07-22T12:00:00Z
EOF
    chmod 600 "${graph}"/*
    (
        cd "${graph}"
        find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' |
            sort -z | xargs -0 sha256sum >SHA256SUMS
    )
    chmod 600 "${graph}/SHA256SUMS"
    graph_receipt_sha=$(sha256sum "${graph}/receipt.env" | awk '{print $1}')
    graph_inventory_sha=$(sha256sum "${graph}/SHA256SUMS" | awk '{print $1}')
    packaging_tool_sha=$(sha256sum "${graph}/packaging-tool.sh" | awk '{print $1}')
    packaging_tool_commit=$(git -C "${repo_root}" rev-parse HEAD)
    cat >"${provenance}/manifest.env" <<EOF
schema_version=4
product=${product}
platform=linux
arch=${arch}
target=${target}
source_commit=${source_commit}
source_tree=${source_tree}
helium_passwords_commit=${passwords_commit}
helium_sync_commit=${sync_commit}
helium_core_commit=${core_commit}
chromium_version=${chromium_version}
chromium_commit=${chromium_commit}
build_job_id=${job}
platform_repository=https://github.com/imputnet/helium-linux.git
platform_commit=9fbdff55283c9275f285c49dc054a1ff38dcdc96
depot_tools_commit=980d6af16e06ff993a52029019dc0628c0a0e1f0
gn_args_sha256=$(sha256sum "${provenance}/gn-args.txt" | awk '{ print $1 }')
nix_provenance_sha256=$(sha256sum "${provenance}/chromiumer-nix.env" | awk '{ print $1 }')
patch_inventory_sha256=$(sha256sum "${provenance}/patches.sha256" | awk '{ print $1 }')
runtime_inventory_sha256=$(sha256sum "${provenance}/runtime.sha256" | awk '{ print $1 }')
packaging_tool_commit=${packaging_tool_commit}
packaging_tool_sha256=${packaging_tool_sha}
full_graph_receipt_sha256=${graph_receipt_sha}
full_graph_inventory_sha256=${graph_inventory_sha}
EOF
    artifact="${temporary}/${bundle_name}.tar.xz"
    receipt="${temporary}/${bundle_name}.receipt.env"
    tar -cJf "${artifact}" -C "${stage}" "${bundle_name}"
    provenance_sha=$(sha256sum "${provenance}/manifest.env" |
        awk '{ print $1 }')
    "${repo_root}/scripts/write-deployment-artifact-receipt.sh" \
        "${artifact}" "${target}" "${sync_commit}" "${passwords_commit}" \
        "${core_commit}" "${chromium_commit}" "${job}" \
        "${provenance_sha}" "${graph_receipt_sha}" \
        "${graph_inventory_sha}" "${receipt}" >/dev/null

    verification="${temporary}/verified-${arch}"
    output=$("${repo_root}/scripts/verify-linux-runtime.sh" \
        "${product}" "${arch}" "${target}" "${artifact}" "${receipt}" \
        "${verification}")
    grep -Fq \
        "browser=${verification}/${bundle_name}/runtime/helium-wrapper" \
        <<<"${output}"
    grep -Fq "receipt=${verification}/artifact-receipt.env" <<<"${output}"
    grep -Fqx "source_commit=${source_commit}" \
        "${verification}/artifact-receipt.env"
    grep -Fqx "product=${product}" "${verification}/artifact-receipt.env"
    grep -Fqx "arch=${arch}" "${verification}/artifact-receipt.env"
    cmp "${receipt}" "${verification}/deployment-artifact-receipt.env"
    grep -Fqx 'schema_version=2' "${receipt}"
    grep -Fqx "target=${target}" "${receipt}"
    grep -Fqx "helium_passwords_commit=${passwords_commit}" "${receipt}"
    grep -Fqx "helium_sync_commit=${sync_commit}" "${receipt}"
    grep -Fqx "build_job_id=${job}" "${receipt}"
    grep -Fqx "provenance_sha256=${provenance_sha}" "${receipt}"
    "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
        "${artifact}" "${receipt}" "${target}" >/dev/null

    if "${repo_root}/scripts/verify-linux-runtime.sh" \
        "${product}" "${arch}" \
        "$([ "${arch}" = x86_64 ] && echo linux-arm64 || echo linux-x86_64)" \
        "${artifact}" "${receipt}" "${temporary}/wrong-target-${arch}" \
        >/dev/null 2>&1; then
        echo "wrong explicit Linux target passed verification" >&2
        exit 1
    fi
}

make_fixture x86_64 "${HELIUM_LINUX_X86_64_TARGET}"

artifact="${temporary}/${product}-linux-x86_64.tar.xz"
receipt="${temporary}/${product}-linux-x86_64.receipt.env"
cp "${receipt}" "${temporary}/unknown-field.receipt.env"
printf 'legacy_field=forbidden\n' >>"${temporary}/unknown-field.receipt.env"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${artifact}" "${temporary}/unknown-field.receipt.env" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "receipt with a legacy field passed verification" >&2
    exit 1
fi
cp "${receipt}" "${temporary}/wrong-schema.receipt.env"
sed -i 's/^schema_version=2$/schema_version=3/' \
    "${temporary}/wrong-schema.receipt.env"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${artifact}" "${temporary}/wrong-schema.receipt.env" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "unsupported receipt schema passed verification" >&2
    exit 1
fi
cp "${artifact}" "${temporary}/tampered.tar.xz"
printf tamper >>"${temporary}/tampered.tar.xz"
if "${repo_root}/scripts/verify-deployment-artifact-receipt.sh" \
    "${temporary}/tampered.tar.xz" "${receipt}" \
    "${HELIUM_LINUX_X86_64_TARGET}" >/dev/null 2>&1; then
    echo "tampered Linux artifact passed deployment verification" >&2
    exit 1
fi
if [ "${product}" = helium-sync ]; then
    wrong_product=helium-passwords
else
    wrong_product=helium-sync
fi
if "${repo_root}/scripts/linux-product-provenance.sh" \
    "${wrong_product}" x86_64 "${HELIUM_LINUX_X86_64_TARGET}" \
    >/dev/null 2>&1; then
    echo "wrong product passed the repository binding" >&2
    exit 1
fi

grep -q 'bash scripts/build.sh -c' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
# shellcheck disable=SC2016
grep -q 'ARCH="${arch}"' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'HELIUM_LINUX_PHASE' "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'HELIUM_FULL_GRAPH_AUDIT_TOOL=' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q '"${checkout}" "${full_graph}" "${artifact}" "${receipt}"' \
    "${repo_root}/scripts/build-chromiumer-linux.sh"
grep -q 'write-deployment-artifact-receipt.sh' \
    "${repo_root}/scripts/package-linux-runtime.sh"
if grep -q '^schema_version=1' \
    "${repo_root}/scripts/package-linux-runtime.sh"; then
    echo "packager hand-authors the deployment receipt" >&2
    exit 1
fi
grep -q 'nodejs_22' "${repo_root}/chromium/nix/chromiumer-shell.nix"
grep -q 'ninja' "${repo_root}/chromium/nix/chromiumer-shell.nix"
printf 'linux_runtime_artifact=passed\n'
