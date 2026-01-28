#!/bin/bash
#
# ETerm Claude Hook
# 支持 SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification 事件
#
# 双写架构：
# 1. 总是通知 vimo-agent（触发即时 Collection + 广播事件）
# 2. 如果在 ETerm 环境，额外通知 ETerm Socket（Tab 装饰等 UI 功能）
#
# 优雅降级：任何通知失败都静默跳过，不影响后续 hooks
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
socket_dir="${ETERM_SOCKET_DIR}"

# 构造 socket 路径
eterm_socket_path="${socket_dir}/claude.sock"
agent_socket_path="${HOME}/.vimo/agent.sock"

# 记录日志
{
    echo "==================="
    echo "Triggered at: $(date)"
    echo "Event: $hook_event_name"
    echo "Source: $source"
    echo "Session ID: $session_id"
    echo "Terminal ID: $terminal_id"
    echo "Agent Socket: $agent_socket_path"
    echo "ETerm Socket: $eterm_socket_path"
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
# 函数：通知 ETerm Socket
# ========================================
notify_eterm() {
    local eterm_json="$1"

    # 检查是否在 ETerm 环境
    if [ -z "$terminal_id" ] || [ -z "$socket_dir" ]; then
        echo "  ℹ️ Not in ETerm environment, skipping ETerm notification" >> "$LOG_FILE"
        return 0
    fi

    if [ ! -S "$eterm_socket_path" ]; then
        echo "  ⚠️ ETerm socket not found: $eterm_socket_path" >> "$LOG_FILE"
        return 0
    fi

    # 异步发送，不阻塞 Claude Code
    (echo "$eterm_json" | nc -w 2 -U "$eterm_socket_path") &
    echo "  ✅ ETerm notified" >> "$LOG_FILE"
}

# ========================================
# 构造 vimo-agent HookEvent JSON
# ========================================
build_agent_hook_event() {
    local event_type="$1"
    local extra_fields="$2"

    # 基础字段（使用 jq 确保正确转义）
    local base_json=$(jq -cn \
        --arg type "HookEvent" \
        --arg event_type "$event_type" \
        --arg session_id "$session_id" \
        --arg transcript_path "$transcript_path" \
        --arg cwd "$cwd" \
        '{
            type: $type,
            event_type: $event_type,
            session_id: $session_id,
            transcript_path: (if $transcript_path == "" then null else $transcript_path end),
            cwd: (if $cwd == "" then null else $cwd end)
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

        # 通知 vimo-agent
        agent_json=$(build_agent_hook_event "SessionStart")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"session_start\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;

    "UserPromptSubmit")
        echo "📍 [UserPromptSubmit] prompt=${#prompt} chars" >> "$LOG_FILE"

        # 通知 vimo-agent（包含 prompt）
        escaped_prompt=$(echo "$prompt" | jq -Rs '.')
        extra_fields="{\"prompt\": $escaped_prompt}"
        agent_json=$(build_agent_hook_event "UserPromptSubmit" "$extra_fields")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"user_prompt_submit\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"prompt\": $escaped_prompt, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;

    "SessionEnd")
        echo "📍 [SessionEnd]" >> "$LOG_FILE"

        # 通知 vimo-agent
        agent_json=$(build_agent_hook_event "SessionEnd")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"session_end\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;

    "Stop")
        echo "📍 [Stop]" >> "$LOG_FILE"

        # 通知 vimo-agent
        agent_json=$(build_agent_hook_event "Stop")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"stop\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;

    "PermissionRequest")
        tool_name=$(echo "$input" | jq -r '.tool_name // ""')
        tool_input=$(echo "$input" | jq -c '.tool_input // {}')
        tool_use_id=$(echo "$input" | jq -r '.tool_use_id // ""')
        echo "📍 [PermissionRequest] tool=$tool_name, tool_use_id=$tool_use_id" >> "$LOG_FILE"

        # 通知 vimo-agent（包含 tool 信息）
        escaped_tool_name=$(echo "$tool_name" | jq -Rs '.')
        escaped_tool_use_id=$(echo "$tool_use_id" | jq -Rs '.')
        extra_fields="{\"tool_name\": $escaped_tool_name, \"tool_input\": $tool_input, \"tool_use_id\": $escaped_tool_use_id}"
        agent_json=$(build_agent_hook_event "PermissionRequest" "$extra_fields")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        escaped_session_id=$(echo "$session_id" | jq -Rs '.')
        escaped_transcript_path=$(echo "$transcript_path" | jq -Rs '.')
        escaped_cwd=$(echo "$cwd" | jq -Rs '.')
        eterm_json="{\"event_type\": \"permission_request\", \"session_id\": $escaped_session_id, \"terminal_id\": $terminal_id, \"tool_name\": $escaped_tool_name, \"tool_input\": $tool_input, \"tool_use_id\": $escaped_tool_use_id, \"transcript_path\": $escaped_transcript_path, \"cwd\": $escaped_cwd}"
        notify_eterm "$eterm_json"
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

        # 通知 vimo-agent（包含通知信息）
        escaped_notification_type=$(echo "$notification_type" | jq -Rs '.')
        escaped_message=$(echo "$message" | jq -Rs '.')
        extra_fields="{\"notification_type\": $escaped_notification_type, \"message\": $escaped_message}"
        agent_json=$(build_agent_hook_event "Notification" "$extra_fields")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"notification\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"notification_type\": \"$notification_type\", \"message\": $escaped_message, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;

    *)
        echo "📍 [Unknown] event=$hook_event_name" >> "$LOG_FILE"

        # 通知 vimo-agent（未知事件也发送，让 agent 决定如何处理）
        agent_json=$(build_agent_hook_event "$hook_event_name")
        notify_vimo_agent "$agent_json"

        # 通知 ETerm
        eterm_json="{\"event_type\": \"unknown\", \"session_id\": \"$session_id\", \"terminal_id\": $terminal_id, \"transcript_path\": \"$transcript_path\", \"cwd\": \"$cwd\"}"
        notify_eterm "$eterm_json"
        ;;
esac

exit 0
