#!/system/bin/sh
set -eu

ROOT=${ARCH_CHROOT:-/data/local/chroots/arch}

/system/bin/chroot "$ROOT" /usr/bin/env \
  HOME=/root \
  TMPDIR=/tmp \
  DISPLAY=:1 \
  XDG_RUNTIME_DIR=/tmp/runtime-root \
  PATH=/root/.config/x11/bin:/root/.local/bin:/root/.local/share/mise/shims:/root/.cabal/bin:/root/.ghcup/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  sh -s <<'EOF'
set -eu

mkdir -p \
  /root/.config/xmonad \
  /root/.config/x11/bin \
  /root/.config/qt5ct \
  /root/.config/qt6ct \
  /home/dhruv/.config/x11/bin \
  /home/dhruv/.config/qt5ct \
  /home/dhruv/.config/qt6ct

cat > /root/.config/xmonad/xmonad.hs <<'HEOF'
import XMonad
import XMonad.Actions.CycleRecentWS (toggleRecentWS)
import XMonad.Actions.MouseResize (mouseResize)
import qualified XMonad.Actions.Navigation2D as Nav
import XMonad.Actions.SpawnOn (manageSpawn, spawnOn)
import XMonad.Hooks.EwmhDesktops (ewmh, ewmhFullscreen)
import qualified XMonad.Layout.BinarySpacePartition as BSP
import XMonad.Layout.BorderResize (borderResizeNear)
import XMonad.Layout.NoBorders (smartBorders)
import XMonad.Layout.WindowArranger (windowArrange)
import XMonad.Util.EZConfig (additionalKeysP, removeKeysP)

import Control.Monad (forM_, when)
import qualified XMonad.StackSet as W
import Graphics.X11.Xlib (setWindowBorderWidth)

main :: IO ()
main = xmonad . ewmhFullscreen . ewmh $
  myConfig
    `removeKeysP` removedKeys
    `additionalKeysP` (hotkeys ++ workspaceKeys)

myConfig = def
  { terminal = terminalCmd
  , modMask = mod4Mask
  , workspaces = myWorkspaces
  , focusFollowsMouse = True
  , clickJustFocuses = False
  , borderWidth = 1
  , focusedBorderColor = "#ffffff"
  , normalBorderColor = "#000000"
  , layoutHook = smartBorders $ mouseResize $ windowArrange $ borderResizeNear 8 BSP.emptyBSP
  , manageHook = manageSpawn <+> manageHook def
  , logHook = borderLogHook
  , startupHook = startupApps
  }

terminalCmd :: String
terminalCmd = terminalBase ++ " -e tmux new-session -A -s x11"

terminalBase :: String
terminalBase = "x11-zutty"

startupApps :: X ()
startupApps = do
  spawnOn "1" "chromium-helium-local"
  spawnOn "2" terminalCmd
  windows $ W.greedyView "1"

zoomTerminal :: String -> X ()
zoomTerminal direction = withFocused $ \window -> do
  windowClass <- runQuery className window
  when (windowClass `elem` ["Zutty", "zutty"]) $ do
    spawn ("zutty-font-size " ++ direction)
    spawn terminalCmd
    killWindow window

