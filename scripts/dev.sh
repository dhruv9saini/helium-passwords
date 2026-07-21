#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

usage() {
    cat >&2 <<'EOF'
usage: scripts/dev.sh <check|status|smoke> [platform] [arch]

Commands:
  check   Run every lightweight, local check. Never downloads Chromium.
  status  Show repository, backbone, and pinned Helium/Chromium state.
  smoke   Check platform overlay injection; requires platform and arch.
EOF
}

check_shell() {
    while IFS= read -r -d '' script; do
        bash -n "${script}"
    done < <(find "${root_dir}/scripts" -type f -name '*.sh' -print0 | sort -z)
}

check_javascript() {
    command -v node >/dev/null 2>&1 || {
        echo "node is required to check JavaScript helpers" >&2
        return 1
    }
    while IFS= read -r -d '' script; do
        node --check "${script}"
    done < <(find "${root_dir}/scripts" -type f -name '*.mjs' -print0 | sort -z)
    if find "${root_dir}/scripts/tests" -type f -name '*.test.mjs' -print -quit 2>/dev/null | grep -q .; then
        node --test "${root_dir}"/scripts/tests/*.test.mjs
    fi
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
    local passwords_repo=${HELIUM_PASSWORDS_REPO:-"${root_dir}/../helium-passwords"}
    [ -d "${passwords_repo}/.git" ] || {
        echo "missing Helium Passwords sibling: ${passwords_repo}" >&2
        return 1
    }

    local passwords_head
    passwords_head="$(git -C "${passwords_repo}" rev-parse main)"
    git -C "${root_dir}" merge-base --is-ancestor "${passwords_head}" HEAD || {
        echo "Helium Sync does not contain Helium Passwords main ${passwords_head}" >&2
        return 1
    }

    cmp "${passwords_repo}/patches/helium-passwords/restore-password-autofill.patch" \
        "${root_dir}/patches/helium-passwords/restore-password-autofill.patch"
    cmp "${passwords_repo}/patches/helium-passwords/restore-password-ui.patch" \
        "${root_dir}/patches/helium-passwords/restore-password-ui.patch"
}

check_all() {
    check_shell
    "${root_dir}/helium-chromium/devutils/lint.py" -t "${root_dir}"
    "${root_dir}/scripts/chromium/generate-overlay-patch.sh" --check

    if find "${root_dir}/scripts" -type f -name '*.mjs' -print -quit | grep -q .; then
        check_javascript
    fi
    if find "${root_dir}/scripts" -type f -name '*.py' -print -quit | grep -q .; then
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

    local passwords_repo=${HELIUM_PASSWORDS_REPO:-"${root_dir}/../helium-passwords"}
    if [ -f "${root_dir}/go.mod" ] && [ -d "${passwords_repo}/.git" ]; then
        printf 'passwords_main=%s\n' "$(git -C "${passwords_repo}" rev-parse main)"
        if git -C "${root_dir}" merge-base --is-ancestor \
            "$(git -C "${passwords_repo}" rev-parse main)" HEAD; then
            printf 'passwords_backbone=contained\n'
        else
            printf 'passwords_backbone=behind\n'
        fi
    fi
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
