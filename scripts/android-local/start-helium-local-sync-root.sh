#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
There is no phone-local Helium sync service. Passwords and cookies use the
native browser bridge and the supervised HTTPS service on lm. This command is
retained only to fail closed if an old launcher still invokes it.
EOF
exit 2
