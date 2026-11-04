# vitterm zsh integration: prompt marks (OSC 133), working directory (OSC 7) and titles.
[[ -n "$_VITTERM_INTEGRATED" ]] && return
typeset -g _VITTERM_INTEGRATED=1
builtin autoload -Uz add-zsh-hook

_vitterm_urlencode() {
  # Percent-encode everything except unreserved characters and '/'.
  builtin local LC_ALL=C str="$1" out="" c i
  for (( i = 1; i <= ${#str}; i++ )); do
    c="${str[i]}"
    case "$c" in
      [a-zA-Z0-9/._~-]) out+="$c" ;;
      *) out+=$(builtin printf '%%%02X' "'$c") ;;
    esac
  done
  REPLY="$out"
}

_vitterm_precmd() {
  builtin local ret=$?
  if [[ -n "$_vitterm_cmd_running" ]]; then
    builtin printf '\e]133;D;%s\a' "$ret"
    _vitterm_cmd_running=
  fi
  _vitterm_urlencode "$PWD"
  builtin printf '\e]7;file://%s%s\a' "${HOST}" "$REPLY"
  builtin print -Pn '\e]2;%~\a'
  builtin printf '\e]133;A\a'
}

_vitterm_preexec() {
  _vitterm_cmd_running=1
  builtin printf '\e]133;C\a'
  builtin printf '\e]2;%s\a' "${1//[[:cntrl:]]/}"
}

add-zsh-hook precmd _vitterm_precmd
add-zsh-hook preexec _vitterm_preexec
