#!/bin/bash
# build.sh - Build MCPRouterKit plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="MCPRouterKit"
BUNDLE_ID="com.eterm.mcp-router"
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

# MCP Router Core library
CORE_LIB="${SCRIPT_DIR}/Lib/libmcp_router_core.dylib"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[${PLUGIN_NAME}]${NC} $*"; }
log_success() { echo -e "${GREEN}[${PLUGIN_NAME}]${NC} $*"; }
log_error() { echo -e "${RED}[${PLUGIN_NAME}]${NC} $*"; }

# Check core library exists
if [ ! -f "$CORE_LIB" ]; then
    log_error "Core library not found: $CORE_LIB"
    log_error "Please build mcp-router core first and copy mcp_router_core to Lib/"
    exit 1
fi

# Build Swift Package
log_info "Building Swift package..."
cd "$SCRIPT_DIR"

# Build using Package.swift linkerSettings
swift build

# Create Bundle structure
log_info "Creating bundle..."
rm -rf "$PLUGIN_DIR"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"
mkdir -p "${BUNDLE_PATH}/Contents/Frameworks"

# Copy plugin dylib
cp ".build/debug/lib${PLUGIN_NAME}.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# Copy MCP Router Core library to Frameworks
cp "$CORE_LIB" "${BUNDLE_PATH}/Contents/Frameworks/"

# Fix ETermKit link path: SPM dylib -> Xcode framework
log_info "Fixing link paths..."
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
    "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Fix MCP Router Core link path
install_name_tool -change \
    "Lib/libmcp_router_core.dylib" \
    "@loader_path/../Frameworks/libmcp_router_core.dylib" \
    "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Re-sign after modification
log_info "Re-signing..."
codesign -f -s - "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"
codesign -f -s - "${BUNDLE_PATH}/Contents/Frameworks/libmcp_router_core.dylib"

# Copy manifest.json
cp "Resources/manifest.json" "${BUNDLE_PATH}/Contents/Resources/"

# Create Info.plist
cat > "${BUNDLE_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.mcp-router</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleVersion</key>
    <string>0.0.1-beta.1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>lib${PLUGIN_NAME}.dylib</string>
    <key>NSPrincipalClass</key>
    <string>MCPRouterKit.MCPRouterPlugin</string>
</dict>
</plist>
EOF

log_success "Installed to ${BUNDLE_PATH}"
log_info "Bundle structure:"
ls -la "${BUNDLE_PATH}/Contents/MacOS/"
ls -la "${BUNDLE_PATH}/Contents/Frameworks/"
