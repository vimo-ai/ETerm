# ETerm AI Strategy for zsh-autosuggestions
# Adds AI-powered suggestion selection using Ollama
#
# This file is sourced after zsh-autosuggestions.zsh
# It adds an 'ai' strategy that uses ETerm's AI service to
# select the best candidate from history matches.

# Bail out if not in ETerm or disabled
[[ -z "$ETERM_SESSION_ID" ]] && return
[[ -n "$ETERM_AI_DISABLED" ]] && return

# Load required modules
zmodload zsh/net/socket 2>/dev/null || return
zmodload zsh/zselect 2>/dev/null || return
zmodload zsh/datetime 2>/dev/null || return

# Per-session request ID tracking
typeset -gA _ETERM_AI_LAST_REQ_IDS

# Unhealthy backoff timestamp
typeset -g _ETERM_AI_UNHEALTHY_UNTIL=0

# Socket path
: ${ETERM_AI_SOCK:="$HOME/.eterm/tmp/ai.sock"}

# JSON escape function
_eterm_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"      # \ -> \\
    str="${str//\"/\\\"}"      # " -> \"
    str="${str//$'\n'/\\n}"    # newline -> \n
    str="${str//$'\t'/\\t}"    # tab -> \t
    str="${str//$'\r'/\\r}"    # cr -> \r
    print -r -- "$str"
}

# AI suggestion strategy
# This strategy uses ETerm's AI service to select the best candidate
# from history matches, considering terminal context.
_zsh_autosuggest_strategy_ai() {
    emulate -L zsh
    setopt EXTENDED_GLOB

    local input="$1"

    # Skip if input is too short
    (( $#input < 2 )) && return

    # Skip if in unhealthy period
    (( EPOCHSECONDS < _ETERM_AI_UNHEALTHY_UNTIL )) && return

    # Get candidates from history (same logic as history strategy)
    local prefix="${input//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"
    local pattern="$prefix*"
    local -a candidates

    # Use (R) subscript flag to get ALL matching values (like history strategy's (r))
    # Then dedupe and take first 5
    local -a all_matches
    all_matches=(${(u)history[(R)$pattern]})
    candidates=(${all_matches[1,5]})

    # Need at least 2 candidates for AI to be useful
    (( ${#candidates} <= 1 )) && return

    # Generate unique request ID for this session
    local req_id="req-${RANDOM}-${EPOCHREALTIME}"
    _ETERM_AI_LAST_REQ_IDS[$ETERM_SESSION_ID]="$req_id"

    # Build JSON request
    local escaped_input=$(_eterm_json_escape "$input")
    local json_candidates=""
    local c
    for c in "${candidates[@]}"; do
        json_candidates+="\"$(_eterm_json_escape "$c")\","
    done
    json_candidates="[${json_candidates%,}]"

    local request="{\"id\":\"$req_id\",\"session_id\":\"$ETERM_SESSION_ID\",\"input\":\"$escaped_input\",\"candidates\":$json_candidates}"

    # Non-blocking socket connection
    local fd
    if ! zsocket "$ETERM_AI_SOCK" 2>/dev/null; then
        # Socket connection failed, mark unhealthy for 10s
        _ETERM_AI_UNHEALTHY_UNTIL=$((EPOCHSECONDS + 10))
        return
    fi
    fd=$REPLY

    # Send request (with newline as message boundary)
    print -u $fd "$request"

    # Wait for response (150ms timeout, zselect uses centiseconds)
    zselect -r $fd -t 15
    if (( $? != 0 )); then
        exec {fd}<&-
        return
    fi

    # Read response (with timeout)
    local response=""
    if ! read -t 0.1 -u $fd response; then
        exec {fd}<&-
        return
    fi
    exec {fd}<&-

    # Check if this is still the current request for this session
    [[ "${_ETERM_AI_LAST_REQ_IDS[$ETERM_SESSION_ID]}" != "$req_id" ]] && return

    # Parse response using regex (robust JSON parsing)
    local resp_status index

    # Extract status
    if [[ "$response" =~ '"status"[[:space:]]*:[[:space:]]*"([^"]*)"' ]]; then
        resp_status="${match[1]}"
    else
        return
    fi

    # Handle unhealthy status
    if [[ "$resp_status" == "unhealthy" ]]; then
        _ETERM_AI_UNHEALTHY_UNTIL=$((EPOCHSECONDS + 30))
        return
    fi

    # Skip if not ok
    [[ "$resp_status" != "ok" ]] && return

    # Extract index (validate it's a number)
    if [[ "$response" =~ '"index"[[:space:]]*:[[:space:]]*([0-9]+)' ]]; then
        index="${match[1]}"
    else
        return
    fi

    # Validate index range and set suggestion
    # Note: zsh arrays are 1-indexed
    if (( index >= 0 && index < ${#candidates} )); then
        typeset -g suggestion="${candidates[$((index + 1))]}"
    fi
}

# Configure autosuggestions to use AI strategy first
# Falls back to history if AI is unavailable or times out
if [[ -n "$ZSH_AUTOSUGGEST_STRATEGY" ]]; then
    # Insert 'ai' at the beginning if not already present
    if [[ ! " ${ZSH_AUTOSUGGEST_STRATEGY[*]} " =~ " ai " ]]; then
        ZSH_AUTOSUGGEST_STRATEGY=(ai "${ZSH_AUTOSUGGEST_STRATEGY[@]}")
    fi
else
    ZSH_AUTOSUGGEST_STRATEGY=(ai history completion)
fi
