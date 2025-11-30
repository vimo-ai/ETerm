#!/usr/bin/env bash
set -euo pipefail
ROOT="/Users/higuaifan/Desktop/hi/小工具/english"
RIO_DIR="$ROOT/rio"
ETERM_DIR="$ROOT/ETerm"

echo "🔨 编译 sugarloaf-ffi..."
cd "$RIO_DIR"
cargo build --release -p sugarloaf-ffi

echo "📦 复制到 ETerm/ETerm/..."
cp "$RIO_DIR/target/release/libsugarloaf_ffi.a" "$ETERM_DIR/ETerm/libsugarloaf_ffi.a"
cp "$RIO_DIR/target/release/libsugarloaf_ffi.dylib" "$ETERM_DIR/ETerm/libsugarloaf_ffi.dylib" 2>/dev/null || true

echo "✅ 库文件已更新到 ETerm/ETerm/"
ls -lh "$ETERM_DIR/ETerm/libsugarloaf_ffi.a"
