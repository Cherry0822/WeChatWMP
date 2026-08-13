#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="../WMPLauncher.app"
SRC="Sources"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/WMPLauncher "$APP/Contents/MacOS/WMPLauncher"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/lx.icns "$APP/Contents/Resources/lx.icns"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成: $APP"
