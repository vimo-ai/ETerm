# ETerm OSC 133 Shell Integration
# Marks shell state transitions for the terminal
#
# OSC 133;A - Prompt start (shell ready for input)
# OSC 133;B - Command start (user typing)
# OSC 133;C;command - Command execute (user pressed enter) with command content
# OSC 133;D;exitcode - Command finished

# Don't load if not in ETerm
[[ -z "$ETERM_SHELL_INTEGRATION" ]] && return

# Escape sequences
_eterm_osc133_prompt_start=$'\e]133;A\a'
_eterm_osc133_command_start=$'\e]133;B\a'
_eterm_osc133_command_execute=$'\e]133;C\a'
_eterm_osc133_command_finished=$'\e]133;D;%?\a'

# Mark prompt start
_eterm_precmd() {
    local ret=$?
    # Report previous command exit status (if any command was run)
    if [[ -n "$_eterm_command_started" ]]; then
        print -Pn "\e]133;D;${ret}\a"
        unset _eterm_command_started
    fi
    # Mark prompt start
    print -Pn "$_eterm_osc133_prompt_start"
}

# Mark command execution
_eterm_preexec() {
    _eterm_command_started=1
    local cmd="${1//;/\\;}"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -n "$branch" ]]; then
        branch="${branch//;/\\;}"
        print -Pn "\e]133;C;${cmd};${branch}\a"
    else
        print -Pn "\e]133;C;${cmd}\a"
    fi
}

# Install hooks
autoload -Uz add-zsh-hook
add-zsh-hook precmd _eterm_precmd
add-zsh-hook preexec _eterm_preexec

# Mark initial prompt
print -Pn "$_eterm_osc133_prompt_start"
