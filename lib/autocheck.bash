#!/bin/bash

_autocheck_unit_quote() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '%s' "$value"
}

_autocheck_service() {
    local executable config_home cache_home
    executable=$(_autocheck_unit_quote "$SCRIPT_PATH") || return 1
    executable="${executable//\$/\$\$}"
    config_home=$(_autocheck_unit_quote "${XDG_CONFIG_HOME:-$HOME/.config}") || return 1
    cache_home=$(_autocheck_unit_quote "${XDG_CACHE_HOME:-$HOME/.cache}") || return 1
    cat <<EOF
[Unit]
Description=Refresh available versions of installed aur-taw packages

[Service]
Type=oneshot
ExecStart=/usr/bin/bash "$executable" autocheck run
Environment="XDG_CONFIG_HOME=$config_home"
Environment="XDG_CACHE_HOME=$cache_home"
TimeoutStartSec=5min
Nice=10
NoNewPrivileges=true
EOF
}

_autocheck_timer() {
    cat <<'EOF'
[Unit]
Description=Check installed aur-taw packages every six hours

[Timer]
OnStartupSec=5min
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=15min
Persistent=true
Unit=aur-taw-autocheck.service

[Install]
WantedBy=timers.target
EOF
}

_autocheck_run() (
    local log_file result=0
    mkdir -p -- "$CACHE_DIR" || return 1
    exec {autocheck_fd}>"$CACHE_DIR/autocheck.lock" || return 1
    if ! flock -n "$autocheck_fd"; then
        echo "An automatic update check is already running."
        return 0
    fi
    log_file=$(mktemp "$CACHE_DIR/.autocheck-log.XXXXXX") || return 1
    trap 'rm -f -- "$log_file"' EXIT
    check_updates --installed > "$log_file" 2>&1 || result=$?
    atomic_write_file "$CACHE_DIR/autocheck.log" < "$log_file" || return 1
    printf '%s status=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$result" |
        atomic_write_file "$CACHE_DIR/last-autocheck" || return 1
    cat -- "$log_file"
    return "$result"
)

autocheck_command() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: aur-taw autocheck <enable|disable|status|run>" >&2
        return 1
    fi
    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local unit='aur-taw-autocheck.timer' service
    case "$1" in
        run) _autocheck_run ;;
        enable)
            command -v systemctl >/dev/null 2>&1 || {
                echo "Error: Automatic scheduling requires a systemd user session." >&2
                return 1
            }
            systemctl --user show-environment >/dev/null || return 1
            [[ -f "$SCRIPT_PATH" ]] || { echo "Error: aur-taw executable not found." >&2; return 1; }
            mkdir -p -- "$unit_dir" || return 1
            service=$(_autocheck_service) || {
                echo "Error: Unsupported newline in installation/configuration path." >&2
                return 1
            }
            printf '%s\n' "$service" | atomic_write_file "$unit_dir/aur-taw-autocheck.service" || return 1
            _autocheck_timer | atomic_write_file "$unit_dir/$unit" || return 1
            systemctl --user daemon-reload || return 1
            systemctl --user enable --now "$unit" || return 1
            echo "Automatic checks enabled every six hours while your user session is running."
            echo "Only versions of tracked, installed packages are refreshed; no packages are installed."
            ;;
        disable)
            systemctl --user disable --now "$unit" || return 1
            systemctl --user stop aur-taw-autocheck.service || return 1
            echo "Automatic checks disabled."
            ;;
        status)
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
                    echo "Automatic checks: enabled"
                    systemctl --user list-timers --all --no-pager "$unit" || return 1
                else
                    echo "Automatic checks: disabled (or no systemd user session available)"
                fi
            else
                echo "Automatic checks: unavailable (systemd is not installed)"
            fi
            if [[ -r "$CACHE_DIR/last-autocheck" ]]; then
                printf 'Last automatic check: '; cat -- "$CACHE_DIR/last-autocheck"
            else
                echo "Last automatic check: never"
            fi
            if [[ -r "$CACHE_DIR/last-check" ]]; then
                printf 'Last successful version refresh: '; cat -- "$CACHE_DIR/last-check"
            fi
            [[ ! -r "$CACHE_DIR/autocheck.log" ]] || printf 'Log: %s\n' "$CACHE_DIR/autocheck.log"
            ;;
        *) echo "Usage: aur-taw autocheck <enable|disable|status|run>" >&2; return 1 ;;
    esac
}
