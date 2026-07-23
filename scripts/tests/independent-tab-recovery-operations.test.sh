#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
temporary=$(mktemp -d /tmp/helium-independent-tab-recovery.XXXXXX)
cleanup() {
	local result=$?
	find "$temporary" -depth -delete 2>/dev/null || true
	return "$result"
}
trap cleanup EXIT

install -d -m0700 "$temporary/bin" "$temporary/raw-profile/Default/Sessions" \
	"$temporary/raw-store" "$temporary/raw-state" "$temporary/journal/closed" \
	"$temporary/journal-store" "$temporary/journal-state" \
	"$temporary/destination-a" "$temporary/destination-b"
find "$temporary/raw-profile" "$temporary/journal" -type d -exec chmod 700 {} +
printf 'helium-tab-journal-root-v1\n' \
	>"$temporary/journal/.helium-tab-journal-root-v1"
chmod 600 "$temporary/journal/.helium-tab-journal-root-v1"
go build -o "$temporary/bin/helium-session-capsule" \
	"$repo_root/cmd/helium-session-capsule"
go build -o "$temporary/bin/helium-tab-journal" \
	"$repo_root/cmd/helium-tab-journal"

# Chromium v150 cleartext session framing: SSNS, version 3, one normal command,
# and the required complete-initial-state marker (id 255).
for family in Session Tabs; do
	printf '\x53\x4e\x53\x53\x03\x00\x00\x00\x01\x00\x01\x01\x00\xff' \
		>"$temporary/raw-profile/Default/Sessions/${family}_100"
	chmod 600 "$temporary/raw-profile/Default/Sessions/${family}_100"
done

checkpoint='{"schema_version":1,"windows":[{"index":0,"groups":[],"tabs":[{"index":0,"active":true,"pinned":false,"group":"","url":"https://journal.invalid/","title":"Journal"}]}]}'
epoch=20260722t120000z-synthetic
occurred=$(($(date +%s) * 1000))
event_material=$(printf '\n%s\n1\n%s\ninitial-checkpoint\n%s' \
	"$epoch" "$occurred" "$checkpoint")
event_hash=$(printf '%s' "$event_material" | sha256sum | awk '{print $1}')
sqlite3 "$temporary/journal/active.sqlite" <<SQL
PRAGMA journal_mode=WAL;
CREATE TABLE events(
  epoch TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  occurred_at_unix_millis TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  previous_sha256 TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  PRIMARY KEY(epoch, sequence)
) STRICT;
INSERT INTO events VALUES(
  '$epoch',1,'$occurred','initial-checkpoint',
  '$checkpoint','','$event_hash'
);
SQL
chmod 600 "$temporary/journal/active.sqlite"

gpg_home="$temporary/gnupg"
install -d -m0700 "$gpg_home"
for identity in raw-a raw-b; do
	gpg --homedir "$gpg_home" --batch --pinentry-mode loopback --passphrase '' \
		--quick-generate-key "$identity@example.invalid" default default 1d \
		>/dev/null 2>&1
done
mapfile -t gpg_fingerprints < <(
	gpg --homedir "$gpg_home" --batch --with-colons --list-keys |
		awk -F: '$1=="pub"{want=1;next} want && $1=="fpr"{print $10;want=0}'
)
[ "${#gpg_fingerprints[@]}" -eq 2 ]

for destination in a b; do
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-subj "/CN=journal-$destination.invalid" \
		-keyout "$temporary/cms-$destination.key" \
		-out "$temporary/cms-$destination.crt" >/dev/null 2>&1
	chmod 600 "$temporary/cms-$destination.key" \
		"$temporary/cms-$destination.crt"
done

printf 'synthetic ssh identity\n' >"$temporary/ssh-identity"
printf 'synthetic known hosts\n' >"$temporary/known-hosts"
chmod 600 "$temporary/ssh-identity" "$temporary/known-hosts"

cat >"$temporary/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ] && [[ "$1" == -* ]]; do
	case "$1" in
		-F|-o|-i|-l) shift 2 ;;
		*) exit 90 ;;
	esac
done
host=$1
shift
[ "$host" = lm ] || [ "$host" = da ]
command_text=${1//\/srv\/nas\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_A}
command_text=${command_text//\/home\/d\/.local\/share\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_B}
HELIUM_TEST_REMOTE_HOST=$host bash -c "$command_text"
EOF

cat >"$temporary/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
	case "$1" in
		-e|--chmod=*) if [ "$1" = -e ]; then shift 2; else shift; fi ;;
		--) shift; break ;;
		-*) shift ;;
		*) break ;;
	esac
