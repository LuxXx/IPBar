#!/bin/zsh
# Builds IPBar.app next to this script.
#   ./build.sh            build for this Mac
#   ./build.sh --install  also copy to /Applications and launch
#   ./build.sh --release  universal (Apple Silicon + Intel) build, zipped as IPBar-<version>.zip
# Set VERSION=1.2.3 to stamp the version (default 1.0.0).
set -euo pipefail
cd "${0:A:h}"

VERSION=${VERSION:-1.0.0}
MODE=${1:-}
APP=IPBar.app

if [[ "$MODE" == "--release" ]]; then
    swift build -c release --triple arm64-apple-macosx14.0
    swift build -c release --triple x86_64-apple-macosx14.0
    BINARIES=(.build/arm64-apple-macosx/release/IPBar .build/x86_64-apple-macosx/release/IPBar)
else
    swift build -c release
    BINARIES=(.build/release/IPBar)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/IPBar"
# Drop debug-map symbols: they embed absolute build paths (incl. the user name).
strip -S -x "$APP/Contents/MacOS/IPBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>IPBar</string>
    <key>CFBundleDisplayName</key><string>IPBar</string>
    <key>CFBundleIdentifier</key><string>io.github.luxxx.IPBar</string>
    <key>CFBundleExecutable</key><string>IPBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocationUsageDescription</key><string>IPBar logs the name of your Wi-Fi network and your approximate location (rounded, about 1 km by default) to a local history file. Nothing is sent anywhere except Apple's location service.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>IPBar logs the name of your Wi-Fi network and your approximate location (rounded, about 1 km by default) to a local history file. Nothing is sent anywhere except Apple's location service.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/IPBar"))"

case "$MODE" in
--install)
    pkill -x IPBar 2>/dev/null || true
    rm -rf /Applications/IPBar.app
    cp -R "$APP" /Applications/
    open /Applications/IPBar.app
    echo "Installed to /Applications"
    ;;
--release)
    ZIP="IPBar-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
    echo "Packaged $PWD/$ZIP"
    ;;
esac
