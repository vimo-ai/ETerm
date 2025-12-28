#!/bin/bash
# build_plugins_swiftc.sh - 使用 swiftc 直接编译插件
#
# 绕过 SPM，直接使用 Xcode 构建的 ETermKit.framework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="$(cd "${PROJECT_ROOT}/../Plugins" && pwd)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 查找 Build Products 目录
find_build_products() {
    # 优先使用 Xcode 环境变量
    if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
        echo "$BUILT_PRODUCTS_DIR"
        return
    fi

    # 否则从 DerivedData 查找
    local derived=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name "ETerm-*" -type d 2>/dev/null | head -1)
    [[ -z "$derived" ]] && { log_error "找不到 ETerm DerivedData"; exit 1; }
    echo "${derived}/Build/Products/Debug"
}

# 构建单个插件
build_plugin() {
    local kit_path="$1"
    local build_products="$2"
    local output_dir="$3"

    local kit_name=$(basename "$kit_path")
    local bundle_path="${output_dir}/${kit_name}.bundle"
    local sources_dir="${kit_path}/Sources/${kit_name}"

    log_info "构建 ${kit_name}..."

    # 查找所有 Swift 源文件
    local sources=$(find "$sources_dir" -name "*.swift" 2>/dev/null)
    if [[ -z "$sources" ]]; then
        log_error "${kit_name} 没有找到源文件"
        return 1
    fi

    # 创建临时构建目录
    local build_dir="${kit_path}/.build_swiftc"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # 编译参数
    local framework_path="${build_products}/ETerm.app/Contents/Frameworks"
    local module_path="${build_products}"

    # 使用 swiftc 编译
    swiftc \
        -emit-library \
        -o "${build_dir}/lib${kit_name}.dylib" \
        -module-name "$kit_name" \
        -emit-module \
        -emit-module-path "${build_dir}/${kit_name}.swiftmodule" \
        -parse-as-library \
        -target arm64-apple-macos14.0 \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -I "$module_path" \
        -F "$framework_path" \
        -framework ETermKit \
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
        -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
        $sources 2>&1 || {
            log_error "${kit_name} 编译失败"
            return 1
        }

    # 创建 bundle
    rm -rf "$bundle_path"
    mkdir -p "${bundle_path}/Contents/MacOS"
    mkdir -p "${bundle_path}/Contents/Resources"

    # 复制 dylib
    cp "${build_dir}/lib${kit_name}.dylib" "${bundle_path}/Contents/MacOS/${kit_name}"

    # 修复 ETermKit 路径
    install_name_tool -change \
        "@rpath/ETermKit.framework/Versions/A/ETermKit" \
        "@executable_path/../Frameworks/ETermKit.framework/ETermKit" \
        "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    install_name_tool -id \
        "@rpath/lib${kit_name}.dylib" \
        "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    # 签名
    codesign -f -s - "${bundle_path}/Contents/MacOS/${kit_name}" 2>/dev/null || true

    # 复制 manifest
    [[ -f "${kit_path}/Resources/manifest.json" ]] && \
        cp "${kit_path}/Resources/manifest.json" "${bundle_path}/Contents/Resources/"

    # Info.plist
    local plugin_id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "${kit_path}/Resources/manifest.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    plugin_id="${plugin_id:-com.eterm.${kit_name}}"

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
</dict>
</plist>
EOF

    # 清理
    rm -rf "$build_dir"

    log_success "${kit_name} 完成"
    return 0
}

main() {
    local output_dir="${1:-$HOME/.eterm/plugins}"
    mkdir -p "$output_dir"

    log_info "========================================"
    log_info "使用 swiftc 直接编译插件"
    log_info "========================================"

    local build_products=$(find_build_products)
    log_info "Build Products: $build_products"

    # 验证 ETermKit
    local framework="${build_products}/ETerm.app/Contents/Frameworks/ETermKit.framework/ETermKit"
    [[ ! -f "$framework" ]] && { log_error "ETermKit.framework 不存在"; exit 1; }

    local uuid=$(dwarfdump --uuid "$framework" 2>/dev/null | grep -o 'UUID: [A-F0-9-]*')
    log_info "ETermKit $uuid"

    local success=0 fail=0

    for kit in "${PLUGINS_DIR}"/*Kit; do
        [[ ! -d "$kit" ]] && continue
        [[ ! -d "$kit/Sources" ]] && continue

        if build_plugin "$kit" "$build_products" "$output_dir"; then
            ((success++))
        else
            ((fail++))
        fi
    done

    echo "" >&2
    log_info "========================================"
    log_success "成功: $success"
    [[ $fail -gt 0 ]] && log_error "失败: $fail (非关键错误，继续)"

    log_success "插件构建完成！"
}

main "$@"
