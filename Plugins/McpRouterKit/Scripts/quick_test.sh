#!/bin/bash
#
# quick_test.sh
# 快速测试脚本：构建 dylib 并验证
#
# 用法：
#   ./quick_test.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 打印标题
echo ""
echo "======================================"
echo "  McpRouterKit Quick Test"
echo "======================================"
echo ""

# Step 1: 检查 Rust 环境
log_step "1/4 Checking Rust environment..."
if ! command -v cargo &> /dev/null; then
    log_error "Rust/Cargo not found. Please install Rust from https://rustup.rs"
    exit 1
fi
log_info "✅ Rust version: $(cargo --version)"
echo ""

# Step 2: 构建 dylib
log_step "2/4 Building Rust dylib..."
"$SCRIPT_DIR/build_rust_dylib.sh" debug
echo ""

# Step 3: 验证 dylib
log_step "3/4 Validating dylib..."
DYLIB_PATH="$PROJECT_ROOT/build/libmcp_router_core.dylib"
"$SCRIPT_DIR/validate_dylib.sh" "$DYLIB_PATH"
echo ""

# Step 4: 显示集成信息
log_step "4/4 Integration info..."
echo ""
log_info "✅ All tests passed!"
echo ""
log_info "Next steps:"
echo "  1. Open ETerm.xcodeproj in Xcode"
echo "  2. Add McpRouterKit as a local Swift Package"
echo "  3. Follow the integration guide: $PROJECT_ROOT/INTEGRATION_GUIDE.md"
echo ""
log_info "dylib location:"
echo "  $DYLIB_PATH"
echo ""
log_info "Environment variables (optional):"
echo "  export MCP_ROUTER_DYLIB_PATH=\"$DYLIB_PATH\""
echo ""

echo "======================================"
echo "  Quick Test Completed Successfully!"
echo "======================================"
echo ""
