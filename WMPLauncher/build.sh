#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="../WMPLauncher.app"
SRC="Sources"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/WMPLauncher "$APP/Contents/MacOS/WMPLauncher"

cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成: $APP"
