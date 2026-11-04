#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacNotch"
APP=build/MacNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacNotch"
# App icon: derived from Resources/AppIcon.png (never modified). macOS 26+ puts icons whose
# artwork doesn't fill the system squircle on a grey plate, so make-icon.swift builds an opaque
# full-bleed square and the system applies its own mask. Cached in build/icon/ until the PNG
# or the generator changes.
ICONDIR=build/icon
if [ ! -f "$ICONDIR/AppIcon.icns" ] || [ Resources/AppIcon.png -nt "$ICONDIR/AppIcon.icns" ] \
   || [ scripts/make-icon.swift -nt "$ICONDIR/AppIcon.icns" ]; then
  rm -rf "$ICONDIR"; mkdir -p "$ICONDIR"
  swift scripts/make-icon.swift Resources/AppIcon.png "$ICONDIR/AppIcon.iconset" full
  iconutil -c icns "$ICONDIR/AppIcon.iconset" -o "$ICONDIR/AppIcon.icns"
fi
cp "$ICONDIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.eortizd.macnotch</string>
  <key>CFBundleName</key><string>MacNotch</string>
  <key>CFBundleDisplayName</key><string>MacNotch</string>
  <key>CFBundleExecutable</key><string>MacNotch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>MacNotch lists the notes in the one Notes folder you choose and opens the one you click in Notes. It never changes your notes and sends nothing off your Mac.</string>
</dict>
</plist>
PLIST

# Signing: a stable identity keeps macOS privacy (TCC) grants across rebuilds.
# Ad-hoc signatures change on every build, which resets Automation grants.
ENT=scripts/MacNotch.entitlements
IDENTITY="MacNotch Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  SIGN=(-s "$IDENTITY")
  echo "Signing with \"$IDENTITY\""
else
  SIGN=(-s -)
  echo "warning: no \"$IDENTITY\" identity; ad-hoc signing."
  echo "warning: *** Automation grants are tied to this build's cdhash and will NOT carry over."
  echo "warning: *** Re-grant after every rebuild, or run scripts/make-signing-cert.sh once for a stable identity."
fi
codesign --force --deep --options runtime --entitlements "$ENT" "${SIGN[@]}" "$APP"
echo "Built $APP"
