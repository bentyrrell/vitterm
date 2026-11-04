# vitterm bash integration. Add to ~/.bashrc:
#   [[ "$TERM_PROGRAM" == vitterm && -n "$VITTERM_SHELL_INTEGRATION" ]] && source "$VITTERM_SHELL_INTEGRATION/bash/vitterm.bash"
[[ -n "$_VITTERM_INTEGRATED" ]] && return
_VITTERM_INTEGRATED=1

# Percent-encode everything except unreserved characters and '/'. Directory names can contain any
# byte (an archive or git checkout can create one with BEL or ESC in it), and anything left raw
# would end the OSC 7 sequence early and inject terminal commands on every prompt.
__vitterm_urlencode() {
    local LC_ALL=C s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9/._~-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    REPLY="$out"
}

__vitterm_prompt() {
    local ret=$?
    printf '\e]133;D;%s\a' "$ret"
    __vitterm_urlencode "$PWD"
    printf '\e]7;file://%s%s\a' "${HOSTNAME//[^a-zA-Z0-9.-]/}" "$REPLY"
    printf '\e]133;A\a'
}
PROMPT_COMMAND="__vitterm_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
