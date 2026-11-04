# vitterm shell integration bootstrap.
# vitterm points ZDOTDIR here so this file runs first. Restore the user's ZDOTDIR,
# source their .zshenv, then install the integration hooks for interactive shells.
if [[ -n "${VITTERM_ORIG_ZDOTDIR+X}" ]]; then
  builtin export ZDOTDIR="$VITTERM_ORIG_ZDOTDIR"
  builtin unset VITTERM_ORIG_ZDOTDIR
else
  builtin unset ZDOTDIR
fi

{
  builtin typeset _vitterm_file="${ZDOTDIR-$HOME}/.zshenv"
  [[ ! -r "$_vitterm_file" ]] || builtin source -- "$_vitterm_file"
} always {
  if [[ -o interactive && -n "$VITTERM_SHELL_INTEGRATION" ]]; then
    builtin source -- "$VITTERM_SHELL_INTEGRATION/zsh/vitterm-integration.zsh"
  fi
  builtin unset _vitterm_file
}