hotkeys :: [(String, X ())]
hotkeys =
  [ ("M-q", kill)
  , ("M-<Return>", spawn terminalCmd)
  , ("M-S-<Return>", spawn terminalCmd)
  , ("M-f", spawn "dolphin --new-window \"$HOME\"")
  , ("M-b", spawn "chromium-helium-local")
  , ("M-t", spawn $ terminalBase ++ " -e btop")
  , ("M-w", spawn $ terminalBase ++ " -e wiremix")
  , ("M-l", spawn "$HOME/.config/scripts/ddc-monitor-toggle")
  , ("M-v", spawn "x11-clip-menu")
  , ("M-S-s", spawn "x11-screenshot-clipboard")
  , ("M-S-C-s", spawn "x11-screenshot-file")
  , ("<XF86MonBrightnessUp>", spawn "$HOME/.config/scripts/brightness-smart increment 5")
  , ("<XF86MonBrightnessDown>", spawn "$HOME/.config/scripts/brightness-smart decrement 5")
  , ("M-<XF86MonBrightnessUp>", spawn "$HOME/.config/scripts/contrast-smart increment 5")
  , ("M-<XF86MonBrightnessDown>", spawn "$HOME/.config/scripts/contrast-smart decrement 5")
  , ("M-h", spawn "x11-hotkeys")
  , ("M-S-h", spawn "x11-hotkeys")
  , ("M-<Tab>", toggleRecentWS)
  , ("M-<Left>", Nav.windowGo Nav.L False)
  , ("M-<Right>", Nav.windowGo Nav.R False)
  , ("M-<Up>", Nav.windowGo Nav.U False)
  , ("M-<Down>", Nav.windowGo Nav.D False)
  , ("M-S-<Left>", Nav.windowSwap Nav.L False)
  , ("M-S-<Right>", Nav.windowSwap Nav.R False)
  , ("M-S-<Up>", Nav.windowSwap Nav.U False)
  , ("M-S-<Down>", Nav.windowSwap Nav.D False)
  , ("M-S-t", withFocused toggleFloat)
  , ("M-j", sendMessage BSP.Rotate)
  , ("M-S-j", sendMessage BSP.Swap)
  , ("M-a", sendMessage BSP.Balance)
  , ("M-S-a", sendMessage BSP.Equalize)
  , ("M-n", sendMessage BSP.FocusParent)
  , ("M-C-n", sendMessage BSP.SelectNode)
  , ("M-S-n", sendMessage BSP.MoveNode)
  , ("M-M1-<Left>", sendMessage $ BSP.ExpandTowards BSP.L)
  , ("M-M1-<Right>", sendMessage $ BSP.ExpandTowards BSP.R)
  , ("M-M1-<Up>", sendMessage $ BSP.ExpandTowards BSP.U)
  , ("M-M1-<Down>", sendMessage $ BSP.ExpandTowards BSP.D)
  , ("M-C-<Left>", sendMessage $ BSP.MoveSplit BSP.L)
  , ("M-C-<Right>", sendMessage $ BSP.MoveSplit BSP.R)
  , ("M-C-<Up>", sendMessage $ BSP.MoveSplit BSP.U)
  , ("M-C-<Down>", sendMessage $ BSP.MoveSplit BSP.D)
  , ("M-S-r", spawn "xmonad --recompile && xmonad --restart")
  , ("M1-<Space>", spawn "dmenu_run")
  ]

workspaceKeys :: [(String, X ())]
workspaceKeys =
  [ (modKey ++ key, windows $ action workspace)
  | (workspace, key) <- zip myWorkspaces (map show [1 :: Int .. 9])
  , (modKey, action) <- [("M-", W.greedyView), ("M-S-", W.shift)]
  ]

myWorkspaces :: [String]
myWorkspaces = map show [1 :: Int .. 9]

removedKeys :: [String]
removedKeys =
  [ "M-q", "M-S-q", "M-S-c", "M-p", "M-<Space>", "M-S-<Return>"
  , "M-b", "M-f", "M-t", "M-S-t", "M-w", "M-h", "M-j", "M-k", "M-l"
  , "M-S-j", "M-S-k", "M-S-l", "M-<Tab>", "M-a", "M-S-a", "M-n", "M-S-n"
  ]

toggleFloat :: Window -> X ()
toggleFloat window = windows $ \windowSet ->
  let tiledSet = W.sink window windowSet
  in if W.floating tiledSet == W.floating windowSet
       then W.float window (W.RationalRect 0.08 0.08 0.84 0.84) windowSet
       else tiledSet

