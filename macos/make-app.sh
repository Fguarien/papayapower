#!/usr/bin/env bash
# Builds PapayaPower.app (universal: arm64 + x86_64) and optionally installs it or packs a DMG.
#
#   ./make-app.sh                 release build → build/PapayaPower.app
#   ./make-app.sh --install       … and copy it to /Applications (and papaya to /usr/local/bin if writable)
#   ./make-app.sh --dmg           … and build build/PapayaPower-<version>.dmg
#
# Signing, in this order: PAPAYA_SIGN_ID=<identity>; the « PapayaPower Local Signing » certificate
# created once by Tools/make-signing-keychain.sh; ad hoc otherwise. A stable identity keeps the
# Keychain and firewall rules (Little Snitch…) valid across builds; ad hoc changes on every build.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="eu.savethemall.papayapower"
OUT="build"
APP="$OUT/PapayaPower.app"

INSTALL=0; DMG=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

echo "==> swift build (universal)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/PapayaPower" "$APP/Contents/MacOS/PapayaPower"
cp "$BIN/papaya" "$APP/Contents/Helpers/papaya"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PapayaPower</string>
  <key>CFBundleDisplayName</key><string>PapayaPower</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>PapayaPower</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NO}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Frédéric Guariento — MIT License</string>
  <key>NSLocalNetworkUsageDescription</key><string>PapayaPower shares battery readings with your other computers, reads UPS units on NUT servers and iPhones over Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_apple-mobdev2._tcp</string><string>_papayapower._tcp</string></array>
</dict>
</plist>
PLIST

echo "==> icon"
if [ ! -f "$OUT/AppIcon.icns" ] || [ Tools/make-icon.swift -nt "$OUT/AppIcon.icns" ]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift Tools/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp ../docs/HELP.md "$APP/Contents/Resources/HELP.md"

echo "==> sign"
SIGN_ID="${PAPAYA_SIGN_ID:-}"
KC="$HOME/Library/Keychains/papayapower-signing.keychain-db"
if [ -z "$SIGN_ID" ] && [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "PapayaPower Local Signing"; then
  security unlock-keychain -p "" "$KC"
  SIGN_ID="PapayaPower Local Signing"
fi
SIGN_ID="${SIGN_ID:--}"
echo "signing identity: $SIGN_ID"
codesign --force --timestamp=none -s "$SIGN_ID" "$APP/Contents/Helpers/papaya"
codesign --force --timestamp=none -s "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/PapayaPower"
echo "built $APP ($VERSION, build $BUILD_NO)"

if [ "$INSTALL" = 1 ]; then
  echo "==> install"
  pkill -x PapayaPower 2>/dev/null || true
  rm -rf /Applications/PapayaPower.app
  cp -R "$APP" /Applications/
  if [ -w /usr/local/bin ]; then ln -sf /Applications/PapayaPower.app/Contents/Helpers/papaya /usr/local/bin/papaya; fi
  echo "installed /Applications/PapayaPower.app"
fi

if [ "$DMG" = 1 ]; then
  echo "==> dmg"
  STAGE="$OUT/dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp ../docs/INSTALL-macOS.txt "$STAGE/Read Me First.txt" 2>/dev/null || true
  DMGFILE="$OUT/PapayaPower-$VERSION.dmg"
  rm -f "$DMGFILE"
  hdiutil create -quiet -volname "PapayaPower $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMGFILE"
  shasum -a 256 "$DMGFILE"
fi
