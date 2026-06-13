#!/system/bin/sh
set -eu

layout_dir=/data/system/devices/keylayout
[ -d "$layout_dir" ] || exit 0

rewrite_layout() {
  file=$1
  tmp="$file.tmp.$$"

  [ -f "$file" ] || return 0
  [ -f "$file.archdesktop.bak" ] || cp -p "$file" "$file.archdesktop.bak" 2>/dev/null || true

  awk '
    $1 == "key" && $2 == "100" { $3 = "ALT_RIGHT" }
    $1 == "key" && $2 == "125" { $3 = "META_LEFT" }
    $1 == "key" && $2 == "126" { $3 = "META_RIGHT" }
    { print }
  ' "$file" >"$tmp"

  if ! cmp -s "$tmp" "$file" 2>/dev/null; then
    cat "$tmp" >"$file"
    chmod 0644 "$file" 2>/dev/null || true
    restorecon "$file" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp"
}

find "$layout_dir" -maxdepth 1 -type f \( \
  -name '*Magic_Keyboard*.kl' -o \
  -name 'Apple_*Keyboard*.kl' -o \
  -name 'Vendor_05ac_Product_*.kl' \
\) 2>/dev/null | while read -r file; do
  rewrite_layout "$file"
done
