#!/bin/bash
# VlaudeKit build script
# Note: This plugin uses Socket.IO (external SPM dependency)

set -euo pipefail

# DEBUG
echo "=== DEBUG VlaudeKit/build.sh ===" >> /tmp/eterm_plugin_debug.log
echo "Date: $(date)" >> /tmp/eterm_plugin_debug.log
echo "BUNDLE_OUTPUT_DIR = ${BUNDLE_OUTPUT_DIR:-NOT_SET}" >> /tmp/eterm_plugin_debug.log
echo "Caller: $(ps -o command= -p $PPID)" >> /tmp/eterm_plugin_debug.log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="VlaudeKit"
BUNDLE_ID="com.eterm.vlaude"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"

# Output directory: {plugins}/{id}/{name}.bundle
OUTPUT_DIR="${BUNDLE_OUTPUT_DIR:-${HOME}/.vimo/eterm/plugins}"
PLUGIN_DIR="${OUTPUT_DIR}/${BUNDLE_ID}"
BUNDLE_PATH="${PLUGIN_DIR}/${BUNDLE_NAME}"

# DEBUG: 输出实际路径
echo "OUTPUT_DIR = $OUTPUT_DIR" >> /tmp/eterm_plugin_debug.log
echo "BUNDLE_PATH = $BUNDLE_PATH" >> /tmp/eterm_plugin_debug.log
echo "" >> /tmp/eterm_plugin_debug.log

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

# Build Swift Package
log_info "Building Swift package..."
cd "$SCRIPT_DIR"

swift build

# Create Bundle structure
log_info "Creating bundle..."
rm -rf "$PLUGIN_DIR"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"
mkdir -p "${BUNDLE_PATH}/Contents/Frameworks"

# Copy plugin dylib
cp ".build/debug/lib${PLUGIN_NAME}.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# Copy SharedDB (claude-session-db FFI)
mkdir -p "${BUNDLE_PATH}/Contents/Libs"
log_info "Copying SharedDB..."
if [ -f "Libs/SharedDB/libclaude_session_db.dylib" ]; then
    cp "Libs/SharedDB/libclaude_session_db.dylib" "${BUNDLE_PATH}/Contents/Libs/"
    log_info "Copied libclaude_session_db.dylib"
else
    log_warn "libclaude_session_db.dylib not found - SharedDb features will be disabled"
fi

# Copy Socket.IO dependencies
# Socket.IO Swift client has several dylibs that need to be bundled
log_info "Copying Socket.IO dependencies..."
SOCKETIO_LIBS=(
    "libSocketIO.dylib"
    "libStarscream.dylib"
)

for lib in "${SOCKETIO_LIBS[@]}"; do
    if [ -f ".build/debug/$lib" ]; then
        cp ".build/debug/$lib" "${BUNDLE_PATH}/Contents/Frameworks/"
        log_info "Copied $lib"
    fi
done

# Fix link paths
log_info "Fixing link paths..."

# Fix ETermKit link path
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
    "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"

# Fix Socket.IO link paths (point to Frameworks folder)
for lib in "${SOCKETIO_LIBS[@]}"; do
    if [ -f "${BUNDLE_PATH}/Contents/Frameworks/$lib" ]; then
        # Fix the main plugin's reference to this lib
        install_name_tool -change \
            "@rpath/$lib" \
            "@loader_path/../Frameworks/$lib" \
            "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib" 2>/dev/null || true

        # Fix the lib's own install name
        install_name_tool -id \
            "@loader_path/../Frameworks/$lib" \
            "${BUNDLE_PATH}/Contents/Frameworks/$lib" 2>/dev/null || true
    fi
done

# Fix Starscream reference in SocketIO
if [ -f "${BUNDLE_PATH}/Contents/Frameworks/libSocketIO.dylib" ] && \
   [ -f "${BUNDLE_PATH}/Contents/Frameworks/libStarscream.dylib" ]; then
    install_name_tool -change \
        "@rpath/libStarscream.dylib" \
        "@loader_path/libStarscream.dylib" \
        "${BUNDLE_PATH}/Contents/Frameworks/libSocketIO.dylib" 2>/dev/null || true
fi

# Fix SharedDB link path
if [ -f "${BUNDLE_PATH}/Contents/Libs/libclaude_session_db.dylib" ]; then
    # Get the actual linked path from the dylib
    OLD_PATH=$(otool -L "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib" | grep claude_session_db | awk '{print $1}')
    if [ -n "$OLD_PATH" ]; then
        install_name_tool -change \
            "$OLD_PATH" \
            "@loader_path/../Libs/libclaude_session_db.dylib" \
            "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib" 2>/dev/null || true
    fi

    install_name_tool -id \
        "@loader_path/../Libs/libclaude_session_db.dylib" \
        "${BUNDLE_PATH}/Contents/Libs/libclaude_session_db.dylib" 2>/dev/null || true
fi

# Re-sign after modification
log_info "Re-signing..."
codesign -f -s - "${BUNDLE_PATH}/Contents/MacOS/lib${PLUGIN_NAME}.dylib"
for lib in "${SOCKETIO_LIBS[@]}"; do
    if [ -f "${BUNDLE_PATH}/Contents/Frameworks/$lib" ]; then
        codesign -f -s - "${BUNDLE_PATH}/Contents/Frameworks/$lib"
    fi
done
if [ -f "${BUNDLE_PATH}/Contents/Libs/libclaude_session_db.dylib" ]; then
    codesign -f -s - "${BUNDLE_PATH}/Contents/Libs/libclaude_session_db.dylib"
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
    <string>VlaudeKit.VlaudePlugin</string>
</dict>
</plist>
EOF

log_success "Installed to ${BUNDLE_PATH}"
log_info "Bundle structure:"
ls -la "${BUNDLE_PATH}/Contents/MacOS/"
ls -la "${BUNDLE_PATH}/Contents/Frameworks/" 2>/dev/null || log_warn "No Frameworks (Socket.IO libs may be statically linked)"
