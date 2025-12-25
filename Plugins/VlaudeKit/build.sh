#!/bin/bash
# build.sh - Build VlaudeKit plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="VlaudeKit"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"

# Output directory
OUTPUT_DIR="${HOME}/.eterm/plugins"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"

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
rm -rf "$BUNDLE_PATH"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"

# Copy dylib
cp ".build/debug/lib${PLUGIN_NAME}.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# Fix ETermKit link path: SPM dylib -> Xcode framework
log_info "Fixing ETermKit link path for framework..."
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@rpath/ETermKit.framework/Versions/A/ETermKit" \
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
    <string>com.eterm.vlaude</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>lib${PLUGIN_NAME}.dylib</string>
    <key>NSPrincipalClass</key>
    <string>VlaudeLogic</string>
</dict>
</plist>
EOF

log_success "Installed to ${BUNDLE_PATH}"