borderLogHook :: X ()
borderLogHook = withWindowSet $ \windowSet -> do
  displayHandle <- asks display
  let visibleScreens = W.current windowSet : W.visible windowSet
      screenWindows = W.integrate' . W.stack . W.workspace
      visibleWindows = concatMap screenWindows visibleScreens
      currentWindows = screenWindows $ W.current windowSet
      focusedWindow = W.peek windowSet
      focusedBorderWidth = if length currentWindows > 1 then 1 else 0

  io $ forM_ visibleWindows $ \window ->
    setWindowBorderWidth displayHandle window 0

  case focusedWindow of
    Just window -> io $ setWindowBorderWidth displayHandle window focusedBorderWidth
    Nothing -> pure ()
HEOF

cat > /root/.config/xmonad/build <<'HEOF'
#!/bin/sh
set -eu

out=${1:?output path required}
config_dir=${XMONAD_CONFIG_DIR:-"$HOME/.config/xmonad"}
export PATH=/root/.ghcup/bin:/root/.cabal/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:$PATH
export TMPDIR=/tmp
mkdir -p "$TMPDIR"
mkdir -p "$(dirname "$out")"
cd "$config_dir"
exec ghc \
  --make xmonad.hs \
  -i \
  -ilib \
  -fforce-recomp \
  -main-is main \
  -v0 \
  -o "$out"
HEOF
chmod 755 /root/.config/xmonad/build

cat > /root/.config/x11/hotkeys.txt <<'HEOF'
XMonad hotkeys

Super+Q              close focused window
Super+Enter          open zutty attached to tmux session x11
Super+F              open Dolphin
Super+B              open Helium Passwords browser
Super+T              open btop in zutty
Super+W              open wiremix in zutty
Super+L              toggle known LG/Acer DDC monitor power/input
Super+V              searchable clipboard history
Super+H              show this hotkey list
Super+Tab            switch to the most recent workspace

BrightnessUp         raise external-monitor brightness by 5 over DDC
BrightnessDown       lower external-monitor brightness by 5 over DDC
Super+BrightnessUp   raise external-monitor contrast by 5 over DDC
Super+BrightnessDown lower external-monitor contrast by 5 over DDC

Super+1..9           view workspace
Super+Shift+1..9     move focused window to workspace

Super+Arrow          focus tile in that direction
Super+Shift+Arrow    move/swap tile in that direction
Super+Shift+T        toggle focused window float/tile
Super+J              rotate the BSP split at the focused node
Super+Shift+J        swap the two children of the BSP split
Super+A              rebalance BSP tree
Super+Shift+A        equalize BSP split ratios
Super+N              select/focus BSP parent node
Super+Ctrl+N         select current BSP node
Super+Shift+N        move selected BSP node under focused node
Super+Alt+Arrow      grow focused BSP tile toward that direction
Super+Ctrl+Arrow     move the nearest BSP split in that direction
Super+drag border    resize BSP tiles by dragging a tile border

Super+Shift+S        screenshot to clipboard
Super+Ctrl+Shift+S   screenshot to ~/Downloads

Alt+Space            dmenu app menu
Ctrl+=               browser zoom in
Ctrl+-               browser zoom out
Ctrl+0               browser zoom reset
Super+Shift+R        recompile and restart XMonad
HEOF

cp /root/.config/x11/hotkeys.txt /home/dhruv/.config/x11/hotkeys.txt 2>/dev/null || true

cat > /root/.config/x11/bin/x11-zutty <<'HEOF'
#!/bin/sh
set -eu

home=${HOME:-/root}
resources="$home/.config/Xresources"
[ -r "$resources" ] || resources=/root/.config/Xresources
xrdb -merge "$resources" >/dev/null 2>&1 || true

font=${ZUTTY_FONT:-IosevkaNerdFontMono}
fontsize=${ZUTTY_FONTSIZE:-15}
exec /usr/bin/zutty \
  -name Zutty \
  -fg '#ffffff' \
  -bg '#000000' \
  -cr '#ffffff' \
  -font "$font" \
  -fontsize "$fontsize" \
  -border 0 \
  "$@"
