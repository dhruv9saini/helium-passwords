#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 FLAGS_GN ARGS_GN GN_ARGS_RESOLVED NEW_EFFECTIVE_LOCKED_ARGS" >&2
  exit 64
fi

flags=$(realpath -e "$1")
args=$(realpath -e "$2")
resolved=$(realpath -e "$3")
effective=$(realpath -m "$4")

for file in "$flags" "$args" "$resolved"; do
  [[ -f "$file" && ! -L "$file" ]] || {
    echo "locked GN input must be a regular non-symlink file" >&2
    exit 1
  }
done
[[ ! -e "$effective" && ! -L "$effective" ]] || {
  echo "effective locked GN output already exists" >&2
  exit 1
}
[[ -d "$(dirname "$effective")" && ! -L "$(dirname "$effective")" ]] || {
  echo "effective locked GN output parent is missing or unsafe" >&2
  exit 1
}

flags_size=$(stat -c %s "$flags")
[[ "$flags_size" -gt 0 ]] && cmp -n "$flags_size" "$flags" "$args" || {
  echo "Android args.gn does not begin with its exact locked flags.gn" >&2
  exit 1
}

declare -A locked=()
declare -A expected=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^([a-z][a-z0-9_]*)=(.+)$ ]] || {
    echo "locked flags.gn contains a malformed assignment" >&2
    exit 1
  }
  key=${BASH_REMATCH[1]}
  value=${BASH_REMATCH[2]}
  [[ ! -v "locked[$key]" ]] || {
    echo "locked flags.gn assigns $key more than once" >&2
    exit 1
  }
  locked[$key]=1
  expected[$key]="$key = $value"
done < "$flags"
[[ ${#locked[@]} -gt 0 ]] || {
  echo "locked flags.gn has no assignments" >&2
  exit 1
}

while IFS= read -r line || [[ -n "$line" ]]; do
  for key in "${!locked[@]}"; do
    if [[ "$line" =~ (^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$) ]]; then
      echo "Android args.gn mentions locked key after flags.gn: $key" >&2
      exit 1
    fi
  done
done < <(tail -c "+$((flags_size + 1))" "$args")

temporary=$(mktemp "$(dirname "$effective")/.locked-gn-args.XXXXXX")
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT
chmod 0600 "$temporary"
while IFS= read -r key; do
  line=${expected[$key]}
  [[ "$(grep -Fxc "$line" "$resolved")" -eq 1 ]] || {
    echo "effective GN value does not match locked flags.gn: $key" >&2
    exit 1
  }
  printf '%s\n' "$line" >> "$temporary"
done < <(printf '%s\n' "${!locked[@]}" | LC_ALL=C sort)
mv -T "$temporary" "$effective"
trap - EXIT

printf 'locked_gn_args_sha256=%s\n' \
  "$(sha256sum "$effective" | cut -d' ' -f1)"
printf 'locked_gn_key_count=%s\n' "${#locked[@]}"
printf 'locked_gn_args=verified\n'
