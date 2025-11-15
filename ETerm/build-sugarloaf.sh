#!/bin/bash

# 构建脚本: 编译 sugarloaf-ffi 并复制到 Xcode 项目

set -e

echo "🔨 编译 sugarloaf-ffi..."
cd "$(dirname "$0")/../sugarloaf-ffi"

# 编译 release 版本
cargo build --release

echo "📦 复制动态库到 Xcode 项目..."
DYLIB_SRC="target/release/libsugarloaf_ffi.dylib"
DYLIB_DST="../ETerm/ETerm/libsugarloaf_ffi.dylib"

if [ -f "$DYLIB_SRC" ]; then
    cp "$DYLIB_SRC" "$DYLIB_DST"
    echo "✅ 动态库已复制到: $DYLIB_DST"
else
    echo "❌ 错误: 找不到编译后的动态库"
    exit 1
fi

echo "🎉 构建完成!"
echo ""
echo "下一步:"
echo "1. 在 Xcode 中将 libsugarloaf_ffi.dylib 添加到项目"
echo "2. 在 Build Settings -> Header Search Paths 添加头文件路径"
echo "3. 在 Build Phases -> Link Binary With Libraries 添加 libsugarloaf_ffi.dylib"
