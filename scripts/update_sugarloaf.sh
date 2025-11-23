#!/usr/bin/env bash
set -euo pipefail
ROOT="/Users/higuaifan/Desktop/hi/小工具/english"
FFI_DIR="$ROOT/sugarloaf-ffi"
ETERM_DIR="$ROOT/ETerm"

cd "$FFI_DIR"
cargo build --release

# 统一复制到 ETerm/ETerm/ 目录（Xcode 项目配置的位置）
cp "$FFI_DIR/target/release/libsugarloaf_ffi.a" "$ETERM_DIR/ETerm/libsugarloaf_ffi.a"
cp "$FFI_DIR/target/release/libsugarloaf_ffi.dylib" "$ETERM_DIR/ETerm/libsugarloaf_ffi.dylib"

echo "✅ 库文件已更新到 ETerm/ETerm/"
