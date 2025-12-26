#!/bin/bash
# package_builtin_plugins.sh
#
# Xcode Build Phase 脚本
# 将内置插件构建并复制到 app bundle
#
# 在 Xcode 中添加:
# 1. ETerm target → Build Phases → + → New Run Script Phase
# 2. 粘贴: "${SRCROOT}/Scripts/package_builtin_plugins.sh"
# 3. 取消勾选 "Based on dependency analysis"

set -euo pipefail

# 注释掉配置判断，Debug 和 Release 都打包插件
# if [ "${CONFIGURATION}" != "Release" ]; then
#     echo "Skipping plugin packaging for ${CONFIGURATION} build"
#     exit 0
# fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGINS_DIR="${SCRIPT_DIR}/../../Plugins"

# 输出目录: app bundle 内的 Resources/BuiltinPlugins
OUTPUT_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/BuiltinPlugins"

echo "=== Packaging Builtin Plugins ==="
echo "Configuration: ${CONFIGURATION}"
echo "Output: ${OUTPUT_DIR}"

# 创建输出目录
mkdir -p "${OUTPUT_DIR}"

# 调用插件构建脚本
export BUNDLE_OUTPUT_DIR="${OUTPUT_DIR}"
export CONFIGURATION="${CONFIGURATION}"

"${SCRIPT_DIR}/build_all_plugins.sh" "${OUTPUT_DIR}"

echo "=== Builtin Plugins Packaged ==="
