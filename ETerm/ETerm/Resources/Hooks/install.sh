#!/bin/bash
#
# ETerm Claude Hook 安装脚本
# 将 ETerm hook 注册到全局 Claude settings.json
#

set -e

# 脚本目录（源文件位置）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_HOOK_SCRIPT="$SCRIPT_DIR/claude_hook.sh"

# 支持环境变量覆盖（与 Swift 代码一致）
VIMO_ROOT="${VIMO_HOME:-$HOME/.vimo}"
ETERM_ROOT="${ETERM_HOME:-$VIMO_ROOT/eterm}"

# 目标位置（用户目录）
TARGET_DIR="$ETERM_ROOT/scripts"
TARGET_HOOK_SCRIPT="$TARGET_DIR/claude_hook.sh"
TARGET_HOOK_DEFAULT="$TARGET_DIR/.claude_hook.sh.default"
SETTINGS_FILE="$HOME/.claude/settings.json"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo "🔧 ETerm Claude Hook 安装程序"
echo "================================"

# 检查源 hook 脚本是否存在
if [ ! -f "$SOURCE_HOOK_SCRIPT" ]; then
    echo -e "${RED}❌ Hook 源脚本不存在: $SOURCE_HOOK_SCRIPT${NC}"
    exit 1
fi

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ 需要安装 jq: brew install jq${NC}"
    exit 1
fi

# 创建目标目录
mkdir -p "$TARGET_DIR"

# 版本管理逻辑
SHOULD_COPY=true
if [ -f "$TARGET_HOOK_SCRIPT" ]; then
    # 目标脚本已存在，检查是否用户修改过
    if [ -f "$TARGET_HOOK_DEFAULT" ]; then
        # 对比当前脚本与 .default
        if diff -q "$TARGET_HOOK_SCRIPT" "$TARGET_HOOK_DEFAULT" > /dev/null 2>&1; then
            echo "📝 检测到脚本未被修改，自动更新"
            SHOULD_COPY=true
        else
            echo -e "${YELLOW}⚠️ 检测到脚本已被修改${NC}"
            echo "当前脚本: $TARGET_HOOK_SCRIPT"
            echo ""
            read -p "是否覆盖？(y/N): " choice
            case "$choice" in
                y|Y)
                    SHOULD_COPY=true
                    ;;
                *)
                    SHOULD_COPY=false
                    echo "跳过脚本更新"
                    ;;
            esac
        fi
    else
        # 没有 .default 文件，可能是旧版本，直接更新
        echo "📝 首次安装到用户目录"
        SHOULD_COPY=true
    fi
fi

# 复制脚本到用户目录
if [ "$SHOULD_COPY" = true ]; then
    cp "$SOURCE_HOOK_SCRIPT" "$TARGET_HOOK_SCRIPT"
    chmod +x "$TARGET_HOOK_SCRIPT"
    # 保存 .default 副本
    cp "$SOURCE_HOOK_SCRIPT" "$TARGET_HOOK_DEFAULT"
    echo -e "${GREEN}✅ 脚本已安装到: $TARGET_HOOK_SCRIPT${NC}"
fi

# 检查 settings.json 是否存在
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${YELLOW}⚠️ Claude settings.json 不存在，创建新文件${NC}"
    mkdir -p "$HOME/.claude"
    echo '{"hooks":{}}' > "$SETTINGS_FILE"
fi

# 备份原文件
BACKUP_FILE="$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS_FILE" "$BACKUP_FILE"
echo "📦 已备份原配置到: $BACKUP_FILE"

# 定义需要注册的 hook 类型
HOOK_TYPES=("SessionStart" "SessionEnd" "Stop" "Notification" "UserPromptSubmit" "PermissionRequest")

# 检查每个 hook 类型是否需要更新
NEEDS_UPDATE=false
for hook_type in "${HOOK_TYPES[@]}"; do
    # 检查该 hook 类型是否已包含我们的脚本（在全局 matcher 中）
    if ! jq -e --arg hook "$TARGET_HOOK_SCRIPT" --arg type "$hook_type" '
        .hooks[$type] // [] |
        map(select(.matcher == "" or .matcher == null)) |
        .[].hooks // [] |
        map(select(.command | contains($hook))) |
        length > 0
    ' "$SETTINGS_FILE" > /dev/null 2>&1; then
        NEEDS_UPDATE=true
        echo "📝 需要添加 $hook_type hook"
    fi
done

if [ "$NEEDS_UPDATE" = false ]; then
    echo -e "${GREEN}✅ 所有 hooks 已安装，无需更新${NC}"
    exit 0
fi

# 使用 jq 添加 hook（增量更新，只添加缺失的）
TMP_FILE=$(mktemp)

# 转义路径中的特殊字符
ESCAPED_HOOK_SCRIPT=$(printf '%s' "$TARGET_HOOK_SCRIPT" | sed 's/"/\\"/g')

jq --arg hook "$ESCAPED_HOOK_SCRIPT" '
# 确保 hooks 对象存在
.hooks //= {} |

# 辅助函数：确保 hook 类型有全局 matcher 并添加我们的 hook
def ensure_hook($type):
    # 获取当前 hook 数组
    (.hooks[$type] // []) as $arr |

    # 查找全局 matcher（matcher 为空或不存在）
    ($arr | to_entries | map(select(.value.matcher == "" or .value.matcher == null)) | .[0].key // null) as $globalIdx |

    # 构建新的 hook 命令
    ("bash \"" + $hook + "\"") as $cmd |

    # 检查是否已存在
    if $globalIdx != null then
        # 检查全局 matcher 中是否已有此 hook
        if ($arr[$globalIdx].hooks // [] | map(select(.command | contains($hook))) | length) > 0 then
            .
        else
            .hooks[$type][$globalIdx].hooks = (($arr[$globalIdx].hooks // []) + [{"type": "command", "command": $cmd}])
        end
    else
        # 没有全局 matcher，添加一个
        .hooks[$type] = ($arr + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}])
    end;

# 为所有 hook 类型添加
ensure_hook("SessionStart") |
ensure_hook("SessionEnd") |
ensure_hook("Stop") |
ensure_hook("Notification") |
ensure_hook("UserPromptSubmit") |
ensure_hook("PermissionRequest")
' "$SETTINGS_FILE" > "$TMP_FILE"

if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$SETTINGS_FILE"
    echo -e "${GREEN}✅ ETerm hook 安装成功！${NC}"
    echo ""
    echo "已添加到:"
    echo "  - SessionStart hook (会话开始)"
    echo "  - SessionEnd hook (会话结束)"
    echo "  - Stop hook (会话完成通知)"
    echo "  - Notification hook (各类通知)"
    echo "  - UserPromptSubmit hook (用户输入同步)"
    echo "  - PermissionRequest hook (远程权限审批)"
    echo ""
    echo "Hook 脚本位置: $TARGET_HOOK_SCRIPT"
else
    rm -f "$TMP_FILE"
    echo -e "${RED}❌ 安装失败${NC}"
    echo "已从备份恢复: $BACKUP_FILE"
    cp "$BACKUP_FILE" "$SETTINGS_FILE"
    exit 1
fi
