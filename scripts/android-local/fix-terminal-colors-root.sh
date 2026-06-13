#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}

/system/bin/chroot "$ROOT" /usr/bin/env \
  DISPLAY=:1 \
  XDG_RUNTIME_DIR=/tmp/runtime-root \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  sh -s <<'EOF'
set -eu

mkdir -p /root/.config/tmux
conf=/root/.config/tmux/tmux.conf
touch "$conf"

set_tmux_line() {
  key=$1
  value=$2
  if grep -q "^set -g $key" "$conf"; then
    escaped=$(printf '%s' "set -g $key $value" | sed 's/[\/&]/\\&/g')
    sed -i "s/^set -g $key.*/$escaped/" "$conf"
  else
    printf 'set -g %s %s\n' "$key" "$value" >>"$conf"
  fi
}

set_tmux_line default-style '"fg=white,bg=black"'
set_tmux_line window-style '"fg=white,bg=black"'
set_tmux_line window-active-style '"fg=white,bg=black"'
set_tmux_line status-style '"bg=black,fg=white"'
set_tmux_line message-style '"bg=black,fg=white"'
set_tmux_line mode-style '"bg=white,fg=black"'
set_tmux_line pane-border-style '"fg=white"'
set_tmux_line pane-active-border-style '"fg=white"'

cat > /root/.config/Xresources <<'XEOF'
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

xrdb -merge /root/.config/Xresources >/dev/null 2>&1 || true

if tmux ls >/dev/null 2>&1; then
  tmux source-file "$conf" >/dev/null 2>&1 || true
  tmux set -g default-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g window-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g window-active-style 'fg=white,bg=black' >/dev/null 2>&1 || true
  tmux set -g status-style 'bg=black,fg=white' >/dev/null 2>&1 || true
  tmux set -g message-style 'bg=black,fg=white' >/dev/null 2>&1 || true
  tmux set -g pane-border-style 'fg=white' >/dev/null 2>&1 || true
  tmux set -g pane-active-border-style 'fg=white' >/dev/null 2>&1 || true
  tmux refresh-client -S >/dev/null 2>&1 || true
fi
EOF
