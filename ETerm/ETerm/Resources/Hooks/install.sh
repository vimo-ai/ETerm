#!/bin/bash
#
# ETerm Claude Hook 安装脚本
# 将 ETerm hook 注册到全局 Claude settings.json
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/claude_hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo "🔧 ETerm Claude Hook 安装程序"
echo "================================"

# 检查 hook 脚本是否存在
if [ ! -f "$HOOK_SCRIPT" ]; then
    echo -e "${RED}❌ Hook 脚本不存在: $HOOK_SCRIPT${NC}"
    exit 1
fi

# 确保 hook 脚本可执行
chmod +x "$HOOK_SCRIPT"

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ 需要安装 jq: brew install jq${NC}"
    exit 1
fi

# 检查 settings.json 是否存在
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${YELLOW}⚠️ Claude settings.json 不存在，创建新文件${NC}"
    mkdir -p "$HOME/.claude"
    echo '{"hooks":{}}' > "$SETTINGS_FILE"
fi

# 备份原文件
cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"
echo "📦 已备份原配置"

# 定义 ETerm hook 配置
ETERM_HOOK="{\"type\": \"command\", \"command\": \"bash $HOOK_SCRIPT\"}"

# 检查是否已安装
if grep -q "$HOOK_SCRIPT" "$SETTINGS_FILE" 2>/dev/null; then
    echo -e "${YELLOW}⚠️ ETerm hook 已安装，跳过${NC}"
    exit 0
fi

# 使用 jq 添加 hook
# 为 Stop 和 Notification 都添加 ETerm hook

TMP_FILE=$(mktemp)

jq --arg hook "$HOOK_SCRIPT" '
# 确保 hooks 对象存在
.hooks //= {} |

# 处理 Stop hooks
.hooks.Stop //= [{"matcher": "", "hooks": []}] |
.hooks.Stop[0].hooks += [{"type": "command", "command": ("bash " + $hook)}] |

# 处理 Notification hooks
.hooks.Notification //= [{"matcher": "", "hooks": []}] |
.hooks.Notification[0].hooks += [{"type": "command", "command": ("bash " + $hook)}]
' "$SETTINGS_FILE" > "$TMP_FILE"

if [ $? -eq 0 ]; then
    mv "$TMP_FILE" "$SETTINGS_FILE"
    echo -e "${GREEN}✅ ETerm hook 安装成功！${NC}"
    echo ""
    echo "已添加到:"
    echo "  - Stop hook"
    echo "  - Notification hook"
    echo ""
    echo "Hook 脚本位置: $HOOK_SCRIPT"
else
    rm -f "$TMP_FILE"
    echo -e "${RED}❌ 安装失败${NC}"
    exit 1
fi
