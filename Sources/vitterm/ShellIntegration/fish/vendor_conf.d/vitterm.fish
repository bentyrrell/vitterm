# vitterm fish integration (loaded via XDG_DATA_DIRS).
status is-interactive; or exit 0
set -q VITTERM_SHELL_INTEGRATION; or exit 0

function __vitterm_prompt --on-event fish_prompt
    printf '\e]133;A\a'
    printf '\e]7;file://%s%s\a' (prompt_hostname) (string escape --style=url -- $PWD)
end

function __vitterm_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end

function __vitterm_postexec --on-event fish_postexec
    printf '\e]133;D;%s\a' $status
end
