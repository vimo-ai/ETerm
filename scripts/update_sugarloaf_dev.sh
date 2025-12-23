#!/usr/bin/env bash
# ============================================================================
# 开发时使用的 Sugarloaf 快速编译脚本
# ============================================================================
# 用途：日常开发时快速编译和更新 sugarloaf-ffi 库
# 特点：使用 dev-fast profile，编译速度比 release 快 3-5 倍
# 性能：二进制性能损失 < 5%，完全够开发使用
#
# 使用场景：
#   - 日常开发调试
#   - 频繁修改 Rust 代码时
#   - 需要快速验证功能
#
# ⚠️  注意：正式发布时请使用 build_sugarloaf_release.sh
# ============================================================================

set -euo pipefail

# 动态获取项目根目录（脚本在 scripts/ 目录下）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIO_DIR="$ROOT/rio"
ETERM_DIR="$ROOT/ETerm"

echo "🚀 [开发模式] 快速编译 sugarloaf-ffi..."
echo "   使用 dev-fast profile (thin LTO + 并行编译)"
cd "$RIO_DIR"
cargo build --profile dev-fast -p sugarloaf-ffi

echo "📦 复制到 ETerm/ETerm/Libs/Sugarloaf/..."
# dev-fast profile 的产物在 target/dev-fast/ 目录
mkdir -p "$ETERM_DIR/ETerm/Libs/Sugarloaf"
cp "$RIO_DIR/target/dev-fast/libsugarloaf_ffi.a" "$ETERM_DIR/ETerm/Libs/Sugarloaf/libsugarloaf_ffi.a"
cp "$RIO_DIR/target/dev-fast/libsugarloaf_ffi.dylib" "$ETERM_DIR/ETerm/Libs/Sugarloaf/libsugarloaf_ffi.dylib" 2>/dev/null || true

echo "✅ 库文件已更新到 ETerm/ETerm/Libs/Sugarloaf/"
ls -lh "$ETERM_DIR/ETerm/Libs/Sugarloaf/libsugarloaf_ffi.a"
echo ""
echo "💡 提示：开发模式编译快 3-5 倍，性能损失 < 5%"
echo "   正式发布时请使用: ./scripts/build_sugarloaf_release.sh"
