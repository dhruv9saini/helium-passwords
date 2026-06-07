#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: with-heartbeat.sh <command> [args...]" >&2
    exit 64
fi

interval="${HELIUM_SYNC_HEARTBEAT_INTERVAL:-120}"
case "$interval" in
    ''|*[!0-9]*)
        echo "HELIUM_SYNC_HEARTBEAT_INTERVAL must be a positive integer" >&2
        exit 64
        ;;
esac
if [ "$interval" -lt 1 ]; then
    echo "HELIUM_SYNC_HEARTBEAT_INTERVAL must be a positive integer" >&2
    exit 64
fi

display=("$@")
state_dir="$(mktemp -d)"
status_file="$state_dir/status"

printf '[heartbeat] %s starting command:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for arg in "${display[@]}"; do
    printf ' %q' "$arg"
done
printf '\n'

cleanup() {
    if [ -n "${cmd_pid:-}" ] && ! [ -f "$status_file" ]; then
        kill "$cmd_pid" 2>/dev/null || true
    fi
    rm -rf "$state_dir"
}
trap cleanup EXIT INT TERM

(
    set +e
    "$@"
    printf '%s\n' "$?" > "$status_file"
) &
cmd_pid="$!"
elapsed=0

while ! [ -f "$status_file" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$interval" ]; then
        printf '[heartbeat] %s command still running:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for arg in "${display[@]}"; do
            printf ' %q' "$arg"
        done
        printf '\n'
        elapsed=0
    fi
done

wait "$cmd_pid" || true
status="$(cat "$status_file")"

exit "$status"
