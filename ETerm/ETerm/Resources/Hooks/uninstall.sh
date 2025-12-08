#!/bin/bash
#
# ETerm Claude Hook 卸载脚本
# 从全局 Claude settings.json 移除 ETerm hook
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/claude_hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "🗑️  ETerm Claude Hook 卸载程序"
echo "================================"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ 需要安装 jq: brew install jq${NC}"
    exit 1
fi

# 检查 settings.json 是否存在
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${YELLOW}⚠️ Claude settings.json 不存在${NC}"
    exit 0
fi

# 检查是否已安装
if ! grep -q "$HOOK_SCRIPT" "$SETTINGS_FILE" 2>/dev/null; then
    echo -e "${YELLOW}⚠️ ETerm hook 未安装，无需卸载${NC}"
    exit 0
fi

# 备份原文件
cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"
echo "📦 已备份原配置"

# 使用 jq 移除 hook
TMP_FILE=$(mktemp)

jq --arg hook "$HOOK_SCRIPT" '
# 从 Stop hooks 移除
if .hooks.Stop then
    .hooks.Stop[0].hooks = [.hooks.Stop[0].hooks[] | select(.command != ("bash " + $hook))]
else . end |

# 从 Notification hooks 移除
if .hooks.Notification then
    .hooks.Notification[0].hooks = [.hooks.Notification[0].hooks[] | select(.command != ("bash " + $hook))]
else . end
' "$SETTINGS_FILE" > "$TMP_FILE"

if [ $? -eq 0 ]; then
    mv "$TMP_FILE" "$SETTINGS_FILE"
    echo -e "${GREEN}✅ ETerm hook 已卸载${NC}"
else
    rm -f "$TMP_FILE"
    echo -e "${RED}❌ 卸载失败${NC}"
    exit 1
fi
