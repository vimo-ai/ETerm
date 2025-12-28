#!/bin/bash
# build_plugins_xcode.sh - 使用 Xcode 构建的 ETermKit 编译插件
#
# 解决问题：SPM 独立构建 ETermKit 导致 Protocol Witness Table 不匹配
# 方案：让插件使用 Xcode 构建的 ETermKit.framework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="$(cd "${PROJECT_ROOT}/../Plugins" && pwd)"

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

# 验证 ETermKit.framework 存在
validate_framework() {
    local derived_data="$1"
    local framework_path="$derived_data/Build/Products/Debug/ETerm.app/Contents/Frameworks/ETermKit.framework"
    local module_path="$derived_data/Build/Products/Debug/ETermKit.swiftmodule"

    if [[ ! -d "$framework_path" ]] || [[ ! -d "$module_path" ]]; then
        log_error "ETermKit.framework 或 swiftmodule 不存在"
        log_error "请先用 Xcode 构建 ETerm 应用"
        exit 1
    fi

    echo "$derived_data/Build/Products/Debug"
}

# 构建单个插件
build_plugin() {
    local kit_path="$1"
    local build_products="$2"
    local output_dir="$3"

    local kit_name=$(basename "$kit_path")
    local bundle_name="${kit_name}.bundle"
    local bundle_path="${output_dir}/${bundle_name}"

    log_info "构建 ${kit_name}..."

    cd "$kit_path"

    # 清理旧的 SPM 构建缓存（确保不使用旧的 ETermKit）
    rm -rf .build/debug/ETermKit* .build/debug/libETermKit* 2>/dev/null || true

    # 使用 Xcode 构建的 ETermKit 进行编译
    # -Xswiftc -I: 添加 swiftmodule 搜索路径
    # -Xswiftc -F: 添加 framework 搜索路径
    # -Xlinker -F: 链接时的 framework 搜索路径
    # -Xlinker -rpath: 运行时搜索路径
    swift build \
        -Xswiftc -I"${build_products}" \
        -Xswiftc -F"${build_products}/PackageFrameworks" \
        -Xswiftc -F"${build_products}/ETerm.app/Contents/Frameworks" \
        -Xlinker -F"${build_products}/PackageFrameworks" \
        -Xlinker -F"${build_products}/ETerm.app/Contents/Frameworks" \
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
        2>&1 || {
            log_error "${kit_name} 构建失败"
            return 1
        }

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
    install_name_tool -change \
        "@rpath/libETermKit.dylib" \
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

# 主函数
main() {
    local output_dir="${1:-$HOME/.eterm/plugins}"
    mkdir -p "$output_dir"

    log_info "========================================"
    log_info "使用 Xcode ETermKit 构建插件"
    log_info "========================================"

    # 查找 DerivedData
    local derived_data=$(find_derived_data)
    log_info "DerivedData: $derived_data"

    # 验证 framework
    local build_products=$(validate_framework "$derived_data")
    log_info "Build Products: $build_products"

    # 验证 ETermKit UUID
    local framework_uuid=$(dwarfdump --uuid "${build_products}/ETerm.app/Contents/Frameworks/ETermKit.framework/ETermKit" 2>/dev/null | grep -o 'UUID: [A-F0-9-]*' | head -1)
    log_info "ETermKit UUID: $framework_uuid"

    local success_count=0
    local fail_count=0

    # 构建所有插件
    for kit in "${PLUGINS_DIR}"/*Kit; do
        [[ ! -d "$kit" ]] && continue
        [[ ! -f "$kit/Package.swift" ]] && continue

        if build_plugin "$kit" "$build_products" "$output_dir"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done

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
