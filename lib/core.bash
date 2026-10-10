#!/bin/bash

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aur-taw"
CONFIG_FILE="$CONFIG_DIR/repos.txt"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aur-taw"

atomic_replace_file() {
    local temporary="$1" destination="$2"
    chmod 600 "$temporary" && sync -f "$temporary" &&
        mv -fT -- "$temporary" "$destination" && sync -f "$(dirname "$destination")"
}

atomic_write_file() (
    local destination="$1" temporary
    umask 077
    mkdir -p -- "$(dirname "$destination")" || return 1
    temporary=$(mktemp "${destination}.tmp.XXXXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    cat > "$temporary" || return 1
    atomic_replace_file "$temporary" "$destination"
)

validate_registry() {
    LC_ALL=C awk '
        NF != 5 { bad=1; next }
        $1 !~ /^[a-zA-Z0-9_+][a-zA-Z0-9_.+-]*$/ { bad=1 }
        $2 !~ /^https?:\/\/[^[:space:][:cntrl:]]+$/ { bad=1 }
        $3 ~ /[[:cntrl:]]/ { bad=1 }
        $4 !~ /^[a-zA-Z0-9_+@][a-zA-Z0-9_.+@-]*$/ { bad=1 }
        $5 !~ /^(tracked|added|imported|installed|bootstrap)$/ { bad=1 }
        seen[$1]++ { bad=1 }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

registry_transaction() (
    local temporary registry_lock result=0
    umask 077
    mkdir -p -- "$CONFIG_DIR" || return 1
    exec {registry_lock}>"$CONFIG_DIR/registry.lock" || return 1
    flock -x "$registry_lock" || return 1
    temporary=$(mktemp "$CONFIG_DIR/.repos.XXXXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    "$@" > "$temporary" || result=$?
    if ((result != 0)); then
        if ((result != 10)); then
            echo 'Error: Registry transaction aborted; previous data preserved.' >&2
        fi
        return "$result"
    fi
    if ! validate_registry "$temporary"; then
        echo 'Error: Invalid registry data; previous data preserved.' >&2
        return 1
    fi
    atomic_replace_file "$temporary" "$CONFIG_FILE"
)

_initialize_registry() (
    local migrated messages backup
    if [[ ! -e "$CONFIG_FILE" ]]; then
        printf '%s\n' 'aur-taw https://aur.archlinux.org/aur-taw.git Unknown aur-taw bootstrap'
        return
    fi
    if validate_registry "$CONFIG_FILE"; then
        cat -- "$CONFIG_FILE"
        return
    fi
    migrated=$(mktemp "$CONFIG_DIR/.migration.XXXXXXXX") || return 1
    messages=$(mktemp "$CONFIG_DIR/.migration-messages.XXXXXXXX") || { rm -f -- "$migrated"; return 1; }
    trap 'rm -f -- "$migrated" "$messages"' EXIT
    if ! LC_ALL=C awk -v messages="$messages" '
        function valid_alias(name) { return name ~ /^[a-zA-Z0-9_+][a-zA-Z0-9_.+-]*$/ }
        NR == FNR {
            if (NF && valid_alias($1)) reserved[$1]=1
            next
        }
        NF == 0 { next }
        NF != 2 && NF != 3 && NF != 5 { exit 1 }
        seen[$1]++ { exit 1 }
        {
            old=$1
            if (!valid_alias(old)) {
                base=old; gsub(/[^a-zA-Z0-9_.+-]/, "_", base)
                base="legacy-" base
                candidate=base; suffix=2
                while (candidate in reserved) candidate=base "-" suffix++
                reserved[candidate]=1
                $1=candidate
                display=old; gsub(/[[:cntrl:]]/, "?", display)
                printf "Legacy alias renamed: %s -> %s\n", display, candidate > messages
            }
            if (NF == 2 || NF == 3) {
                pkg=$2; sub(/\/$/, "", pkg); sub(/^.*\//, "", pkg); sub(/\.git$/, "", pkg)
                print $1, $2, "Unknown", pkg, "tracked"
            } else print
        }
    ' "$CONFIG_FILE" "$CONFIG_FILE" > "$migrated" || ! validate_registry "$migrated"; then
        echo 'Error: Registry migration could not safely interpret the data; original file preserved.' >&2
        return 1
    fi
    backup="$CONFIG_DIR/repos.pre-v2.bak"
    if [[ -e "$backup" ]] && ! cmp -s -- "$backup" "$CONFIG_FILE"; then
        backup=$(mktemp "$CONFIG_DIR/repos.pre-migration.XXXXXXXX.bak") || return 1
    fi
    if [[ ! -s "$backup" ]]; then
        atomic_write_file "$backup" < "$CONFIG_FILE" || return 1
    fi
    printf 'Migrating registry; original data saved in %s\n' "$backup" >&2
    cat -- "$messages" >&2
    cat -- "$migrated"
)

init_core() {
    local command_name
    for command_name in flock sync mktemp awk; do
        command -v "$command_name" >/dev/null || { echo "Error: Required command missing: $command_name" >&2; return 1; }
    done
    mkdir -p -- "$CONFIG_DIR" "$CACHE_DIR" || return 1
    if [[ -f "$CONFIG_FILE" ]] && validate_registry "$CONFIG_FILE"; then return 0; fi
    registry_transaction _initialize_registry
}

get_installed_pkg() {
    [[ -n "$1" ]] || return 1
    if pacman -Qq -- "$1" >/dev/null 2>&1; then
        printf '%s\n' "$1"
    else
        return 1
    fi
}

warn_version_mismatch() {
    local alias_name="$1" package="$2" installed="$3" latest="$4" comparison="$5" ordering
    ordering='newer than'
    [[ "$comparison" -ne 0 ]] || ordering='equivalent to'
    printf '  [VERSION MISMATCH] %s (%s): installed=%s | latest AUR=%s\n' \
        "$alias_name" "$package" "$installed" "$latest"
    printf '    vercmp considers the installed version %s the AUR version; no automatic update selected.\n' "$ordering"
    printf '    Different versioning or stale VCS metadata may explain this. Upstream freshness is not verified.\n'
}
