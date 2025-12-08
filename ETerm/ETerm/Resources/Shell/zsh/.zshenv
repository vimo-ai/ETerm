# ETerm Zsh Environment
# This ensures user's .zshenv is also loaded

# Source user's original .zshenv
_eterm_user_zshenv="${ETERM_ORIGINAL_ZDOTDIR:-$HOME}/.zshenv"
if [[ -f "$_eterm_user_zshenv" ]]; then
    source "$_eterm_user_zshenv"
fi
unset _eterm_user_zshenv
