# ETerm Shell Integration for Zsh
# This file is sourced automatically when ETERM_SHELL_INTEGRATION is set

# Bail out if disabled
[[ -n "$ETERM_NO_INTEGRATION" ]] && return

# Get the directory containing this script
ETERM_SHELL_DIR="${0:A:h}"

# === OSC 133: Shell state reporting ===
# Lets ETerm know when prompt appears, command starts, command finishes
source "$ETERM_SHELL_DIR/osc133.zsh"

# === Autosuggestions: Fish-like history suggestions ===
# Shows gray text completion based on history
source "$ETERM_SHELL_DIR/zsh-autosuggestions.zsh"

# Configure autosuggestions
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'           # Gray color
ZSH_AUTOSUGGEST_STRATEGY=(history completion)    # Default: history, then completion
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20               # Don't suggest for long inputs

# === AI-Powered Suggestions ===
# Enhances autosuggestions with AI-based candidate selection
# Only loads if Ollama is available and ETERM_SESSION_ID is set
source "$ETERM_SHELL_DIR/eterm-ai-strategy.zsh"

# Bind right arrow to accept suggestion
bindkey '^[[C' forward-char                      # Right arrow accepts char by char
bindkey '^[f' forward-word                       # Alt+F accepts word
bindkey '^E' end-of-line                         # Ctrl+E accepts full suggestion
