#!/bin/bash
#
# validate_dylib.sh
# 验证 MCP Router dylib 的正确性
#
# 用法：
#   ./validate_dylib.sh <dylib_path>
#

set -e

DYLIB_PATH="$1"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查参数
if [ -z "$DYLIB_PATH" ]; then
    log_error "Usage: $0 <dylib_path>"
    exit 1
fi

log_info "🔍 Validating dylib: $DYLIB_PATH"
echo ""

# 1. 检查文件存在
log_info "[1/5] Checking if dylib exists..."
if [ ! -f "$DYLIB_PATH" ]; then
    log_error "dylib not found: $DYLIB_PATH"
    exit 1
fi
log_info "✅ dylib exists"
echo ""

# 2. 检查文件类型
log_info "[2/5] Checking file type..."
FILE_TYPE=$(file "$DYLIB_PATH")
if [[ ! "$FILE_TYPE" =~ "Mach-O" ]]; then
    log_error "Invalid file type: $FILE_TYPE"
    exit 1
fi
log_info "✅ File type: $FILE_TYPE"
echo ""

# 3. 检查 install_name
log_info "[3/5] Checking install_name..."
INSTALL_NAME=$(otool -D "$DYLIB_PATH" | tail -1)
log_info "install_name: $INSTALL_NAME"

if [[ "$INSTALL_NAME" != "@rpath"* ]] && [[ "$INSTALL_NAME" != "@loader_path"* ]] && [[ "$INSTALL_NAME" != "$DYLIB_PATH" ]]; then
    log_warn "install_name 可能需要调整为 @rpath 或 @loader_path"
    log_warn "当前值: $INSTALL_NAME"
fi
echo ""

# 4. 检查 FFI 符号
log_info "[4/5] Checking FFI symbols..."

REQUIRED_SYMBOLS=(
    "mcp_router_create"
    "mcp_router_destroy"
    "mcp_router_free_string"
    "mcp_router_init_logging"
    "mcp_router_version"
    "mcp_router_list_servers"
    "mcp_router_add_http_server"
    "mcp_router_start_server"
    "mcp_router_stop_server"
)

MISSING_SYMBOLS=()

for symbol in "${REQUIRED_SYMBOLS[@]}"; do
    if ! nm "$DYLIB_PATH" | grep -q "$symbol"; then
        MISSING_SYMBOLS+=("$symbol")
    fi
done

if [ ${#MISSING_SYMBOLS[@]} -eq 0 ]; then
    log_info "✅ All required symbols found (${#REQUIRED_SYMBOLS[@]})"
else
    log_error "Missing symbols:"
    for symbol in "${MISSING_SYMBOLS[@]}"; do
        log_error "  - $symbol"
    done
    exit 1
fi
echo ""

# 5. 检查依赖库
log_info "[5/5] Checking dependencies..."
DEPENDENCIES=$(otool -L "$DYLIB_PATH" | tail -n +2)
log_info "Dependencies:"
echo "$DEPENDENCIES"

# 检查是否有绝对路径的系统库（可能导致部署问题）
if echo "$DEPENDENCIES" | grep -q "^[[:space:]]*/usr/local"; then
    log_warn "Found dependencies in /usr/local, may cause deployment issues"
fi
echo ""

# 总结
log_info "🎉 Validation completed successfully!"
log_info ""
log_info "Summary:"
log_info "  File: $DYLIB_PATH"
log_info "  Size: $(du -h "$DYLIB_PATH" | cut -f1)"
log_info "  Symbols: ${#REQUIRED_SYMBOLS[@]} required symbols found"

exit 0
