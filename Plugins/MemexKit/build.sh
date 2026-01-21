#!/bin/bash
# MemexKit build script (HTTP 服务模式)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="MemexKit"
BUNDLE_ID="com.eterm.memex"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"

# Output directory: {plugins}/{id}/{name}.bundle
OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-${HOME}/.vimo/eterm/plugins}"
PLUGIN_DIR="${OUTPUT_DIR}/${BUNDLE_ID}"
BUNDLE_PATH="${PLUGIN_DIR}/${BUNDLE_NAME}"

# Memex binary
MEMEX_BINARY="${SCRIPT_DIR}/Lib/memex"

# Memex Web UI (从 memex-rs 项目复制)
MEMEX_WEB_DIR="${SCRIPT_DIR}/Lib/web"
MEMEX_WEB_SOURCE="/Users/higuaifan/Desktop/vimo/memex/web/dist"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[${PLUGIN_NAME}]${NC} $*"; }
log_success() { echo -e "${GREEN}[${PLUGIN_NAME}]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[${PLUGIN_NAME}]${NC} $*"; }
log_error() { echo -e "${RED}[${PLUGIN_NAME}]${NC} $*"; }

# Check memex binary exists
if [ ! -f "$MEMEX_BINARY" ]; then
    log_warn "Memex binary not found: $MEMEX_BINARY"
    log_warn "Please run: scripts/update_eterm.sh in memex-rs"
    log_warn "Continuing without binary (service will need to be installed separately)"
fi

# Copy Web UI from memex project if source exists
if [ -d "$MEMEX_WEB_SOURCE" ]; then
    log_info "Copying Web UI from memex project..."
    rm -rf "$MEMEX_WEB_DIR"
    cp -r "$MEMEX_WEB_SOURCE" "$MEMEX_WEB_DIR"
    log_info "Web UI copied to Lib/web"
elif [ ! -d "$MEMEX_WEB_DIR" ]; then
    log_warn "Web UI not found: $MEMEX_WEB_DIR"
    log_warn "Please build memex web: cd memex/web && npm run build"
fi

# Build Swift Package
log_info "Building Swift package..."
cd "$SCRIPT_DIR"

swift build

# Create Bundle structure
log_info "Creating bundle..."
rm -rf "$PLUGIN_DIR"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"
mkdir -p "${BUNDLE_PATH}/Contents/Lib"

# Copy plugin dylib
cp ".build/debug/lib${PLUGIN_NAME}.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# Copy memex binary if exists
if [ -f "$MEMEX_BINARY" ]; then
    cp "$MEMEX_BINARY" "${BUNDLE_PATH}/Contents/Lib/"
    chmod +x "${BUNDLE_PATH}/Contents/Lib/memex"
    log_info "Memex binary copied"
fi

# Copy SharedDB (ai-cli-session-db FFI)
log_info "Copying SharedDB..."
mkdir -p "${BUNDLE_PATH}/Contents/Libs"
if [ -f "Libs/SharedDB/libai_cli_session_db.dylib" ]; then
    cp "Libs/SharedDB/libai_cli_session_db.dylib" "${BUNDLE_PATH}/Contents/Libs/"
    log_info "Copied libai_cli_session_db.dylib"
else
    log_warn "libai_cli_session_db.dylib not found - SharedDb features will be disabled"
fi

# SessionReaderFFI 已被 SharedDbFFI 替代，不再需要

# Copy Web UI if exists
if [ -d "$MEMEX_WEB_DIR" ]; then
    cp -r "$MEMEX_WEB_DIR" "${BUNDLE_PATH}/Contents/Resources/"
    log_info "Web UI copied to bundle"

    # 部署到 ~/.vimo/memex/public（与 memex-rs 共享）
    MEMEX_PUBLIC_DIR="${HOME}/.vimo/memex/public"
    rm -rf "$MEMEX_PUBLIC_DIR"
    mkdir -p "$MEMEX_PUBLIC_DIR"
    cp -r "$MEMEX_WEB_DIR"/* "$MEMEX_PUBLIC_DIR/"
    log_info "Web UI deployed to $MEMEX_PUBLIC_DIR"
fi

# Fix ETermKit link path
log_info "Fixing link paths..."
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
    "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Fix SharedDB link path
if [ -f "${BUNDLE_PATH}/Contents/Libs/libai_cli_session_db.dylib" ]; then
    OLD_PATH=$(otool -L "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib" | grep ai_cli_session_db | awk '{print $1}')
    if [ -n "$OLD_PATH" ]; then
        install_name_tool -change \
            "$OLD_PATH" \
            "@loader_path/../Libs/libai_cli_session_db.dylib" \
            "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib" 2>/dev/null || true
    fi
    install_name_tool -id \
        "@loader_path/../Libs/libai_cli_session_db.dylib" \
        "${BUNDLE_PATH}/Contents/Libs/libai_cli_session_db.dylib" 2>/dev/null || true
fi

# SessionReaderFFI link path 不再需要

# Re-sign after modification
log_info "Re-signing..."
codesign -f -s - "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"
if [ -f "${BUNDLE_PATH}/Contents/Libs/libai_cli_session_db.dylib" ]; then
    codesign -f -s - "${BUNDLE_PATH}/Contents/Libs/libai_cli_session_db.dylib"
fi

# Copy manifest.json
cp "Resources/manifest.json" "${BUNDLE_PATH}/Contents/Resources/"

# Create Info.plist
cat > "${BUNDLE_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.memex</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleVersion</key>
    <string>0.0.1-beta.1</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>lib${PLUGIN_NAME}.dylib</string>
    <key>NSPrincipalClass</key>
    <string>MemexKit.MemexPlugin</string>
</dict>
</plist>
EOF

log_success "Installed to ${BUNDLE_PATH}"
log_info "Bundle structure:"
ls -la "${BUNDLE_PATH}/Contents/MacOS/"
ls -la "${BUNDLE_PATH}/Contents/Lib/" 2>/dev/null || log_warn "No Lib directory (memex binary not included)"
