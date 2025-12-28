#!/bin/bash
# build_plugins_binary.sh - 使用 binaryTarget 方式构建插件
#
# 核心思路：
# 1. 从 Xcode DerivedData 创建 ETermKit.xcframework
# 2. 临时修改 Package.swift 使用 binaryTarget
# 3. 构建插件
# 4. 恢复 Package.swift

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="$(cd "${PROJECT_ROOT}/../Plugins" && pwd)"
PACKAGES_DIR="$(cd "${PROJECT_ROOT}/../Packages" && pwd)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# 查找 Xcode DerivedData 路径
find_derived_data() {
    local derived_data_base="$HOME/Library/Developer/Xcode/DerivedData"
    local eterm_derived=$(find "$derived_data_base" -maxdepth 1 -name "ETerm-*" -type d 2>/dev/null | head -1)

    if [[ -z "$eterm_derived" ]]; then
        log_error "找不到 ETerm 的 DerivedData，请先用 Xcode 构建主应用"
        exit 1
    fi

    echo "$eterm_derived"
}

# 创建 ETermKit.xcframework
create_xcframework() {
    local derived_data="$1"
    local output_dir="$2"

    local framework_path="${derived_data}/Build/Products/Debug/ETerm.app/Contents/Frameworks/ETermKit.framework"
    local module_path="${derived_data}/Build/Products/Debug/ETermKit.swiftmodule"
    local xcframework_path="${output_dir}/ETermKit.xcframework"

    if [[ ! -d "$framework_path" ]]; then
        log_error "ETermKit.framework 不存在: $framework_path"
        exit 1
    fi

    log_info "创建 ETermKit.xcframework..."

    # 删除旧的 xcframework
    rm -rf "$xcframework_path"

    # 创建临时 framework 副本，包含完整的 Modules
    local temp_framework="${output_dir}/ETermKit.framework"
    rm -rf "$temp_framework"
    cp -R "$framework_path" "$temp_framework"

    # 复制 swiftmodule 到 framework 的 Modules 目录
    mkdir -p "${temp_framework}/Modules/ETermKit.swiftmodule"
    cp -R "${module_path}/"* "${temp_framework}/Modules/ETermKit.swiftmodule/"

    # 创建 module.modulemap
    cat > "${temp_framework}/Modules/module.modulemap" << 'EOF'
framework module ETermKit {
    header "ETermKit-Swift.h"
    requires objc
}
EOF

    # 创建 xcframework
    xcodebuild -create-xcframework \
        -framework "$temp_framework" \
        -output "$xcframework_path" 2>/dev/null || {
            log_error "创建 xcframework 失败"
            exit 1
        }

    # 清理临时 framework
    rm -rf "$temp_framework"

    log_success "xcframework 创建成功: $xcframework_path"
    echo "$xcframework_path"
}

