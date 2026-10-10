_aur_taw_completions() {
    local cur prev cmds repos config_file subcommand alias_name
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    subcommand="${COMP_WORDS[1]:-}"
    cmds='search add edit import discover deps remove uninstall list view log install check autocheck'
    config_file="${XDG_CONFIG_HOME:-$HOME/.config}/aur-taw/repos.txt"
    if [[ "$COMP_CWORD" -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$cmds --help --version" -- "$cur")
        return
    fi
    repos=''
    case "$subcommand" in
        install|edit|remove|uninstall|view|log|deps|dependencies)
            if [[ -r "$config_file" ]]; then
                while read -r alias_name _; do repos+="$alias_name "; done < "$config_file"
            fi ;;
    esac
    case "$subcommand" in
        install) mapfile -t COMPREPLY < <(compgen -W "--all --upgrade $repos" -- "$cur") ;;
        edit)
            [[ "$prev" != --url && "$prev" != --name && "$prev" != --package ]] || return
            mapfile -t COMPREPLY < <(compgen -W "$repos --name --url --package" -- "$cur") ;;
        remove|uninstall|view|log) mapfile -t COMPREPLY < <(compgen -W "$repos" -- "$cur") ;;
        deps|dependencies) mapfile -t COMPREPLY < <(compgen -W "$repos --all --tree" -- "$cur") ;;
        import) mapfile -t COMPREPLY < <(compgen -W '--all' -- "$cur") ;;
        check) mapfile -t COMPREPLY < <(compgen -W '--installed --quiet' -- "$cur") ;;
        autocheck) mapfile -t COMPREPLY < <(compgen -W 'enable disable status run' -- "$cur") ;;
    esac
}
complete -F _aur_taw_completions aur-taw