HEOF
chmod 755 /root/.config/x11/bin/x11-zutty
cp /root/.config/x11/bin/x11-zutty /home/dhruv/.config/x11/bin/x11-zutty 2>/dev/null || true
chmod 755 /home/dhruv/.config/x11/bin/x11-zutty 2>/dev/null || true

cat > /root/.config/x11/bin/x11-hotkeys <<'HEOF'
#!/bin/sh
set -eu

config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
exec xmessage \
  -center \
  -buttons OK:0 \
  -bg '#111111' \
  -fg '#eeeeee' \
  -xrm '*borderColor: #555555' \
  -xrm '*Button.background: #222222' \
  -xrm '*Button.foreground: #eeeeee' \
  -xrm '*Command.background: #222222' \
  -xrm '*Command.foreground: #eeeeee' \
  -file "$config_home/x11/hotkeys.txt"
HEOF
chmod 755 /root/.config/x11/bin/x11-hotkeys
cp /root/.config/x11/bin/x11-hotkeys /home/dhruv/.config/x11/bin/x11-hotkeys 2>/dev/null || true
chmod 755 /home/dhruv/.config/x11/bin/x11-hotkeys 2>/dev/null || true

cat > /root/.config/x11/bin/dolphin <<'HEOF'
#!/bin/sh
export QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-qt5ct}"
export QT_STYLE_OVERRIDE="${QT_STYLE_OVERRIDE:-Breeze}"
export KDE_COLOR_SCHEME="${KDE_COLOR_SCHEME:-BreezeDark}"
exec /usr/bin/dolphin "$@"
HEOF
chmod 755 /root/.config/x11/bin/dolphin
cp /root/.config/x11/bin/dolphin /home/dhruv/.config/x11/bin/dolphin 2>/dev/null || true
chmod 755 /home/dhruv/.config/x11/bin/dolphin 2>/dev/null || true

write_dark_qt_config() {
  home=$1
  mkdir -p "$home/.config" "$home/.config/qt5ct" "$home/.config/qt6ct"
  cat > "$home/.config/kdeglobals" <<'HEOF'
[General]
ColorScheme=BreezeDark
Name=Breeze Dark
shadeSortColumn=true

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
SingleClick=false

[UiSettings]
ColorScheme=BreezeDark
HEOF
  for qt_conf in "$home/.config/qt5ct/qt5ct.conf" "$home/.config/qt6ct/qt6ct.conf"; do
    cat > "$qt_conf" <<'HEOF'
[Appearance]
color_scheme_path=/usr/share/qt5ct/colors/darker.conf
custom_palette=false
icon_theme=breeze-dark
standard_dialogs=default
style=Breeze

[Fonts]
fixed="Iosevka Nerd Font Mono,12,-1,5,50,0,0,0,0,0"
general="Noto Sans,10,-1,5,50,0,0,0,0,0"

[Interface]
activate_item_on_single_click=0
buttonbox_layout=0
cursor_flash_time=1000
dialog_buttons_have_icons=1
double_click_interval=400
gui_effects=@Invalid()
keyboard_scheme=2
menus_have_icons=true
show_shortcuts_in_context_menus=true
stylesheets=@Invalid()
toolbutton_style=4
underline_shortcut=1
wheel_scroll_lines=3
HEOF
  done
}

write_dark_qt_config /root
write_dark_qt_config /home/dhruv

uid=$(id -u dhruv 2>/dev/null || true)
gid=$(id -g dhruv 2>/dev/null || true)
if [ -n "$uid" ] && [ -n "$gid" ]; then
  chown -R "$uid:$gid" /home/dhruv/.config/x11 /home/dhruv/.config/kdeglobals /home/dhruv/.config/qt5ct /home/dhruv/.config/qt6ct
fi
EOF
