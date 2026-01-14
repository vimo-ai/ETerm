#!/bin/bash
# build.sh - Build DevHelperKit plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="DevHelperKit"
BUNDLE_ID="com.eterm.dev-helper"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"

# Output directory: {plugins}/{id}/{name}.bundle
# 内置插件必须通过 Xcode 编译
if [ -z "${BUNDLE_OUTPUT_DIR:-}" ]; then
    echo "Error: BUNDLE_OUTPUT_DIR not set. Build via Xcode." >&2
    exit 1
fi
OUTPUT_DIR="${BUNDLE_OUTPUT_DIR}"
PLUGIN_DIR="${OUTPUT_DIR}/${BUNDLE_ID}"
BUNDLE_PATH="${PLUGIN_DIR}/${BUNDLE_NAME}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[${PLUGIN_NAME}]${NC} $*"; }
log_success() { echo -e "${GREEN}[${PLUGIN_NAME}]${NC} $*"; }

# Build Swift Package
log_info "Building Swift package..."
cd "$SCRIPT_DIR"
swift build

# Create Bundle structure
log_info "Creating bundle..."
rm -rf "$PLUGIN_DIR"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"

# Copy dylib
cp ".build/debug/lib${PLUGIN_NAME}.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# Fix ETermKit link path: SPM dylib -> Xcode framework
log_info "Fixing ETermKit link path for framework..."
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
    "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Re-sign after modification
codesign -f -s - "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Copy manifest.json
cp "Resources/manifest.json" "${BUNDLE_PATH}/Contents/Resources/"

# Create Info.plist
cat > "${BUNDLE_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.dev-helper</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleVersion</key>
    <string>0.0.1-beta.1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>lib${PLUGIN_NAME}.dylib</string>
    <key>NSPrincipalClass</key>
    <string>DevHelperKit.DevHelperPlugin</string>
</dict>
</plist>
EOF

log_success "Installed to ${BUNDLE_PATH}"
