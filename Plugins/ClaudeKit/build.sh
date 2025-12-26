#!/bin/bash
# ClaudeKit build script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 配置
BUNDLE_NAME="ClaudeKit"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-$HOME/.eterm/plugins}"

echo "Building $BUNDLE_NAME ($CONFIGURATION)..."

# 构建
swift build -c $(echo $CONFIGURATION | tr '[:upper:]' '[:lower:]')

# 创建 bundle 结构
BUNDLE_DIR="$BUNDLE_OUTPUT_DIR/$BUNDLE_NAME.bundle"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# 复制动态库
BUILD_DIR=".build/$(echo $CONFIGURATION | tr '[:upper:]' '[:lower:]')"
cp "$BUILD_DIR/lib${BUNDLE_NAME}.dylib" "$BUNDLE_DIR/Contents/MacOS/$BUNDLE_NAME"

# 修复 ETermKit 依赖路径：从 @rpath/libETermKit.dylib 改为指向 app bundle 的 framework
install_name_tool -change @rpath/libETermKit.dylib @executable_path/../Frameworks/ETermKit.framework/ETermKit "$BUNDLE_DIR/Contents/MacOS/$BUNDLE_NAME"

# 修改后需要重签名
codesign -f -s - "$BUNDLE_DIR/Contents/MacOS/$BUNDLE_NAME"

# 复制 manifest
cp "Resources/manifest.json" "$BUNDLE_DIR/Contents/Resources/"

# 创建 Info.plist
cat > "$BUNDLE_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.claude</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
</dict>
</plist>
EOF

echo "Bundle created at: $BUNDLE_DIR"
