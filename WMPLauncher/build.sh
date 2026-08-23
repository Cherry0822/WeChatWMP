#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="../WMPLauncher.app"
SRC="Sources"

# SwiftUI macros are shipped with Xcode, not the standalone Command Line
# Tools package. Select an installed Xcode when the caller has not done so.
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    developer_dir="$DEVELOPER_DIR"
else
    developer_dir=""
    selected_dir="$(xcode-select -p 2>/dev/null || true)"
    candidates=("$selected_dir" "/Applications/Xcode.app/Contents/Developer" "/Applications/Xcode-beta.app/Contents/Developer")
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" && \
              -f "$candidate/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
            developer_dir="$candidate"
            break
        fi
    done
fi

if [[ ! -x "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" || \
      ! -f "$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    current_dir="$(xcode-select -p 2>/dev/null || echo unavailable)"
    cat >&2 <<EOF
错误：未找到包含 SwiftUIMacros 的完整 Xcode。
当前开发者目录：$current_dir
请安装 Xcode，或运行：DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer $0
EOF
    exit 1
fi

export DEVELOPER_DIR="$developer_dir"
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
