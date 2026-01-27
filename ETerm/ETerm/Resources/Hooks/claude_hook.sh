#!/bin/bash
#
# ETerm Claude Hook
# 支持 SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification 事件
#
# 架构：通知 vimo-agent，由其广播给所有订阅者（ETerm AICliKit, memex 等）
#
# 优雅降级：通知失败静默跳过，不影响后续 hooks
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
    echo "$(date) ⚠️ [Hook] jq not found - skipping notification" >> "$LOG_FILE"
    exit 0  # 优雅降级，不阻塞后续 hooks
fi

# 解析 JSON 字段
session_id=$(echo "$input" | jq -r '.session_id')
hook_event_name=$(echo "$input" | jq -r '.hook_event_name // "Stop"')
source=$(echo "$input" | jq -r '.source // "unknown"')
prompt=$(echo "$input" | jq -r '.prompt // ""')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# 读取环境变量
terminal_id="${ETERM_TERMINAL_ID}"

# vimo-agent socket 路径
agent_socket_path="${HOME}/.vimo/db/agent.sock"

# 记录日志
{
    echo "==================="
    echo "Triggered at: $(date)"
    echo "Event: $hook_event_name"
    echo "Source: $source"
    echo "Session ID: $session_id"
    echo "Terminal ID: $terminal_id"
    echo "Agent Socket: $agent_socket_path"
} >> "$LOG_FILE"

# ========================================
# 函数：通知 vimo-agent
# ========================================
notify_vimo_agent() {
    local hook_json="$1"

    if [ ! -S "$agent_socket_path" ]; then
        echo "  ⚠️ vimo-agent socket not found, skipping" >> "$LOG_FILE"
        return 0
    fi

    # 异步发送，不阻塞 Claude Code
    (echo "$hook_json" | nc -w 1 -U "$agent_socket_path") &
    echo "  ✅ vimo-agent notified" >> "$LOG_FILE"
}

# ========================================
# 构造 vimo-agent HookEvent JSON
# ========================================
build_agent_hook_event() {
    local event_type="$1"
    local extra_fields="$2"

    # 构造 context（ETerm 环境下带 terminal_id）
    local context="null"
    if [ -n "$terminal_id" ]; then
        context="{\"terminal_id\": $terminal_id}"
    fi

    # 基础字段（使用 jq 确保正确转义）
    local base_json=$(jq -cn \
        --arg type "HookEvent" \
        --arg event_type "$event_type" \
        --arg session_id "$session_id" \
        --arg transcript_path "$transcript_path" \
        --arg cwd "$cwd" \
        --argjson context "$context" \
        '{
            type: $type,
            event_type: $event_type,
            session_id: $session_id,
            transcript_path: (if $transcript_path == "" then null else $transcript_path end),
            cwd: (if $cwd == "" then null else $cwd end),
            context: $context
        }')

    # 合并额外字段
    if [ -n "$extra_fields" ]; then
        echo "$base_json" | jq -c ". + $extra_fields"
    else
        echo "$base_json"
    fi
}

# ========================================
# 事件处理
# ========================================
case "$hook_event_name" in
    "SessionStart")
        echo "📍 [SessionStart]" >> "$LOG_FILE"
        agent_json=$(build_agent_hook_event "SessionStart")
        notify_vimo_agent "$agent_json"
        ;;

    "UserPromptSubmit")
        echo "📍 [UserPromptSubmit] prompt=${#prompt} chars" >> "$LOG_FILE"
        escaped_prompt=$(echo "$prompt" | jq -Rs '.')
        extra_fields="{\"prompt\": $escaped_prompt}"
        agent_json=$(build_agent_hook_event "UserPromptSubmit" "$extra_fields")
        notify_vimo_agent "$agent_json"
        ;;

    "SessionEnd")
        echo "📍 [SessionEnd]" >> "$LOG_FILE"
        agent_json=$(build_agent_hook_event "SessionEnd")
        notify_vimo_agent "$agent_json"
        ;;

    "Stop")
        echo "📍 [Stop]" >> "$LOG_FILE"
        agent_json=$(build_agent_hook_event "Stop")
        notify_vimo_agent "$agent_json"
        ;;

    "PermissionRequest")
        tool_name=$(echo "$input" | jq -r '.tool_name // ""')
        tool_input=$(echo "$input" | jq -c '.tool_input // {}')
        tool_use_id=$(echo "$input" | jq -r '.tool_use_id // ""')
        echo "📍 [PermissionRequest] tool=$tool_name, tool_use_id=$tool_use_id" >> "$LOG_FILE"
        escaped_tool_name=$(echo "$tool_name" | jq -Rs '.')
        escaped_tool_use_id=$(echo "$tool_use_id" | jq -Rs '.')
        extra_fields="{\"tool_name\": $escaped_tool_name, \"tool_input\": $tool_input, \"tool_use_id\": $escaped_tool_use_id}"
        agent_json=$(build_agent_hook_event "PermissionRequest" "$extra_fields")
        notify_vimo_agent "$agent_json"
        ;;

    "Notification")
        notification_type=$(echo "$input" | jq -r '.notification_type // "unknown"')

        # 过滤掉不需要的通知类型
        if [ "$notification_type" = "idle_prompt" ]; then
            echo "⏭️ Skipping idle_prompt (60s idle, no action needed)" >> "$LOG_FILE"
            exit 0
        fi
        if [ "$notification_type" = "permission_prompt" ]; then
            echo "⏭️ Skipping permission_prompt (handled by PermissionRequest hook)" >> "$LOG_FILE"
            exit 0
        fi

        message=$(echo "$input" | jq -r '.message // ""')
        echo "📍 [Notification] type=$notification_type" >> "$LOG_FILE"
        escaped_notification_type=$(echo "$notification_type" | jq -Rs '.')
        escaped_message=$(echo "$message" | jq -Rs '.')
        extra_fields="{\"notification_type\": $escaped_notification_type, \"message\": $escaped_message}"
        agent_json=$(build_agent_hook_event "Notification" "$extra_fields")
        notify_vimo_agent "$agent_json"
        ;;

    *)
        echo "📍 [Unknown] event=$hook_event_name" >> "$LOG_FILE"
        agent_json=$(build_agent_hook_event "$hook_event_name")
        notify_vimo_agent "$agent_json"
        ;;
esac

exit 0
