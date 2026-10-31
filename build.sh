#!/bin/zsh
# Builds IPBar.app next to this script. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP=IPBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/IPBar "$APP/Contents/MacOS/IPBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>IPBar</string>
    <key>CFBundleDisplayName</key><string>IPBar</string>
    <key>CFBundleIdentifier</key><string>local.ipbar</string>
    <key>CFBundleExecutable</key><string>IPBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocationUsageDescription</key><string>IPBar uses Location Services only to read the name of your Wi-Fi network for the IP log. Your location is never requested or stored.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>IPBar uses Location Services only to read the name of your Wi-Fi network for the IP log. Your location is never requested or stored.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x IPBar 2>/dev/null || true
    rm -rf /Applications/IPBar.app
    cp -R "$APP" /Applications/
    open /Applications/IPBar.app
    echo "Installed to /Applications"
fi