done
[ "$#" -eq 2 ]
source_host=
destination_host=
if [[ "$1" == *:* ]]; then source_host=${1%%:*}; fi
if [[ "$2" == *:* ]]; then destination_host=${2%%:*}; fi
source_file=${1#*:}
destination_file=${2#*:}
case "$source_host" in
	lm) source_file=${source_file/\/srv\/nas\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_A} ;;
	da) source_file=${source_file/\/home\/d\/.local\/share\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_B} ;;
esac
case "$destination_host" in
	lm) destination_file=${destination_file/\/srv\/nas\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_A} ;;
	da) destination_file=${destination_file/\/home\/d\/.local\/share\/helium-tab-recovery/$HELIUM_TEST_DESTINATION_B} ;;
esac
install -m0600 "$source_file" "$destination_file"
EOF

cat >"$temporary/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${HELIUM_TEST_REMOTE_HOST:-}" ]; then
	printf '%s\n' "$HELIUM_TEST_REMOTE_HOST"
else
	printf 'd\n'
fi
EOF

cat >"$temporary/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '/synthetic-separate-nas\n'
EOF
chmod 700 "$temporary/bin/ssh" "$temporary/bin/rsync" \
	"$temporary/bin/uname" "$temporary/bin/findmnt"
export HELIUM_TEST_DESTINATION_A="$temporary/destination-a"
export HELIUM_TEST_DESTINATION_B="$temporary/destination-b"

raw_config="$temporary/raw.conf"
cat >"$raw_config" <<EOF
version=1
source_device=d
profile=default
profile_root=$temporary/raw-profile
guard_path=$temporary/browser.guard
store=$temporary/raw-store
state_root=$temporary/raw-state
capsule_cli=$temporary/bin/helium-session-capsule
gpg_home=$gpg_home
gpg_recipient_a=${gpg_fingerprints[0]}
gpg_recipient_b=${gpg_fingerprints[1]}
ssh_user=d
ssh_identity=$temporary/ssh-identity
ssh_known_hosts=$temporary/known-hosts
destination_a_host=lm
destination_a_root=/srv/nas/helium-tab-recovery
destination_b_host=da
destination_b_root=/home/d/.local/share/helium-tab-recovery
EOF
chmod 600 "$raw_config"
install -d -m0700 \
	"$temporary/destination-a/d/default/native-session-capsule/generations" \
	"$temporary/destination-b/d/default/native-session-capsule/generations"

journal_config="$temporary/journal.conf"
cat >"$journal_config" <<EOF
version=1
source_device=d
profile=default
journal_root=$temporary/journal
store=$temporary/journal-store
state_root=$temporary/journal-state
journal_cli=$temporary/bin/helium-tab-journal
cms_certificate_a=$temporary/cms-a.crt
cms_certificate_b=$temporary/cms-b.crt
cms_private_key_a=$temporary/cms-a.key
cms_private_key_b=$temporary/cms-b.key
ssh_user=d
ssh_identity=$temporary/ssh-identity
ssh_known_hosts=$temporary/known-hosts
destination_a_host=lm
destination_a_root=/srv/nas/helium-tab-recovery
destination_b_host=da
destination_b_root=/home/d/.local/share/helium-tab-recovery
EOF
chmod 600 "$journal_config"
install -d -m0700 \
	"$temporary/destination-a/d/default/tab-event-journal/generations" \
	"$temporary/destination-b/d/default/tab-event-journal/generations"

