#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2154
set -euo pipefail

usage() {
	echo "usage: $0 <cycle|status|restore-drill> CONFIG [DESTINATION GENERATION DISPOSABLE_ROOT DRILL_NAME]" >&2
	exit 2
}

fail() {
	echo "native-session-capsule-backup: $*" >&2
	exit 1
}

require_safe_absolute() {
	[[ "$2" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "$1 must be a safe absolute path"
}

load_config() {
	local config=$1 key value
	[ -f "$config" ] && [ ! -L "$config" ] || fail "config must be a regular file"
	[ $((8#$(stat -c %a "$config"))) -le $((8#600)) ] || fail "config must be private"
	declare -gA seen=()
	while IFS='=' read -r key value || [ -n "${key}${value}" ]; do
		[ -n "$key" ] || continue
		[[ "$key" =~ ^[a-z_]+$ ]] || fail "invalid config key"
		case "$key" in
			version|source_device|profile|profile_root|guard_path|store|state_root|capsule_cli|gpg_home|gpg_recipient_a|gpg_recipient_b|ssh_user|ssh_identity|ssh_known_hosts|destination_a_host|destination_a_root|destination_b_host|destination_b_root) ;;
			*) fail "unknown config key: $key" ;;
		esac
		[ -z "${seen[$key]:-}" ] || fail "duplicate config key: $key"
		seen[$key]=1
		printf -v "$key" '%s' "$value"
	done <"$config"
	for key in version source_device profile profile_root guard_path store state_root \
		capsule_cli gpg_home gpg_recipient_a gpg_recipient_b ssh_user \
		ssh_identity ssh_known_hosts destination_a_host destination_a_root \
		destination_b_host destination_b_root; do
		[ -n "${!key:-}" ] || fail "missing config key: $key"
	done
	[ "$version" = 1 ] || fail "unsupported config version"
	[[ "$source_device" =~ ^(d|da|oneplus)$ ]] || fail "invalid source device"
	[[ "$profile" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "invalid profile"
	[[ "$ssh_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "invalid SSH user"
	case "$source_device" in
		d) expected_peer=da ;;
		da) expected_peer=d ;;
		oneplus) expected_peer=da ;;
	esac
	[ "$destination_a_host" = lm ] &&
		[ "$destination_b_host" = "$expected_peer" ] ||
		fail "destinations must be lm NAS then the fixed peer for $source_device"
	[ "$destination_a_root" = /srv/nas/helium-tab-recovery ] ||
		fail "destination A must be the Helium NAS namespace"
	[ "$destination_b_root" = /home/d/.local/share/helium-tab-recovery ] ||
		fail "destination B must be the Helium peer namespace"
	[ "$gpg_recipient_a" != "$gpg_recipient_b" ] || fail "recovery recipients must differ"
	[[ "$gpg_recipient_a" =~ ^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?$ ]] &&
		[[ "$gpg_recipient_b" =~ ^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?$ ]] ||
		fail "recovery recipients must be exact fingerprints"
	for key in profile_root guard_path store state_root capsule_cli gpg_home \
		ssh_identity ssh_known_hosts destination_a_root destination_b_root; do
		require_safe_absolute "$key" "${!key}"
	done
	for key in capsule_cli ssh_identity ssh_known_hosts; do
		[ -f "${!key}" ] && [ ! -L "${!key}" ] || fail "$key must be a regular file"
	done
	for key in ssh_identity ssh_known_hosts; do
		[ "$(stat -c %u "${!key}")" -eq "$(id -u)" ] &&
			[ $((8#$(stat -c %a "${!key}") & 8#077)) -eq 0 ] ||
			fail "$key must be source-owned and private"
	done
	[ -x "$capsule_cli" ] || fail "capsule CLI is not executable"
	[ -d "$gpg_home" ] && [ ! -L "$gpg_home" ] || fail "GnuPG home is invalid"
	[ $((8#$(stat -c %a "$gpg_home") & 8#077)) -eq 0 ] ||
		fail "GnuPG home must be private"
	[ "$(uname -n | cut -d. -f1)" = "$source_device" ] ||
		fail "capture must run on source device $source_device"
	install -d -m0700 "$state_root" "$state_root/ciphertext"
}

ssh_args() {
	SSH_ARGS=(-F none -o BatchMode=yes -o IdentitiesOnly=yes \
		-o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no \
		-o StrictHostKeyChecking=yes -o GlobalKnownHostsFile="$ssh_known_hosts" \
		-o UserKnownHostsFile="$ssh_known_hosts" -i "$ssh_identity" -l "$ssh_user")
}

verify_remote() {
	local destination=$1 host root name mount_target
	if [ "$destination" = a ]; then
		host=$destination_a_host
		root=$destination_a_root
	else
		host=$destination_b_host
		root=$destination_b_root
	fi
	name=$(ssh "${SSH_ARGS[@]}" "$host" "uname -n")
	[ "${name%%.*}" = "$host" ] || fail "remote host identity mismatch: $host"
	ssh "${SSH_ARGS[@]}" "$host" "test -d '$root' && test -w '$root'"
	if [ "$destination" = a ]; then
		mount_target=$(ssh "${SSH_ARGS[@]}" "$host" \
			"findmnt --noheadings --output TARGET --target '$root'")
		[ -n "$mount_target" ] && [ "$mount_target" != / ] ||
			fail "lm recovery destination is not a separate NAS mount"
	fi
}

remote_leaf() {
	local destination=$1 generation=$2 root host
	case "$destination" in
		a) root=$destination_a_root; host=$destination_a_host ;;
		b) root=$destination_b_root; host=$destination_b_host ;;
		*) fail "destination must be a or b" ;;
	esac
	printf '%s|%s/%s/%s/native-session-capsule/generations/%s.tar.gpg' \
		"$host" "$root" "$source_device" "$profile" "$generation"
}

generation_from_json() {
	jq -er '.generation | select(test("^[0-9]{8}T[0-9]{6}\\.[0-9]{9}Z-[a-f0-9]{16}$"))' "$1"
}

cycle() {
	local capture_json generation archive destination recipient pair host remote
	local hash hash_file size ciphertext_sha256_a ciphertext_sha256_b
	local ciphertext_size_a ciphertext_size_b
	capture_json=$(mktemp "$state_root/.capture.XXXXXX")
	trap 'find "$capture_json" -delete 2>/dev/null || true' RETURN
	if ! "$capsule_cli" capture --store "$store" --profile-root "$profile_root" \
		--guard "$guard_path" --device "$source_device" --profile "$profile" \
		>"$capture_json"; then
		fail "capture refused; browser may be active or the native inventory is invalid"
	fi
	generation=$(generation_from_json "$capture_json")
	ssh_args
	for destination in a b; do
		verify_remote "$destination"
		if [ "$destination" = a ]; then
			recipient=$gpg_recipient_a
		else
			recipient=$gpg_recipient_b
		fi
		archive="$state_root/ciphertext/$generation.$destination.tar.gpg"
		[ ! -e "$archive" ] || fail "ciphertext already exists"
		tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
			-C "$store/generations" -cf - "$generation" |
			gpg --homedir "$gpg_home" --batch --yes --trust-model always \
				--recipient "$recipient" --encrypt --output "$archive"
		chmod 600 "$archive"
		hash=$(sha256sum "$archive" | awk '{print $1}')
		size=$(stat -c %s "$archive")
		printf -v "ciphertext_sha256_$destination" '%s' "$hash"
		printf -v "ciphertext_size_$destination" '%s' "$size"
		hash_file="$archive.sha256"
		printf '%s\n' "$hash" >"$hash_file"
		chmod 600 "$hash_file"
		pair=$(remote_leaf "$destination" "$generation")
		host=${pair%%|*}
		remote=${pair#*|}
		ssh "${SSH_ARGS[@]}" "$host" "test -d '${remote%/*}' && test -w '${remote%/*}'"
		rsync -e "ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=$ssh_known_hosts -o UserKnownHostsFile=$ssh_known_hosts -i $ssh_identity -l $ssh_user" \
			--chmod=F600 -- "$archive" "$host:$remote.partial"
		rsync -e "ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=$ssh_known_hosts -o UserKnownHostsFile=$ssh_known_hosts -i $ssh_identity -l $ssh_user" \
			--chmod=F600 -- "$hash_file" "$host:$remote.sha256.partial"
		ssh "${SSH_ARGS[@]}" "$host" \
			"test \"\$(sha256sum '$remote.partial' | awk '{print \$1}')\" = '$hash' && test \"\$(cat '$remote.sha256.partial')\" = '$hash' && test ! -e '$remote' && test ! -e '$remote.sha256' && mv '$remote.partial' '$remote' && mv '$remote.sha256.partial' '$remote.sha256'"
	done
	cat >"$state_root/status.tmp" <<EOF
version=1
mechanism=native-session-capsule
state=healthy
source_device=$source_device
profile=$profile
generation=$generation
completed_unix=$(date +%s)
destination_a_host=$destination_a_host
destination_b_host=$destination_b_host
ciphertext_sha256_a=$ciphertext_sha256_a
ciphertext_sha256_b=$ciphertext_sha256_b
ciphertext_size_a=$ciphertext_size_a
ciphertext_size_b=$ciphertext_size_b
EOF
	chmod 600 "$state_root/status.tmp"
	mv "$state_root/status.tmp" "$state_root/status"
	"$capsule_cli" retention-apply --store "$store" >/dev/null
	find "$state_root/ciphertext" -maxdepth 1 -type f \
		-name "$generation.*.tar.gpg*" -delete
	printf 'state=healthy\ngeneration=%s\n' "$generation"
}

status() {
	local state generation completed pair host remote destination expected_hash
	local expected_size actual_hash actual_size
	[ -f "$state_root/status" ] && [ ! -L "$state_root/status" ] || fail "no successful cycle"
	state=$(awk -F= '$1=="state"{print $2}' "$state_root/status")
	generation=$(awk -F= '$1=="generation"{print $2}' "$state_root/status")
	completed=$(awk -F= '$1=="completed_unix"{print $2}' "$state_root/status")
	[ "$state" = healthy ] && [[ "$completed" =~ ^[0-9]+$ ]] || fail "invalid status"
	[ $(( $(date +%s) - completed )) -le 86400 ] || fail "last stopped capture is stale"
	"$capsule_cli" validate --store "$store" --generation "$generation" >/dev/null
	ssh_args
	for destination in a b; do
		verify_remote "$destination"
		expected_hash=$(awk -F= -v key="ciphertext_sha256_$destination" \
			'$1==key{print $2}' "$state_root/status")
		expected_size=$(awk -F= -v key="ciphertext_size_$destination" \
			'$1==key{print $2}' "$state_root/status")
		[[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] &&
			[[ "$expected_size" =~ ^[1-9][0-9]*$ ]] ||
			fail "invalid ciphertext status"
		pair=$(remote_leaf "$destination" "$generation")
		host=${pair%%|*}; remote=${pair#*|}
		actual_hash=$(ssh "${SSH_ARGS[@]}" "$host" "sha256sum '$remote'" |
			awk '{print $1}')
		actual_size=$(ssh "${SSH_ARGS[@]}" "$host" "stat -c %s '$remote'")
		[ "$actual_hash" = "$expected_hash" ] &&
			[ "$actual_size" = "$expected_size" ] &&
			[ "$(ssh "${SSH_ARGS[@]}" "$host" "cat '$remote.sha256'")" = "$expected_hash" ] ||
			fail "remote ciphertext does not match status"
	done
	cat "$state_root/status"
}

restore_drill() {
	local destination=$1 generation=$2 disposable_root=$3 drill_name=$4
	local pair host remote encrypted staging extracted plaintext member
	[[ "$drill_name" =~ ^drill-native-[a-z0-9._-]+$ ]] || fail "invalid drill name"
	pair=$(remote_leaf "$destination" "$generation")
	host=${pair%%|*}; remote=${pair#*|}
	staging=$(mktemp -d "$state_root/.restore.XXXXXX")
	trap 'find "$staging" -depth -delete 2>/dev/null || true' RETURN
	ssh_args
	verify_remote "$destination"
	encrypted="$staging/generation.tar.gpg"
	rsync -e "ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=$ssh_known_hosts -o UserKnownHostsFile=$ssh_known_hosts -i $ssh_identity -l $ssh_user" \
		-- "$host:$remote" "$encrypted"
	rsync -e "ssh -F none -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes -o RequestTTY=no -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=$ssh_known_hosts -o UserKnownHostsFile=$ssh_known_hosts -i $ssh_identity -l $ssh_user" \
		-- "$host:$remote.sha256" "$staging/generation.sha256"
	[ "$(sha256sum "$encrypted" | awk '{print $1}')" = \
		"$(cat "$staging/generation.sha256")" ] ||
		fail "fetched capsule ciphertext checksum mismatch"
	extracted="$staging/plain"
	install -d -m0700 "$extracted"
	plaintext="$staging/generation.tar"
	gpg --homedir "$gpg_home" --batch --output "$plaintext" --decrypt "$encrypted"
	chmod 600 "$plaintext"
	while IFS= read -r member; do
		case "$member" in
			"$generation"|"$generation/"|"$generation/"*) ;;
			*) fail "archive member escapes the selected generation" ;;
		esac
		[[ "/$member/" != *"/../"* ]] || fail "archive contains parent traversal"
	done < <(tar --list --file "$plaintext")
	tar --list --verbose --file "$plaintext" |
		awk 'substr($1,1,1) !~ /^[-d]$/ { exit 1 }' ||
		fail "archive contains a link or special file"
	tar --extract --file "$plaintext" --directory "$extracted" \
		--no-same-owner --no-same-permissions
	local drill_store="$staging/store"
	install -d -m0700 "$drill_store/generations" "$drill_store/quarantine"
	mv "$extracted/$generation" "$drill_store/generations/$generation"
	"$capsule_cli" validate --store "$drill_store" --generation "$generation" >/dev/null
	"$capsule_cli" restore --store "$drill_store" --generation "$generation" \
		--disposable-root "$disposable_root" --profile "$drill_name"
}

[ "$#" -ge 2 ] || usage
command_name=$1
config_file=$2
shift 2
load_config "$config_file"
case "$command_name" in
	cycle) [ "$#" -eq 0 ] || usage; cycle ;;
	status) [ "$#" -eq 0 ] || usage; status ;;
	restore-drill) [ "$#" -eq 4 ] || usage; restore_drill "$@" ;;
	*) usage ;;
esac
