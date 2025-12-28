#!/bin/bash
# ============================================================================
# ETerm 开发环境快速启动脚本
# 用于新贡献者首次构建和运行，或干净环境测试
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[ETerm]${NC} $*"; }
log_success() { echo -e "${GREEN}[ETerm]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ETerm]${NC} $*"; }
log_error() { echo -e "${RED}[ETerm]${NC} $*"; }

# 默认使用隔离环境
ETERM_HOME="${ETERM_HOME:-/tmp/.eterm-dev}"
SKIP_RUST="${SKIP_RUST:-false}"
SKIP_BUILD="${SKIP_BUILD:-false}"
RUN_APP="${RUN_APP:-true}"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --home PATH     设置 ETERM_HOME (默认: /tmp/.eterm-dev)"
    echo "  --skip-rust     跳过 Rust FFI 构建"
    echo "  --skip-build    跳过 Xcode 构建（仅启动）"
    echo "  --no-run        仅构建，不启动"
    echo "  --clean         清理并重新构建"
    echo "  -h, --help      显示帮助"
    exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --home)
            ETERM_HOME="$2"
            shift 2
            ;;
        --skip-rust)
            SKIP_RUST=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --no-run)
            RUN_APP=false
            shift
            ;;
        --clean)
            log_info "清理构建缓存..."
            rm -rf "$PROJECT_DIR/ETerm/ETerm.xcodeproj/project.xcworkspace/xcuserdata"
            rm -rf ~/Library/Developer/Xcode/DerivedData/ETerm-*
            rm -rf "$ETERM_HOME"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "未知参数: $1"
            usage
            ;;
    esac
done

log_info "=========================================="
log_info "ETerm 开发环境快速启动"
log_info "=========================================="
log_info "ETERM_HOME: $ETERM_HOME"
echo ""

# Step 1: 构建 Rust FFI
if [ "$SKIP_RUST" = false ]; then
    log_info "[1/3] 构建 Rust FFI (sugarloaf)..."
    if [ -f "$PROJECT_DIR/scripts/update_sugarloaf_dev.sh" ]; then
        "$PROJECT_DIR/scripts/update_sugarloaf_dev.sh"
        log_success "Rust FFI 构建完成"
    else
        log_warn "未找到 update_sugarloaf_dev.sh，跳过 Rust 构建"
    fi
else
    log_info "[1/3] 跳过 Rust FFI 构建"
fi
echo ""

# Step 2: Xcode 构建
if [ "$SKIP_BUILD" = false ]; then
    log_info "[2/3] Xcode 构建..."
    cd "$PROJECT_DIR/ETerm"

    # 使用 xcodebuild
    xcodebuild -project ETerm.xcodeproj \
        -scheme ETerm \
        -configuration Debug \
        build \
        | grep -E "^(Build|Compile|Link|Copy|Sign|error:|warning:|\*\*)" || true

    log_success "Xcode 构建完成"
else
    log_info "[2/3] 跳过 Xcode 构建"
fi
echo ""

# 找到构建产物
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ETerm-*/Build/Products/Debug/ETerm.app -maxdepth 0 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    log_error "未找到构建产物 ETerm.app"
    exit 1
fi
log_info "App 路径: $APP_PATH"

# Step 3: 启动
if [ "$RUN_APP" = true ]; then
    log_info "[3/3] 启动 ETerm (隔离环境)..."

    # 创建隔离的 ETERM_HOME
    mkdir -p "$ETERM_HOME"

    # 启动，设置环境变量
    ETERM_HOME="$ETERM_HOME" "$APP_PATH/Contents/MacOS/ETerm" &
    APP_PID=$!

    log_success "ETerm 已启动 (PID: $APP_PID)"
    log_info "数据目录: $ETERM_HOME"
    log_info ""
    log_info "提示: 按 Ctrl+C 或关闭窗口退出"

    # 等待进程结束
    wait $APP_PID 2>/dev/null || true
else
    log_info "[3/3] 跳过启动"
    log_success "构建完成！"
    log_info "手动启动: ETERM_HOME=$ETERM_HOME $APP_PATH/Contents/MacOS/ETerm"
fi