export PATH="$temporary/bin:$PATH"
raw_result=$("$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	cycle "$raw_config")
raw_generation=$(awk -F= '$1=="generation"{print $2}' <<<"$raw_result")
[[ "$raw_generation" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]]
"$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	status "$raw_config" >/dev/null
for root in "$temporary/destination-a" "$temporary/destination-b"; do
	test -s "$root/d/default/native-session-capsule/generations/$raw_generation.tar.gpg"
	test -s "$root/d/default/native-session-capsule/generations/$raw_generation.tar.gpg.sha256"
done
test -z "$(find "$temporary/raw-state/ciphertext" -type f -print -quit)"

raw_disposable="$temporary/raw-disposable"
install -d -m0700 "$raw_disposable"
printf 'helium-native-session-disposable-root-v1\n' \
	>"$raw_disposable/.helium-native-session-disposable-root-v1"
chmod 600 "$raw_disposable/.helium-native-session-disposable-root-v1"
"$repo_root/scripts/tabs/native-session-capsule-backup.sh" restore-drill \
	"$raw_config" a "$raw_generation" "$raw_disposable" drill-native-proof \
	>/dev/null
"$temporary/bin/helium-session-capsule" validate-restore \
	--destination "$raw_disposable/drill-native-proof" >/dev/null
raw_peer="$temporary/destination-b/d/default/native-session-capsule/generations/$raw_generation.tar.gpg"
printf '%064d\n' 0 >"$raw_peer.sha256"
if "$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	status "$raw_config" >/dev/null 2>&1; then
	echo "tampered capsule checksum sidecar passed status" >&2
	exit 1
fi
sha256sum "$raw_peer" | awk '{print $1}' >"$raw_peer.sha256"

journal_result=$("$repo_root/scripts/tabs/tab-journal-backup.sh" \
	cycle "$journal_config")
journal_generation=$(awk -F= '$1=="generation"{print $2}' <<<"$journal_result")
[[ "$journal_generation" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[a-f0-9]{16}$ ]]
"$repo_root/scripts/tabs/tab-journal-backup.sh" status "$journal_config" >/dev/null
for root in "$temporary/destination-a" "$temporary/destination-b"; do
	test -s "$root/d/default/tab-event-journal/generations/$journal_generation.tar.cms"
	test -s "$root/d/default/tab-event-journal/generations/$journal_generation.tar.cms.sha256"
done
test -z "$(find "$temporary/journal-state/ciphertext" -type f -print -quit)"

journal_disposable="$temporary/journal-disposable"
install -d -m0700 "$journal_disposable"
printf 'helium-tab-journal-disposable-root-v1\n' \
	>"$journal_disposable/.helium-tab-journal-disposable-root-v1"
chmod 600 "$journal_disposable/.helium-tab-journal-disposable-root-v1"
"$repo_root/scripts/tabs/tab-journal-backup.sh" restore-drill \
	"$journal_config" b "$journal_generation" "$journal_disposable" \
	drill-journal-proof >/dev/null
"$temporary/bin/helium-tab-journal" validate-catalog \
	--destination "$journal_disposable/drill-journal-proof" >/dev/null
grep -q 'journal.invalid' \
	"$journal_disposable/drill-journal-proof/tabs.html"
journal_nas="$temporary/destination-a/d/default/tab-event-journal/generations/$journal_generation.tar.cms"
printf tamper >>"$journal_nas"
if "$repo_root/scripts/tabs/tab-journal-backup.sh" \
	status "$journal_config" >/dev/null 2>&1; then
	echo "tampered journal ciphertext passed status" >&2
	exit 1
fi
"$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	status "$raw_config" >/dev/null
truncate -s -6 "$journal_nas"
"$repo_root/scripts/tabs/tab-journal-backup.sh" \
	status "$journal_config" >/dev/null

# A capsule-only fault must likewise leave the journal path healthy.
printf '%064d\n' 0 >"$raw_peer.sha256"
if "$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	status "$raw_config" >/dev/null 2>&1; then
	echo "second capsule checksum fault passed status" >&2
	exit 1
fi
"$repo_root/scripts/tabs/tab-journal-backup.sh" \
	status "$journal_config" >/dev/null
sha256sum "$raw_peer" | awk '{print $1}' >"$raw_peer.sha256"

# A held browser lifetime guard must block raw capture without touching the
# independent journal mechanism.
"$temporary/bin/helium-session-capsule" guard-run \
	--guard "$temporary/browser.guard" -- sh -c 'sleep 5' &
guard_pid=$!
for _ in $(seq 1 50); do
	if [ -s "$temporary/browser.guard" ] || [ -e "$temporary/browser.guard" ]; then
		break
	fi
	sleep 0.02
done
if "$repo_root/scripts/tabs/native-session-capsule-backup.sh" \
	cycle "$raw_config" >/dev/null 2>&1; then
	echo "raw capsule captured while browser lifetime guard was held" >&2
	kill "$guard_pid" 2>/dev/null || true
	exit 1
fi
kill "$guard_pid" 2>/dev/null || true
wait "$guard_pid" 2>/dev/null || true
"$repo_root/scripts/tabs/tab-journal-backup.sh" status "$journal_config" \
	>/dev/null

echo "independent_tab_recovery_operations=passed"
