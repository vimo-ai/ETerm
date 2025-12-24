#!/bin/bash
# create_kit.sh - 快速创建插件 Kit 脚手架
#
# 用法：
#   ./create_kit.sh PluginName
#   创建 Plugins/PluginNameKit/ 目录和基础文件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="${PROJECT_ROOT}/Plugins"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# 检查参数
if [ $# -lt 1 ]; then
    log_error "Usage: $0 PluginName"
    echo ""
    echo "Examples:"
    echo "  $0 Claude       # Creates ClaudeKit"
    echo "  $0 Translation  # Creates TranslationKit"
    exit 1
fi

PLUGIN_NAME="$1"
KIT_NAME="${PLUGIN_NAME}Kit"
KIT_DIR="${PLUGINS_DIR}/${KIT_NAME}"

# 检查目录是否已存在
if [ -d "$KIT_DIR" ]; then
    log_error "Kit already exists: ${KIT_DIR}"
    exit 1
fi

log_info "Creating ${KIT_NAME}..."

# 创建目录结构
mkdir -p "${KIT_DIR}/Sources/${KIT_NAME}"
mkdir -p "${KIT_DIR}/Tests/${KIT_NAME}Tests"

# 创建 Package.swift
log_info "Creating Package.swift..."
cat > "${KIT_DIR}/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "${KIT_NAME}",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "${KIT_NAME}",
            type: .dynamic,
            targets: ["${KIT_NAME}"]
        ),
    ],
    targets: [
        .target(
            name: "${KIT_NAME}",
            path: "Sources/${KIT_NAME}"
        ),
        .testTarget(
            name: "${KIT_NAME}Tests",
            dependencies: ["${KIT_NAME}"],
            path: "Tests/${KIT_NAME}Tests"
        ),
    ]
)
EOF

# 创建主 Swift 文件
log_info "Creating ${KIT_NAME}.swift..."
cat > "${KIT_DIR}/Sources/${KIT_NAME}/${KIT_NAME}.swift" <<EOF
import Foundation

/// ${PLUGIN_NAME} 插件实现
///
/// 实现 ETPluginProtocol 协议以支持热插拔加载
public final class ${PLUGIN_NAME}Plugin {
    public init() {}

    public func activate() {
        print("[\(type(of: self))] Plugin activated")
        // TODO: 初始化插件逻辑
    }

    public func deactivate() {
        print("[\(type(of: self))] Plugin deactivated")
        // TODO: 清理资源
    }
}

// MARK: - Plugin Entry Point

/// Bundle 加载入口
/// dlopen 加载后会调用此函数
@_cdecl("${PLUGIN_NAME}PluginMain")
public func pluginMain() -> UnsafeMutableRawPointer {
    let plugin = ${PLUGIN_NAME}Plugin()
    plugin.activate()
    return Unmanaged.passRetained(plugin as AnyObject).toOpaque()
}
EOF

# 创建测试文件
log_info "Creating test file..."
cat > "${KIT_DIR}/Tests/${KIT_NAME}Tests/${KIT_NAME}Tests.swift" <<EOF
import XCTest
@testable import ${KIT_NAME}

final class ${KIT_NAME}Tests: XCTestCase {
    func testPluginInitialization() {
        let plugin = ${PLUGIN_NAME}Plugin()
        XCTAssertNotNil(plugin)
    }
}
EOF

# 创建 Info.plist
log_info "Creating Info.plist..."
cat > "${KIT_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eterm.plugins.${PLUGIN_NAME}</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${PLUGIN_NAME} Plugin</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $(date +%Y) ETerm. All rights reserved.</string>
</dict>
</plist>
EOF

# 复制 build.sh
log_info "Creating build.sh..."
if [ -f "${TEMPLATE_DIR}/build.sh.template" ]; then
    cp "${TEMPLATE_DIR}/build.sh.template" "${KIT_DIR}/build.sh"
    chmod +x "${KIT_DIR}/build.sh"
else
    log_warn "Template not found, creating minimal build.sh..."
    cat > "${KIT_DIR}/build.sh" <<'EOFBUILD'
#!/bin/bash
# See Scripts/templates/build.sh.template for full implementation
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT_DIR"
swift build
EOFBUILD
    chmod +x "${KIT_DIR}/build.sh"
fi

# 创建 .gitignore
log_info "Creating .gitignore..."
cat > "${KIT_DIR}/.gitignore" <<EOF
.DS_Store
.build/
.swiftpm/
*.xcodeproj
*.xcworkspace
build/
DerivedData/
EOF

# 创建 README
log_info "Creating README.md..."
cat > "${KIT_DIR}/README.md" <<EOF
# ${KIT_NAME}

${PLUGIN_NAME} plugin for ETerm.

## Structure

\`\`\`
${KIT_NAME}/
├── Package.swift          # Swift Package 定义
├── Info.plist             # Bundle 元数据
├── build.sh               # 构建脚本
├── Sources/
│   └── ${KIT_NAME}/
│       └── ${KIT_NAME}.swift
└── Tests/
    └── ${KIT_NAME}Tests/
        └── ${KIT_NAME}Tests.swift
\`\`\`

## Development

### Build
\`\`\`bash
./build.sh
\`\`\`

### Test
\`\`\`bash
swift test
\`\`\`

## Integration

Add to ETerm Xcode project as a local Swift Package.
EOF

log_success "✅ ${KIT_NAME} created successfully!"
echo ""
log_info "Next steps:"
echo "  1. cd ${KIT_DIR}"
echo "  2. Edit Sources/${KIT_NAME}/${KIT_NAME}.swift"
echo "  3. Run ./build.sh to build"
echo "  4. Add to Xcode project as local package"
echo ""
log_info "Files created:"
echo "  - Package.swift"
echo "  - Sources/${KIT_NAME}/${KIT_NAME}.swift"
echo "  - Tests/${KIT_NAME}Tests/${KIT_NAME}Tests.swift"
echo "  - Info.plist"
echo "  - build.sh"
echo "  - README.md"
