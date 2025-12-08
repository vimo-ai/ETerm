# ETerm Zsh Wrapper
# This file is loaded when ZDOTDIR points to ETerm's shell directory
# It sources the user's original .zshrc and then loads ETerm integration

# Restore original ZDOTDIR for any nested shells
if [[ -n "$ETERM_ORIGINAL_ZDOTDIR" ]]; then
    export ZDOTDIR="$ETERM_ORIGINAL_ZDOTDIR"
else
    unset ZDOTDIR
fi

# Source user's original .zshrc
_eterm_user_zshrc="${ZDOTDIR:-$HOME}/.zshrc"
if [[ -f "$_eterm_user_zshrc" ]]; then
    source "$_eterm_user_zshrc"
fi
unset _eterm_user_zshrc

# Load ETerm shell integration (after user config to avoid conflicts)
if [[ -n "$ETERM_SHELL_DIR" && -f "$ETERM_SHELL_DIR/integration.zsh" ]]; then
    source "$ETERM_SHELL_DIR/integration.zsh"
fi
