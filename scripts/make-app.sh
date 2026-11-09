#!/bin/bash
# 构建并组装 DevScope.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/DevScope.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DevScope "$APP/Contents/MacOS/DevScope"
cp App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 应用图标（首次缺失时生成）
if [ ! -f App/AppIcon.icns ]; then
    swift scripts/make-icon.swift
fi
[ -f App/AppIcon.icns ] && cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "✅ 已生成 $APP"
echo "   open $APP   # 启动（菜单栏常驻）"