# 修改 Package.swift 使用 binaryTarget
patch_package_swift() {
    local kit_path="$1"
    local xcframework_path="$2"
    local package_swift="${kit_path}/Package.swift"
    local package_backup="${kit_path}/Package.swift.bak"

    # 备份原始文件
    cp "$package_swift" "$package_backup"

    # 创建新的 Package.swift
    cat > "$package_swift" << EOF
// swift-tools-version: 6.0
// 临时修改：使用 Xcode 构建的 ETermKit.xcframework

import PackageDescription

let package = Package(
    name: "$(basename "$kit_path")",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "$(basename "$kit_path")",
            type: .dynamic,
            targets: ["$(basename "$kit_path")"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "ETermKit",
            path: "${xcframework_path}"
        ),
        .target(
            name: "$(basename "$kit_path")",
            dependencies: ["ETermKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
EOF
}

# 恢复 Package.swift
restore_package_swift() {
    local kit_path="$1"
    local package_swift="${kit_path}/Package.swift"
    local package_backup="${kit_path}/Package.swift.bak"

    if [[ -f "$package_backup" ]]; then
        mv "$package_backup" "$package_swift"
    fi
}

# 构建单个插件
build_plugin() {
    local kit_path="$1"
    local xcframework_path="$2"
    local output_dir="$3"

    local kit_name=$(basename "$kit_path")
    local bundle_name="${kit_name}.bundle"
    local bundle_path="${output_dir}/${bundle_name}"

    log_info "构建 ${kit_name}..."

    cd "$kit_path"

    # 清理 SPM 缓存
    rm -rf .build 2>/dev/null || true

    # 修改 Package.swift
    patch_package_swift "$kit_path" "$xcframework_path"

    # 构建
    local build_result=0
    swift build 2>&1 || build_result=$?

    # 恢复 Package.swift
    restore_package_swift "$kit_path"

    if [[ $build_result -ne 0 ]]; then
        log_error "${kit_name} 构建失败"
        return 1
    fi

    # 创建 bundle 结构
    rm -rf "$bundle_path"
    mkdir -p "${bundle_path}/Contents/MacOS"
    mkdir -p "${bundle_path}/Contents/Resources"

    # 查找构建产物
    local dylib_name="lib${kit_name}.dylib"
    local dylib_path=".build/debug/${dylib_name}"

    if [[ ! -f "$dylib_path" ]]; then
        log_error "找不到构建产物: ${dylib_path}"
        return 1
    fi

    # 复制动态库
    cp "$dylib_path" "${bundle_path}/Contents/MacOS/${kit_name}"

    # 修复 ETermKit 依赖路径
    # xcframework 会产生 @rpath/ETermKit.framework/Versions/A/ETermKit 的引用
    install_name_tool -change \
        "@rpath/ETermKit.framework/Versions/A/ETermKit" \
        "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
        "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    install_name_tool -change \
        "@rpath/ETermKit.framework/ETermKit" \
        "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
        "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    # 修复 install_name
    install_name_tool -id \
        "@rpath/lib${kit_name}.dylib" \
        "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    # 重签名
    codesign -f -s - "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    # 复制 manifest.json
    if [[ -f "Resources/manifest.json" ]]; then
        cp "Resources/manifest.json" "${bundle_path}/Contents/Resources/"
    fi

    # 创建 Info.plist
    local plugin_id=$(cat "Resources/manifest.json" 2>/dev/null | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    plugin_id="${plugin_id:-com.eterm.plugins.${kit_name}}"

    cat > "${bundle_path}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${plugin_id}</string>
    <key>CFBundleName</key>
    <string>${kit_name}</string>
    <key>CFBundleExecutable</key>
    <string>${kit_name}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
</dict>
</plist>
EOF

    log_success "${kit_name} 构建完成"
    return 0
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    # 恢复所有可能被修改的 Package.swift
    for kit in "${PLUGINS_DIR}"/*Kit; do
        [[ -d "$kit" ]] && restore_package_swift "$kit"
    done
}

trap cleanup EXIT

# 主函数
main() {
    local output_dir="${1:-$HOME/.eterm/plugins}"
    mkdir -p "$output_dir"

    log_info "========================================"
    log_info "使用 binaryTarget 方式构建插件"
    log_info "========================================"

    # 查找 DerivedData
    local derived_data=$(find_derived_data)
    log_info "DerivedData: $derived_data"

    # 创建 xcframework
    local temp_dir=$(mktemp -d)
    local xcframework_path=$(create_xcframework "$derived_data" "$temp_dir")

    # 验证 ETermKit UUID
    local framework_uuid=$(dwarfdump --uuid "${xcframework_path}/macos-arm64/ETermKit.framework/ETermKit" 2>/dev/null | grep -o 'UUID: [A-F0-9-]*' | head -1)
    log_info "ETermKit UUID: $framework_uuid"

    local success_count=0
    local fail_count=0

    # 构建所有插件
    for kit in "${PLUGINS_DIR}"/*Kit; do
        [[ ! -d "$kit" ]] && continue
        [[ ! -f "$kit/Package.swift" ]] && continue

        if build_plugin "$kit" "$xcframework_path" "$output_dir"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

    # 清理临时目录
    rm -rf "$temp_dir"

    echo "" >&2
    log_info "========================================"
    log_info "构建摘要"
    log_info "========================================"
    log_success "成功: ${success_count}"

    if [[ $fail_count -gt 0 ]]; then
        log_error "失败: ${fail_count}"
        exit 1
    fi

    log_success "所有插件构建完成！"
}

main "$@"
