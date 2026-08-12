#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: scripts/dev.sh <check|status|smoke> [platform] [arch]

Commands:
  check   Run every lightweight, local check. Never downloads Chromium.
  status  Show repository and pinned Helium/Chromium state.
  smoke   Check platform overlay injection; requires platform and arch.
EOF
}

check_shell() {
    while IFS= read -r -d '' script; do
        bash -n "${script}"
    done < <(find "${root_dir}/scripts" -type f -name '*.sh' -print0 | sort -z)
    while IFS= read -r -d '' test_script; do
        bash "${test_script}"
    done < <(find "${root_dir}/scripts/tests" -type f -name '*.test.sh' -print0 2>/dev/null | sort -z)
}

check_javascript() {
    command -v node >/dev/null 2>&1 || {
        echo "node is required to check JavaScript helpers" >&2
        return 1
    }
    while IFS= read -r -d '' script; do
        node --check "${script}"
    done < <(find "${root_dir}/scripts" -type f -name '*.mjs' -print0 | sort -z)
    while IFS= read -r -d '' test_script; do
        node --test "${test_script}"
    done < <(find "${root_dir}/scripts/tests" -type f -name '*.test.mjs' -print0 | sort -z)
}

check_python() {
    command -v python >/dev/null 2>&1 || {
        echo "python is required to check Python helpers" >&2
        return 1
    }
    while IFS= read -r -d '' script; do
        python -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "${script}"
    done < <(find "${root_dir}/scripts" -type f -name '*.py' -print0 | sort -z)
}

check_go() {
    [ -f "${root_dir}/go.mod" ] || return 0
    command -v go >/dev/null 2>&1 || {
        echo "go is required to check the sync services" >&2
        return 1
    }
    (
        cd "${root_dir}"
        go test ./...
        go vet ./...
        go build ./cmd/...
    )
}

check_backbone() {
    [ -f "${root_dir}/go.mod" ] || return 0
    # shellcheck source=../linux-product.conf
    # shellcheck disable=SC1091
    . "${root_dir}/linux-product.conf"
    [ "${HELIUM_LINUX_PRODUCT}" = helium-passwords ] || {
        echo "Linux artifact product is not helium-passwords" >&2
        return 1
    }
    [ "${HELIUM_LINUX_PASSWORDS_REF}" = HEAD ] || {
        echo "Linux artifact Passwords source is not this checkout" >&2
        return 1
    }
    [ "${HELIUM_LINUX_SYNC_REF}" = \
        0000000000000000000000000000000000000000 ] || {
        echo "public artifact unexpectedly identifies a private Sync source" >&2
        return 1
    }
    [ "$(cd "${root_dir}" && go list -m -f '{{.Path}}' 2>/dev/null)" = \
        github.com/dhruv9saini/helium-passwords ] || {
        echo "Go module is not bound to the public Helium Passwords product" >&2
        return 1
    }
}

check_all() {
    check_shell
    "${root_dir}/helium-chromium/devutils/lint.py" -t "${root_dir}"
    "${root_dir}/scripts/chromium/generate-overlay-patch.sh" --check

    if [ -n "$(find "${root_dir}/scripts" -type f -name '*.mjs' -print -quit)" ]; then
        check_javascript
    fi
    if [ -n "$(find "${root_dir}/scripts" -type f -name '*.py' -print -quit)" ]; then
        check_python
    fi

    check_go
    check_backbone
    echo "lightweight checks passed"
}

show_status() {
    git -C "${root_dir}" status --short --branch --ignore-submodules=none
    printf 'repository=%s\n' "$(basename "${root_dir}")"
    printf 'head=%s\n' "$(git -C "${root_dir}" rev-parse HEAD)"
    printf 'helium_submodule=%s\n' "$(git -C "${root_dir}" rev-parse HEAD:helium-chromium)"
    printf 'chromium_version=%s\n' "$(tr -d '\r\n' <"${root_dir}/helium-chromium/chromium_version.txt")"

    # shellcheck source=../linux-product.conf
    # shellcheck disable=SC1091
    . "${root_dir}/linux-product.conf"
    printf 'linux_product=%s\n' "${HELIUM_LINUX_PRODUCT}"
    printf 'passwords_source=%s\n' "${HELIUM_LINUX_PASSWORDS_REF}"
    printf 'private_sync_source=%s\n' "${HELIUM_LINUX_SYNC_REF}"
}

smoke_target() {
    [ "$#" -eq 2 ] || {
        usage
        exit 2
    }
    "${root_dir}/scripts/ci-check-target.sh" "$1" "$2"
}

command=${1:-}
case "${command}" in
    check)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        check_all
        ;;
    status)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        show_status
        ;;
    smoke)
        shift
        smoke_target "$@"
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac
