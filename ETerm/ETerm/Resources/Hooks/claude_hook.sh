#!/bin/bash
#
# ETerm Claude Hook
# 支持 SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification 事件
# 通过 Unix Socket 通知 ETerm，建立 session 映射，控制 Tab 装饰
# 优雅降级：非 ETerm 环境下静默跳过，不影响后续 hooks
#

# 确保日志目录存在
mkdir -p /tmp/eterm

# 日志文件（自动轮转，保留最近 100 条）
LOG_FILE="/tmp/eterm/claude-hook.log"
if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 500 ]; then
    tail -100 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# 读取 stdin（Claude 传递的 JSON 数据）
input=$(cat)

# 检查 jq 是否可用
if ! command -v jq &> /dev/null; then
    echo "⚠️ [Hook] jq not found - skipping ETerm notification" >> "$LOG_FILE"
    exit 0  # 优雅降级，不阻塞后续 hooks
fi

# 解析 JSON 字段
session_id=$(echo "$input" | jq -r '.session_id')
hook_event_name=$(echo "$input" | jq -r '.hook_event_name // "Stop"')
source=$(echo "$input" | jq -r '.source // "unknown"')
# 提取 prompt（用于生成智能标题）
prompt=$(echo "$input" | jq -r '.prompt // ""')

# 读取环境变量
terminal_id="${ETERM_TERMINAL_ID}"
socket_path="${ETERM_SOCKET_PATH}"

# 记录日志（包含完整 JSON 便于调试）
{
    echo "==================="
    echo "Triggered at: $(date)"
    echo "Event: $hook_event_name"
    echo "Source: $source"
    echo "Session ID: $session_id"
    echo "Terminal ID: $terminal_id"
    echo "Socket Path: $socket_path"
    echo "Raw JSON:"
    echo "$input" | jq '.' 2>/dev/null || echo "$input"
} >> "$LOG_FILE"

# 检查必要的环境变量
if [ -z "$terminal_id" ]; then
    echo "⚠️ Not in ETerm environment (ETERM_TERMINAL_ID not set) - skipping" >> "$LOG_FILE"
    exit 0  # 优雅降级
fi

if [ -z "$socket_path" ]; then
    echo "⚠️ Not in ETerm environment (ETERM_SOCKET_PATH not set) - skipping" >> "$LOG_FILE"
    exit 0  # 优雅降级
fi

# 检查 socket 文件是否存在
if [ ! -S "$socket_path" ]; then
    echo "⚠️ Socket file not found: $socket_path - skipping" >> "$LOG_FILE"
    exit 0  # 优雅降级
fi

# 事件类型映射
case "$hook_event_name" in
    "SessionStart")
        event_type="session_start"
        ;;
    "UserPromptSubmit")
        event_type="user_prompt_submit"
        # UserPromptSubmit 事件包含 prompt，需要特殊处理
        # 转义 prompt 中的特殊字符（双引号、反斜杠、换行）
        escaped_prompt=$(echo "$prompt" | jq -Rs '.')
        # 异步发送，不阻塞 Claude Code
        (echo "{\"event_type\": \"$event_type\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"prompt\": $escaped_prompt}" | nc -w 2 -U "$socket_path") &
        echo "✅ [$event_type] Notification sent async with prompt (${#prompt} chars)" >> "$LOG_FILE"
        exit 0
        ;;
    "SessionEnd")
        event_type="session_end"
        ;;
    "Stop")
        event_type="stop"
        ;;
    "Notification")
        # 过滤掉 idle_prompt（60秒空闲提醒，不需要用户操作）
        # 保留：permission_prompt, elicitation_dialog 等需要用户操作的
        notification_type=$(echo "$input" | jq -r '.notification_type // "unknown"')
        if [ "$notification_type" = "idle_prompt" ]; then
            echo "⏭️ Skipping idle_prompt (60s idle, no action needed)" >> "$LOG_FILE"
            exit 0
        fi
        event_type="notification"
        ;;
    *)
        event_type="unknown"
        ;;
esac

# 异步发送 JSON 到 ETerm Socket Server，不阻塞 Claude Code
(echo "{\"event_type\": \"$event_type\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id}" | nc -w 2 -U "$socket_path") &
echo "✅ [$event_type] Notification sent async" >> "$LOG_FILE"
