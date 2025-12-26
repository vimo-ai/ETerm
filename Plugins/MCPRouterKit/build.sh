#!/bin/bash
# build.sh - 构建 MCPRouterKit 插件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="MCPRouter"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"

# 输出目录：参数 > 环境变量 > 默认值
if [ -n "${BUNDLE_OUTPUT_DIR:-}" ]; then
    # 通过构建系统调用，输出到 {OUTPUT_DIR}/{PluginName}/{PluginName}.bundle
    OUTPUT_DIR="${BUNDLE_OUTPUT_DIR}/${PLUGIN_NAME}"
else
    OUTPUT_DIR="${HOME}/.eterm/plugins"
fi
mkdir -p "$OUTPUT_DIR"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[${PLUGIN_NAME}]${NC} $*"; }
log_success() { echo -e "${GREEN}[${PLUGIN_NAME}]${NC} $*"; }

# 构建 Swift Package
log_info "Building Swift package..."
cd "$SCRIPT_DIR"
swift build

# 创建 Bundle 结构
log_info "Creating bundle..."
rm -rf "$BUNDLE_PATH"
mkdir -p "${BUNDLE_PATH}/Contents/MacOS"
mkdir -p "${BUNDLE_PATH}/Contents/Frameworks"
mkdir -p "${BUNDLE_PATH}/Contents/Resources"

# 复制 dylib
cp ".build/debug/libMCPRouterKit.dylib" "${BUNDLE_PATH}/Contents/MacOS/"

# 复制 mcp_router_core dylib
# 按优先级搜索 dylib：
# 1. MCP_ROUTER_DYLIB 环境变量
# 2. ETerm 项目的 Libs 目录
# 3. 用户目录下的 .eterm/lib
MCP_ROUTER_DYLIB="${MCP_ROUTER_DYLIB:-}"
if [ -z "$MCP_ROUTER_DYLIB" ] || [ ! -f "$MCP_ROUTER_DYLIB" ]; then
    # 尝试 ETerm 项目的 Libs 目录
    ETERM_LIBS_PATH="${SCRIPT_DIR}/../../ETerm/Libs/MCPRouter/libmcp_router_core.dylib"
    if [ -f "$ETERM_LIBS_PATH" ]; then
        MCP_ROUTER_DYLIB="$ETERM_LIBS_PATH"
    fi
fi

if [ -z "$MCP_ROUTER_DYLIB" ] || [ ! -f "$MCP_ROUTER_DYLIB" ]; then
    # 尝试用户目录
    USER_LIB_PATH="${HOME}/.eterm/lib/libmcp_router_core.dylib"
    if [ -f "$USER_LIB_PATH" ]; then
        MCP_ROUTER_DYLIB="$USER_LIB_PATH"
    fi
fi

if [ -f "$MCP_ROUTER_DYLIB" ]; then
    log_info "Copying mcp_router_core.dylib from $MCP_ROUTER_DYLIB..."
    cp "$MCP_ROUTER_DYLIB" "${BUNDLE_PATH}/Contents/Frameworks/"
    codesign -f -s - "${BUNDLE_PATH}/Contents/Frameworks/libmcp_router_core.dylib"
else
    echo "⚠️  Warning: mcp_router_core.dylib not found"
    echo "   Set MCP_ROUTER_DYLIB env var or place dylib in:"
    echo "   - ETerm/Libs/MCPRouter/libmcp_router_core.dylib"
    echo "   - ~/.eterm/lib/libmcp_router_core.dylib"
fi

# 修改 ETermKit 链接路径：SPM dylib -> Xcode framework
# SPM 构建的是 libETermKit.dylib，但 app bundle 里是 ETermKit.framework
log_info "Fixing ETermKit link path for framework..."
install_name_tool -change \
    "@rpath/libETermKit.dylib" \
    "@rpath/ETermKit.framework/Versions/A/ETermKit" \
    "${BUNDLE_PATH}/Contents/MacOS/libMCPRouterKit.dylib"

# 重新签名（修改后需要重签）
codesign -f -s - "${BUNDLE_PATH}/Contents/MacOS/libMCPRouterKit.dylib"

# 复制 manifest.json
cp "Resources/manifest.json" "${BUNDLE_PATH}/Contents/Resources/"

# 创建 Info.plist
cat > "${BUNDLE_PATH}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.mcp-router</string>
    <key>CFBundleName</key>
    <string>MCPRouterKit</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleExecutable</key>
    <string>libMCPRouterKit.dylib</string>
    <key>NSPrincipalClass</key>
    <string>MCPRouterLogic</string>
</dict>
</plist>
EOF

log_success "✅ Installed to ${BUNDLE_PATH}"
