#!/bin/bash
# 极简插件构建系统 - 调用每个 Kit 的 build.sh
#
# 用法:
#   ./build_all_plugins.sh                    # 默认输出到 ~/.vimo/eterm/plugins/
#   ./build_all_plugins.sh /path/to/output    # 指定输出目录

set -euo pipefail

# 清理残留的插件进程（避免旧进程占用端口）
pkill -f "MemexKit.bundle/Contents/Lib/memex" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_DIR="$(cd "${PROJECT_ROOT}/../Plugins" && pwd)"

# 输出目录：参数 > 环境变量 > 默认值
BUNDLE_OUTPUT_DIR="${1:-${BUNDLE_OUTPUT_DIR:-$HOME/.vimo/eterm/plugins}}"
mkdir -p "$BUNDLE_OUTPUT_DIR"

# 导出环境变量供 build.sh 使用
export BUNDLE_OUTPUT_DIR
export CONFIGURATION="${CONFIGURATION:-Debug}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 主函数
main() {
    log_info "Building all plugins..."
    log_info "Output directory: ${BUNDLE_OUTPUT_DIR}"

    local success_count=0
    local fail_count=0

    # 扫描 *Kit 和 *SDK 目录
    for kit in "${PLUGINS_DIR}"/*Kit "${PLUGINS_DIR}"/*SDK; do
        [[ ! -d "$kit" ]] && continue

        local kit_name=$(basename "$kit")
        local build_script="${kit}/build.sh"

        if [[ ! -f "$build_script" ]]; then
            log_info "Skipping ${kit_name} (no build.sh)"
            continue
        fi

        log_info "Building ${kit_name}..."

        if bash "$build_script"; then
            log_success "${kit_name} built successfully"
            ((success_count++))
        else
            log_error "${kit_name} build failed"
            ((fail_count++))
        fi
    done

    echo "" >&2
    log_info "========================================"
    log_info "Build Summary"
    log_info "========================================"
    log_success "Successful: ${success_count}"

    if [[ $fail_count -gt 0 ]]; then
        log_error "Failed: ${fail_count}"
        exit 1
    fi

    log_success "All plugins built successfully!"
}

main "$@"
