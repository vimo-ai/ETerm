#!/usr/bin/env bash
# ============================================================================
# 正式发布时使用的 Sugarloaf 完整优化编译脚本
# ============================================================================
# 用途：正式发布前编译 sugarloaf-ffi 库（完整优化）
# 特点：使用 release profile，启用 Full LTO + 单编译单元
# 性能：二进制性能最优，体积最小
#
# 使用场景：
#   - 准备正式发布版本
#   - 需要最优性能和最小体积
#   - 性能测试和 benchmark
#
# ⚠️  注意：
#   - 编译时间较长（~1 分钟），适合发布前使用
#   - 日常开发请使用 update_sugarloaf_dev.sh
# ============================================================================

set -euo pipefail

# 动态获取项目根目录（脚本在 scripts/ 目录下）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIO_DIR="$ROOT/rio"
ETERM_DIR="$ROOT/ETerm"

echo "🏗️  [发布模式] 完整优化编译 sugarloaf-ffi..."
echo "   使用 release profile (full LTO + 最大优化)"
echo "   ⏱️  预计耗时: ~1 分钟"
cd "$RIO_DIR"
cargo build --release -p sugarloaf-ffi

echo "📦 复制到 ETerm/ETerm/Libs/Sugarloaf/..."
mkdir -p "$ETERM_DIR/ETerm/Libs/Sugarloaf"
cp "$RIO_DIR/target/release/libsugarloaf_ffi.a" "$ETERM_DIR/ETerm/Libs/Sugarloaf/libsugarloaf_ffi.a"

echo "✅ 库文件已更新到 ETerm/ETerm/Libs/Sugarloaf/"
ls -lh "$ETERM_DIR/ETerm/Libs/Sugarloaf/libsugarloaf_ffi.a"
echo ""
echo "🎯 发布模式编译完成："
echo "   - Full LTO 优化"
echo "   - 最小二进制体积"
echo "   - 最优运行性能"
echo ""
echo "💡 日常开发时使用: ./scripts/update_sugarloaf_dev.sh (快 3-5 倍)"
