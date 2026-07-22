#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
CDP password seeding has been removed. Enroll this profile with helium-sync,
start the native browser bridge in pending pull-only mode, verify both browser
state cursors, stop the browser, and run helium-sync enrollment-complete.
EOF
exit 2
