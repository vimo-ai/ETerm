#!/bin/bash
#
# build_rust_dylib.sh
# 构建 MCP Router Rust dylib
#
# 用法：
#   ./build_rust_dylib.sh [debug|release]
#
# 环境变量：
#   RUST_PROJECT_DIR: Rust 项目路径（默认：~/Desktop/vimo/mcp-router/core）
#   OUTPUT_DIR: 输出目录（默认：./build）
#

set -e

# 配置
RUST_PROJECT_DIR="${RUST_PROJECT_DIR:-/Users/higuaifan/Desktop/vimo/mcp-router/core}"
BUILD_TYPE="${1:-debug}"
DYLIB_NAME="libmcp_router_core.dylib"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../build}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Rust 项目目录
if [ ! -d "$RUST_PROJECT_DIR" ]; then
    log_error "Rust project directory not found: $RUST_PROJECT_DIR"
    log_info "Please set RUST_PROJECT_DIR environment variable"
    exit 1
fi

log_info "Building Rust dylib..."
log_info "  Project: $RUST_PROJECT_DIR"
log_info "  Build type: $BUILD_TYPE"

# 切换到 Rust 项目目录
cd "$RUST_PROJECT_DIR"

# 构建
if [ "$BUILD_TYPE" == "release" ]; then
    log_info "Building release version..."
    cargo build --release
    RUST_TARGET_DIR="target/release"
else
    log_info "Building debug version..."
    cargo build
    RUST_TARGET_DIR="target/debug"
fi

# 检查 dylib 是否生成
DYLIB_PATH="${RUST_TARGET_DIR}/${DYLIB_NAME}"
if [ ! -f "$DYLIB_PATH" ]; then
    log_error "dylib not found: $DYLIB_PATH"
    exit 1
fi

log_info "✅ Rust dylib built successfully: $DYLIB_PATH"

# 显示 dylib 信息
log_info "dylib info:"
otool -D "$DYLIB_PATH"
log_info "Size: $(du -h "$DYLIB_PATH" | cut -f1)"

# 可选：复制到输出目录
if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp "$DYLIB_PATH" "$OUTPUT_DIR/"
    log_info "✅ dylib copied to: $OUTPUT_DIR/$DYLIB_NAME"
fi

log_info "🎉 Build completed successfully!"
