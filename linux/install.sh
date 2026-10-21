#!/usr/bin/env bash
# Installs PapayaPower for the current user (no root): ~/.local/lib/papayapower, `papaya` and
# `papayapower` launchers, desktop entry, icon, and a systemd user timer that records history,
# sends notifications and pushes metrics every 5 minutes even when the window is closed.
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

if [ "${1:-}" = "--remove" ]; then
  systemctl --user disable --now papayapower-record.timer 2>/dev/null || true
  rm -rf "$LIB" "$BIN/papaya" "$BIN/papayapower" "$APPS/eu.savethemall.papayapower.desktop" \
         "$ICONS/papayapower.png" "$UNITS/papayapower-record.service" "$UNITS/papayapower-record.timer"
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
systemctl --user daemon-reload
systemctl --user enable --now papayapower-record.timer
"$BIN/papaya" --no-ios | head -12
echo "installed: $BIN/papaya, $BIN/papayapower, timer papayapower-record (every 5 min)"
echo "Waybar: add the module in waybar/papaya.jsonc and the style in waybar/papaya.css"
