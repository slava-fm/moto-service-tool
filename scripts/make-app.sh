#!/bin/bash
# Build the SwiftUI GUI and wrap it into a double-clickable MotoServiceTool.app.
# To rebrand: change APP_NAME / DISPLAY_NAME / BUNDLE_ID below.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MotoServiceTool"
DISPLAY_NAME="Moto Service Tool"
BUNDLE_ID="com.local.motoservicetool"

echo "Building release…"
swift build -c release --product DucatiResetGUI

BIN=".build/release/DucatiResetGUI"
APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"

# Icon (generate if missing)
if [ ! -f build/AppIcon.icns ]; then
  swift tools/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>     <string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key>         <string>1.0</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Open with:  open \"$APP\"   (first run: right-click → Open)"
