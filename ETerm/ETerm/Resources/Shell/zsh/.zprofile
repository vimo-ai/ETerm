# ETerm Zsh Profile Wrapper
# This ensures user's .zprofile is loaded for PATH setup (homebrew, etc.)

# Source user's original .zprofile
_eterm_user_zprofile="${ETERM_ORIGINAL_ZDOTDIR:-$HOME}/.zprofile"
if [[ -f "$_eterm_user_zprofile" ]]; then
    source "$_eterm_user_zprofile"
fi
unset _eterm_user_zprofile
