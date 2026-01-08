#!/bin/bash
#
# ETerm Claude Hook
# 支持 SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification 事件
# 通过 Unix Socket 通知 ETerm，建立 session 映射，控制 Tab 装饰
# 优雅降级：非 ETerm 环境下静默跳过，不影响后续 hooks
#

# 确保日志目录存在（权限 0700，防止敏感信息泄露给其他用户）
mkdir -p /tmp/eterm
chmod 700 /tmp/eterm 2>/dev/null || true

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
# 提取 transcript_path 和 cwd（用于 MemexKit 索引）
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# 读取环境变量
terminal_id="${ETERM_TERMINAL_ID}"
socket_dir="${ETERM_SOCKET_DIR}"

# 构造 socket 路径（新路径格式）
socket_path="${socket_dir}/claude.sock"

# 记录日志（包含完整 JSON 便于调试）
{
    echo "==================="
    echo "Triggered at: $(date)"
    echo "Event: $hook_event_name"
    echo "Source: $source"
    echo "Session ID: $session_id"
    echo "Terminal ID: $terminal_id"
    echo "Socket Dir: $socket_dir"
    echo "Socket Path: $socket_path"
    echo "Raw JSON:"
    echo "$input" | jq '.' 2>/dev/null || echo "$input"
} >> "$LOG_FILE"

# 检查必要的环境变量
if [ -z "$terminal_id" ]; then
    echo "⚠️ Not in ETerm environment (ETERM_TERMINAL_ID not set) - skipping" >> "$LOG_FILE"
    exit 0  # 优雅降级
fi

if [ -z "$socket_dir" ]; then
    echo "⚠️ Not in ETerm environment (ETERM_SOCKET_DIR not set) - skipping" >> "$LOG_FILE"
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
        (echo "{\"event_type\": \"$event_type\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"prompt\": $escaped_prompt, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}" | nc -w 2 -U "$socket_path") &
        echo "✅ [$event_type] Notification sent async with prompt (${#prompt} chars)" >> "$LOG_FILE"
        exit 0
        ;;
    "SessionEnd")
        event_type="session_end"
        ;;
    "Stop")
        event_type="stop"
        ;;
    "PermissionRequest")
        # 权限请求事件（主要入口）- 直接提供 tool_name + tool_input
        tool_name=$(echo "$input" | jq -r '.tool_name // ""')
        tool_input=$(echo "$input" | jq -c '.tool_input // {}')
        tool_use_id=$(echo "$input" | jq -r '.tool_use_id // ""')

        # JSON 转义所有字符串字段（防止路径中含引号/反斜杠导致 JSON 无效）
        escaped_session_id=$(echo "$session_id" | jq -Rs '.')
        escaped_tool_name=$(echo "$tool_name" | jq -Rs '.')
        escaped_tool_use_id=$(echo "$tool_use_id" | jq -Rs '.')
        escaped_transcript_path=$(echo "$transcript_path" | jq -Rs '.')
        escaped_cwd=$(echo "$cwd" | jq -Rs '.')

        # 异步发送，不阻塞（不返回决策，让 Claude Code 显示正常 UI）
        (echo "{\"event_type\": \"permission_request\", \"session_id\": $escaped_session_id, \"terminal_id\": $terminal_id, \"tool_name\": $escaped_tool_name, \"tool_input\": $tool_input, \"tool_use_id\": $escaped_tool_use_id, \"transcript_path\": $escaped_transcript_path, \"cwd\": $escaped_cwd}" | nc -w 2 -U "$socket_path") &
        echo "✅ [permission_request] tool=$tool_name, sent async" >> "$LOG_FILE"
        exit 0
        ;;
    "Notification")
        # 过滤掉 idle_prompt（60秒空闲提醒，不需要用户操作）
        # 过滤掉 permission_prompt（由 PermissionRequest hook 处理，避免重复）
        notification_type=$(echo "$input" | jq -r '.notification_type // "unknown"')
        if [ "$notification_type" = "idle_prompt" ]; then
            echo "⏭️ Skipping idle_prompt (60s idle, no action needed)" >> "$LOG_FILE"
            exit 0
        fi
        if [ "$notification_type" = "permission_prompt" ]; then
            echo "⏭️ Skipping permission_prompt (handled by PermissionRequest hook)" >> "$LOG_FILE"
            exit 0
        fi

        # 提取 message 字段（用于其他通知场景）
        message=$(echo "$input" | jq -r '.message // ""')
        escaped_message=$(echo "$message" | jq -Rs '.')

        # 异步发送，包含完整通知信息
        (echo "{\"event_type\": \"notification\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"notification_type\": \"$notification_type\", \"message\": $escaped_message, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}" | nc -w 2 -U "$socket_path") &
        echo "✅ [notification] type=$notification_type, sent async" >> "$LOG_FILE"
        exit 0
        ;;
    *)
        event_type="unknown"
        ;;
esac

# 异步发送 JSON 到 ETerm Socket Server，不阻塞 Claude Code
(echo "{\"event_type\": \"$event_type\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}" | nc -w 2 -U "$socket_path") &
echo "✅ [$event_type] Notification sent async" >> "$LOG_FILE"
