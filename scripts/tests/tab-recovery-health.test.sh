#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
temporary=$(mktemp -d /tmp/helium-tab-recovery-health.XXXXXX)
cleanup() {
	local result=$?
	find "$temporary" -depth -delete 2>/dev/null || true
	return "$result"
}
trap cleanup EXIT
install -d -m0700 "$temporary/status"

mechanisms=(
	chromium-native-session
	neutral-topology
	full-profile
	native-session-capsule
	tab-event-journal
)
for mechanism in "${mechanisms[@]}"; do
	cat >"$temporary/status/$mechanism.status" <<EOF
version=1
mechanism=$mechanism
state=healthy
source_device=d
profile=default
completed_unix=$(date +%s)
evidence=synthetic-$mechanism
EOF
	chmod 600 "$temporary/status/$mechanism.status"
done

health=$("$repo_root/scripts/tabs/tab-recovery-health.sh" \
	"$temporary/status" d default)
[ "$(jq '.mechanisms | length' <<<"$health")" -eq 5 ]
[ "$(jq '[.mechanisms[].mechanism] | unique | length' <<<"$health")" -eq 5 ]
jq -e '.healthy == true and
  [.mechanisms[].state] == ["healthy","healthy","healthy","healthy","healthy"]' \
	<<<"$health" >/dev/null

# One failed producer must turn only its own mechanism red. Four replicas or
# healthy sibling mechanisms cannot hide the absent fifth recovery path.
find "$temporary/status/native-session-capsule.status" -delete
if unhealthy=$("$repo_root/scripts/tabs/tab-recovery-health.sh" \
	"$temporary/status" d default); then
	echo "five-path health passed with a missing mechanism" >&2
	exit 1
fi
[ "$(jq '.mechanisms | length' <<<"$unhealthy")" -eq 5 ]
jq -e '.healthy == false and
  ([.mechanisms[] | select(.state == "unhealthy")] | length) == 1 and
  (.mechanisms[] | select(.mechanism == "native-session-capsule") |
    .reason == "missing_or_unsafe")' <<<"$unhealthy" >/dev/null
jq -e '([.mechanisms[] |
  select(.mechanism != "native-session-capsule" and .state == "healthy")] |
  length) == 4' <<<"$unhealthy" >/dev/null

# A copied proof cannot claim a different device namespace.
sed 's/source_device=d/source_device=da/' \
	"$temporary/status/tab-event-journal.status" \
	>"$temporary/status/tab-event-journal.status.tmp"
mv "$temporary/status/tab-event-journal.status.tmp" \
	"$temporary/status/tab-event-journal.status"
chmod 600 "$temporary/status/tab-event-journal.status"
if "$repo_root/scripts/tabs/tab-recovery-health.sh" \
	"$temporary/status" d default >/dev/null; then
	echo "wrong-device proof passed health" >&2
	exit 1
fi

echo "tab_recovery_health=passed"
