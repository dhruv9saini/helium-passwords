#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: run-soft-timeout.sh <minutes> <command> [args...]" >&2
    exit 64
fi

minutes="$1"
shift

case "$minutes" in
    ''|*[!0-9]*)
        echo "timeout minutes must be a positive integer" >&2
        exit 64
        ;;
esac
if [ "$minutes" -lt 1 ]; then
    echo "timeout minutes must be a positive integer" >&2
    exit 64
fi

set +e
timeout --kill-after=5m "${minutes}m" "$@"
status="$?"
set -e

case "$status" in
    0)
        build_status=success
        ;;
    124|137|143)
        build_status=timeout
        ;;
    *)
        build_status=failure
        ;;
esac

echo "build_status=$build_status"
echo "exit_status=$status"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "build_status=$build_status"
        echo "exit_status=$status"
    } >>"$GITHUB_OUTPUT"
fi

if [ "$build_status" != success ]; then
    echo "command ended with status $status; reporting $build_status so later cache/artifact steps can run" >&2
fi

exit 0
