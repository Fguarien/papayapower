#!/usr/bin/env bash
# Installs PapayaPower for the current user (no root): ~/.local/lib/papayapower, `papaya` and
# `papayapower` launchers, desktop entry, icon, and a systemd user timer that records history,
# sends notifications and pushes metrics every 5 minutes even when the window is closed, a
# systemd user service that answers the master over Bonjour (member), and — on Omarchy 4,
# whose bar is Quickshell — the `local.papaya` bar widget.
#   ./install.sh            install / update
#   ./install.sh --remove   uninstall (history and settings are kept)
set -euo pipefail
cd "$(dirname "$0")"
PREFIX="${PREFIX:-$HOME/.local}"
LIB="$PREFIX/lib/papayapower"
BIN="$PREFIX/bin"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
OMARCHY_PLUGINS="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

if [ "${1:-}" = "--remove" ]; then
  systemctl --user disable --now papayapower-record.timer papayapower-peer.service 2>/dev/null || true
  if [ -d "$OMARCHY_PLUGINS/local.papaya" ]; then
    omarchy plugin disable local.papaya >/dev/null 2>&1 || true
    rm -rf "$OMARCHY_PLUGINS/local.papaya"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
  rm -rf "$LIB" "$BIN/papaya" "$BIN/papayapower" "$APPS/eu.savethemall.papayapower.desktop" \
         "$ICONS/papayapower.png" "$UNITS/papayapower-record.service" "$UNITS/papayapower-record.timer" \
         "$UNITS/papayapower-peer.service"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "removed (history and settings kept in ~/.local/share/papayapower and ~/.config/papayapower)"
  exit 0
fi

python3 - <<'PY' || { echo "missing: python-gobject / python-cairo / gtk4 / libadwaita (the CLI still works)" >&2; }
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw
import cairo  # python-cairo: needed by the gauges and charts
assert (Adw.get_major_version(), Adw.get_minor_version()) >= (1, 5), "libadwaita >= 1.5 required"
PY

mkdir -p "$LIB" "$BIN" "$APPS" "$ICONS" "$UNITS"
rm -rf "$LIB/papayapower"
cp -r papayapower "$LIB/"
cp ../docs/HELP.md "$LIB/papayapower/HELP.md"
find "$LIB" -name __pycache__ -prune -exec rm -rf {} +

cat > "$BIN/papaya" <<SH
#!/bin/sh
PYTHONPATH="$LIB" exec python3 -m papayapower "\$@"
SH
cat > "$BIN/papayapower" <<SH
#!/bin/sh
PYTHONPATH="$LIB" exec python3 -m papayapower --gui "\$@"
SH
chmod +x "$BIN/papaya" "$BIN/papayapower"

cp ../docs/icon.png "$ICONS/papayapower.png"
cat > "$APPS/eu.savethemall.papayapower.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=PapayaPower
Comment=Battery health for laptops, iPhones, iPads and UPS units
Exec=$BIN/papayapower
Icon=papayapower
Categories=System;Monitor;
Keywords=battery;ups;health;iphone;
DESK

sed "s|@BIN@|$BIN|g" systemd/papayapower-record.service > "$UNITS/papayapower-record.service"
cp systemd/papayapower-record.timer "$UNITS/"
sed "s|@BIN@|$BIN|g" systemd/papayapower-peer.service > "$UNITS/papayapower-peer.service"
systemctl --user daemon-reload
systemctl --user enable --now papayapower-record.timer
# Member: the master finds this machine with Bonjour (Avahi) and reads it over HTTP.
command -v avahi-publish >/dev/null || echo "missing: avahi (avahi-publish) — the master will not find this machine" >&2
systemctl --user enable papayapower-peer.service
systemctl --user restart papayapower-peer.service
"$BIN/papaya" --no-ios | head -12
echo "installed: $BIN/papaya, $BIN/papayapower, timer papayapower-record (every 5 min), service papayapower-peer"

# Omarchy 4 (Quickshell bar): drop the bar widget in and enable it once (re-enabling would
# move it back to its default place if you moved it).
if command -v omarchy-shell >/dev/null && [ -d "$(dirname "$OMARCHY_PLUGINS")" ]; then
  # Over SSH the session variables are missing: borrow them from the running shell.
  if [ -z "${OMARCHY_PATH:-}" ] && qs=$(pgrep -u "$(id -u)" -x quickshell | head -1); then
    while IFS= read -r -d '' kv; do
      case "$kv" in OMARCHY_PATH=*|WAYLAND_DISPLAY=*|HYPRLAND_INSTANCE_SIGNATURE=*) export "${kv?}";; esac
    done < "/proc/$qs/environ"
  fi
  new=0; [ -d "$OMARCHY_PLUGINS/local.papaya" ] || new=1
  mkdir -p "$OMARCHY_PLUGINS"
  rm -rf "$OMARCHY_PLUGINS/local.papaya"
  cp -r omarchy/local.papaya "$OMARCHY_PLUGINS/"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  [ "$new" = 1 ] && omarchy plugin enable local.papaya >/dev/null 2>&1 || true
  echo "Omarchy bar: widget local.papaya installed (move it with \`omarchy bar move\`)"
elif command -v waybar >/dev/null; then
  echo "Waybar: add the module in waybar/papaya.jsonc and the style in waybar/papaya.css"
fi
echo "Firewall: the master reads this machine on TCP 47823 (mDNS is already allowed by ufw), e.g."
echo "  sudo ufw allow from 192.168.1.0/24 to any port 47823 proto tcp"
