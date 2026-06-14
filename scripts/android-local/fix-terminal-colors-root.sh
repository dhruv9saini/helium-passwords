#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}

/system/bin/chroot "$ROOT" /usr/bin/env \
  DISPLAY=:1 \
  XDG_RUNTIME_DIR=/tmp/runtime-root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  sh -s <<'EOF'
set -eu

set_config_line() {
  file=$1
  prefix=$2
  line=$3
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "^$prefix" "$file"; then
    escaped=$(printf '%s' "$line" | sed 's/[\/&]/\\&/g')
    sed -i "s/^$prefix.*/$escaped/" "$file"
  else
    printf '%s\n' "$line" >>"$file"
  fi
}

set_tmux_line() {
  conf=$1
  key=$2
  value=$3
  if grep -q "^set -g $key" "$conf"; then
    escaped=$(printf '%s' "set -g $key $value" | sed 's/[\/&]/\\&/g')
    sed -i "s/^set -g $key.*/$escaped/" "$conf"
  else
    printf 'set -g %s %s\n' "$key" "$value" >>"$conf"
  fi
}

write_user_colors() {
  home=$1
  mkdir -p "$home/.config/tmux" "$home/.config/shell"
  conf="$home/.config/tmux/tmux.conf"
  touch "$conf"

  set_tmux_line "$conf" default-style '"fg=white,bg=black"'
  set_tmux_line "$conf" window-style '"fg=white,bg=black"'
  set_tmux_line "$conf" window-active-style '"fg=white,bg=black"'
  set_tmux_line "$conf" status-style '"bg=black,fg=white"'
  set_tmux_line "$conf" message-style '"bg=black,fg=white"'
  set_tmux_line "$conf" mode-style '"bg=white,fg=black"'
  set_tmux_line "$conf" pane-border-style '"fg=white"'
  set_tmux_line "$conf" pane-active-border-style '"fg=white"'
  set_tmux_line "$conf" window-status-current-style '"bg=white,fg=black"'
  set_tmux_line "$conf" window-status-style '"bg=black,fg=white"'

  cat > "$home/.config/Xresources" <<'XEOF'
Xft.dpi: 120
Xft.antialias: true
Xft.hinting: true
*.foreground: #ffffff
*.background: #000000
Zutty.foreground: #ffffff
Zutty.background: #000000
Zutty.fg: #ffffff
Zutty.bg: #000000
Zutty.cr: #ffffff
Zutty.font: IosevkaNerdFontMono
Zutty.fontsize: 15
XEOF

  set_config_line "$home/.config/shell/chroot-shell.sh" 'export ZUTTY_FG=' 'export ZUTTY_FG="${ZUTTY_FG:-#ffffff}"'
  set_config_line "$home/.config/shell/chroot-shell.sh" 'export ZUTTY_BG=' 'export ZUTTY_BG="${ZUTTY_BG:-#000000}"'
  set_config_line "$home/.config/shell/chroot-shell.sh" 'export ZUTTY_CURSOR=' 'export ZUTTY_CURSOR="${ZUTTY_CURSOR:-#ffffff}"'
  set_config_line "$home/.config/shell/chroot-shell.sh" 'export COLORTERM=' 'export COLORTERM="${COLORTERM:-truecolor}"'
}

write_user_colors /root
write_user_colors /home/dhruv

uid=$(id -u dhruv 2>/dev/null || true)
gid=$(id -g dhruv 2>/dev/null || true)
if [ -n "$uid" ] && [ -n "$gid" ]; then
  chown -R "$uid:$gid" /home/dhruv/.config/tmux /home/dhruv/.config/Xresources /home/dhruv/.config/shell
fi

xrdb -merge /root/.config/Xresources >/dev/null 2>&1 || true

if tmux ls >/dev/null 2>&1; then
  tmux source-file /root/.config/tmux/tmux.conf >/dev/null 2>&1 || true
  tmux set -g default-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g window-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g window-active-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g status-style 'bg=black,fg=white' >/dev/null 2>&1 || true
  tmux set -g message-style 'bg=black,fg=white' >/dev/null 2>&1 || true
  tmux set -g pane-border-style 'fg=white' >/dev/null 2>&1 || true
  tmux set -g pane-active-border-style 'fg=white' >/dev/null 2>&1 || true
  tmux set -g window-status-current-style 'bg=white,fg=black' >/dev/null 2>&1 || true
  tmux set -g window-status-style 'bg=black,fg=white' >/dev/null 2>&1 || true
  tmux refresh-client -S >/dev/null 2>&1 || true
  tmux send-keys -t x11 C-l >/dev/null 2>&1 || true
fi
EOF
