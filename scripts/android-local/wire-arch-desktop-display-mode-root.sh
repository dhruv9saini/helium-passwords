#!/system/bin/sh
set -eu

root=${ARCH_CHROOT:-/data/local/chroots/arch}

wire_after_match() {
  file=$1
  marker=$2
  pattern=$3
  line=$4

  [ -f "$file" ] || return 0

  tmp="$root/tmp/$(basename "$file").$$"
  awk -v marker="$marker" -v pattern="$pattern" -v line="$line" '
    index($0, marker) {
      next
    }
    {
      print
      if ($0 ~ pattern) {
        print ""
        print line
      }
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
  chmod 755 "$file"
}

wire_after_match \
  "$root/arch-desktop-resume-root.sh" \
  "arch-desktop-display-mode-root.sh\" apply" \
  "pkill -f .*desktop-session-watch\\.sh" \
  "\"$root/arch-desktop-display-mode-root.sh\" apply >>\"\$LOG\" 2>&1 || true"

wire_after_match \
  "$root/arch-desktop-hibernate-root.sh" \
  "arch-desktop-display-mode-root.sh\" reset" \
  "stop-arch-x11-root\\.sh" \
  "\"$root/arch-desktop-display-mode-root.sh\" reset >>\"\$LOG\" 2>&1 || true"
