#!/bin/bash

_validate_dependency_metadata() {
    jq -e '
        type == "object" and all(to_entries[];
            (.key | test("^[A-Za-z0-9_+@][A-Za-z0-9_.+@-]*$")) and
            (.value | type == "object") and
            (.value | keys | sort == ["check", "make"]) and
            all(.value[];
                type == "array" and all(.[];
                    type == "string" and
                    test("^[A-Za-z0-9_+@][A-Za-z0-9_.+@-]*((>=|<=|>|<|=)[^[:space:][:cntrl:]]+)?$"))))' >/dev/null
}

_merge_dependency_metadata() (
    local incoming="$1" metadata_lock merged previous='{}'
    _validate_dependency_metadata <<< "$incoming" || {
        echo 'Error: Invalid dependency metadata; previous metadata retained.' >&2
        return 1
    }
    exec {metadata_lock}>"$CONFIG_DIR/dependency-metadata.lock" || return 1
    flock -x "$metadata_lock" || return 1
    if [[ -f "$CONFIG_DIR/dependency-metadata.json" ]]; then
        previous=$(cat -- "$CONFIG_DIR/dependency-metadata.json") || return 1
        _validate_dependency_metadata <<< "$previous" || {
            echo 'Error: Saved dependency metadata is invalid; previous file retained.' >&2
            return 1
        }
    fi
    merged=$(printf '%s\n%s\n' "$previous" "$incoming" | jq -s '.[0] * .[1]') || return 1
    atomic_write_file "$CONFIG_DIR/dependency-metadata.json" <<< "$merged"
)

record_aur_dependencies() {
    local metadata
    metadata=$(jq -e 'reduce .results[] as $p ({};
        .[$p.Name] = {make: ($p.MakeDepends // []), check: ($p.CheckDepends // [])})' <<< "$1") || return 1
    _merge_dependency_metadata "$metadata"
}

record_srcinfo_dependencies() {
    local metadata srcinfo="$1" arch
    [[ -f "$srcinfo" && ! -L "$srcinfo" ]] || return 1
    arch=$(uname -m)
    metadata=$(awk -v arch="$arch" '
        $2 == "=" && $1 == "pkgname" { pkg=$3; names[pkg]=1 }
        $2 == "=" && ($1 == "makedepends" || $1 == "makedepends_" arch) { make[pkg]=make[pkg] $3 "\n" }
        $2 == "=" && ($1 == "checkdepends" || $1 == "checkdepends_" arch) { check[pkg]=check[pkg] $3 "\n" }
        END { for (p in names) {
            print p "\tname\t-"
            n=split(make[""] make[p], a, "\n"); for(i=1;i<=n;i++) if(a[i]!="") print p "\tmake\t" a[i]
            n=split(check[""] check[p], a, "\n"); for(i=1;i<=n;i++) if(a[i]!="") print p "\tcheck\t" a[i]
        }}' "$srcinfo" | jq -Rn '[inputs | split("\t")] | group_by(.[0]) |
            map({key: .[0][0], value: {make: [ .[] | select(.[1]=="make") | .[2] ],
                check: [ .[] | select(.[1]=="check") | .[2] ]}}) | from_entries') || return 1
    _merge_dependency_metadata "$metadata"
}

_dep_version_satisfies() {
    local actual="$1" operator="$2" wanted="$3" comparison
    [[ -z "$operator" ]] && return 0
    [[ -n "$actual" ]] || return 1
    comparison=$(vercmp "$actual" "$wanted") || return 1
    case "$operator" in
        '=') ((comparison == 0));; '>') ((comparison > 0));; '<') ((comparison < 0));;
        '>=') ((comparison >= 0));; '<=') ((comparison <= 0));; *) return 1;;
    esac
}

_resolve_dependency() {
    local requirement="$1" name operator='' wanted='' candidate provided
    local -n result="$2"
    name="$requirement"
    if [[ "$requirement" =~ ^([^\<\>\=]+)(\>=|\<=|\>|\<|=)(.+)$ ]]; then
        name="${BASH_REMATCH[1]}" operator="${BASH_REMATCH[2]}" wanted="${BASH_REMATCH[3]}"
    fi
    if [[ -n "${versions[$name]+exists}" ]] && _dep_version_satisfies "${versions[$name]}" "$operator" "$wanted"; then
        result="$name"; return
    fi
    for candidate in ${providers[$name]:-}; do
        provided="${provided_versions[$name:$candidate]:-}"
        if _dep_version_satisfies "$provided" "$operator" "$wanted"; then
            result="$candidate"; return
        fi
    done
    result='-'
}

refresh_dependencies() (
    local dbpath dependency_lock rows snapshot kind pkg value source resolved requirement
    local -a descriptions
    local -A versions=() reasons=() providers=() provided_versions=() foreign=() known_aur=() resolved_requirements=()
    dbpath="${AUR_TAW_PACMAN_DB:-}"
    if [[ -z "$dbpath" ]]; then
        dbpath=$(pacman-conf DBPath 2>/dev/null) || dbpath=/var/lib/pacman
    fi
    [[ -d "$dbpath/local" ]] || { echo 'Warning: Pacman local database unavailable; dependency snapshot retained.' >&2; return 1; }
    exec {dependency_lock}>"$CONFIG_DIR/dependencies.lock" || return 1
    flock -x "$dependency_lock" || return 1
    rows=$(mktemp "$CONFIG_DIR/.dep-rows.XXXXXXXX") || return 1
    snapshot=$(mktemp "$CONFIG_DIR/.deps.XXXXXXXX") || { rm -f "$rows"; return 1; }
    trap 'rm -f -- "$rows" "$snapshot"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    shopt -s nullglob
    descriptions=("$dbpath"/local/*/desc)
    if ((${#descriptions[@]})); then
        awk '
            FNR==1 {name=""; section=""}
            /^%.*%$/ {section=$0; next}
            NF==0 {section=""; next}
            section=="%NAME%" {name=$0}
            section=="%VERSION%" {version=$0}
            section=="%REASON%" {reason=$0}
            section=="%VERSION%" {print "V\t" name "\t" version}
            section=="%REASON%" {print "R\t" name "\t" reason}
            section=="%DEPENDS%" {print "D\t" name "\t" $0}
            section=="%PROVIDES%" {print "P\t" name "\t" $0}
        ' "${descriptions[@]}" > "$rows" || return 1
    fi
    while IFS=$'\t' read -r kind pkg value; do
        case "$kind" in
            V) versions["$pkg"]="$value";;
            R) reasons["$pkg"]="$value";;
            P) requirement="${value%%[<>=]*}"; providers["$requirement"]+=" $pkg"
               if [[ "$value" == *=* ]]; then provided_versions["$requirement:$pkg"]="${value#*=}"; fi;;
        esac
    done < "$rows"
    while read -r pkg; do [[ -n "$pkg" ]] && foreign["$pkg"]=1; done < <(pacman -Qmq 2>/dev/null)
    while read -r _ value _ pkg _; do
        [[ "$value" == https://aur.archlinux.org/* && -n "$pkg" ]] && known_aur["$pkg"]=1
    done < "$CONFIG_FILE"
    {
        for pkg in "${!versions[@]}"; do
            source=repo
            if [[ -n "${foreign[$pkg]:-}" ]]; then
                source=foreign
                [[ -n "${known_aur[$pkg]:-}" ]] && source=AUR
            fi
            kind=explicit; [[ "${reasons[$pkg]:-0}" == 1 ]] && kind=dependency
            printf 'P\t%s\t%s\t%s\t%s\n' "$pkg" "${versions[$pkg]}" "$kind" "$source" || return 1
        done
        while IFS=$'\t' read -r kind pkg requirement; do
            [[ "$kind" == D ]] || continue
            if [[ -n "${resolved_requirements[$requirement]+exists}" ]]; then
                resolved="${resolved_requirements[$requirement]}"
            else
                _resolve_dependency "$requirement" resolved
                resolved_requirements["$requirement"]="$resolved"
            fi
            [[ "$resolved" != '-' ]] || continue
            printf 'D\t%s\t%s\truntime\t%s\n' "$pkg" "$resolved" "$requirement" || return 1
        done < "$rows"
    } > "$snapshot" || return 1
    LC_ALL=C sort -u "$snapshot" > "$rows" || return 1
    atomic_replace_file "$rows" "$CONFIG_DIR/dependencies.txt"
)

_deps_tree_node() {
    local pkg="$1" indent="$2" ancestors="$3" depth="$4" child
    if ((depth > 128)); then printf '%s[depth limit]\n' "$indent"; return; fi
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        printf '%s|- %s' "$indent" "${dep_aliases[$child]:-$child}"
        if [[ "$ancestors" == *"|$child|"* ]]; then printf ' [cycle]\n'; continue; fi
        if [[ -n "${dep_seen[$child]:-}" ]]; then printf ' [already shown]\n'; continue; fi
        printf '\n'; dep_seen["$child"]=1
        _deps_tree_node "$child" "$indent|  " "$ancestors$child|" "$((depth + 1))"
    done <<< "${dep_edges[$pkg]:-}"
}

_deps_collect() {
    local pkg="$1" child
    [[ -n "${dep_seen[$pkg]:-}" ]] && return
    dep_seen["$pkg"]=1
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        dep_selected["$child"]=1
        dep_required_by["$child"]+="$pkg"$'\n'
        _deps_collect "$child"
    done <<< "${dep_edges[$pkg]:-}"
}

deps_command() {
    local tree=0 all=0 target='' arg kind pkg version reason source parent child requirement alias_name
    local shown=0
    local -a roots=()
    local -A dep_versions=() dep_sources=() dep_reasons=() dep_edges=() dep_seen=() dep_selected=()
    local -A dep_required_by=() dep_pairs=() root_set=() root_has_parent=() dep_aliases=() alias_packages=()
    for arg in "$@"; do
        case "$arg" in
            --tree) tree=1;; --all) all=1;;
            -*) echo "Usage: aur-taw deps [alias|package] [--tree] [--all]" >&2; return 1;;
            *) [[ -z "$target" ]] || return 1; target="$arg";;
        esac
    done
    refresh_dependencies || return 1
    while read -r alias_name _ _ pkg _; do
        if [[ -n "$alias_name" && -n "$pkg" ]]; then
            dep_aliases["$pkg"]="$alias_name"
            alias_packages["$alias_name"]="$pkg"
        fi
    done < "$CONFIG_FILE"
    while IFS=$'\t' read -r kind pkg version reason source; do
        [[ "$kind" == P ]] || continue
        dep_versions["$pkg"]="$version"; dep_reasons["$pkg"]="$reason"; dep_sources["$pkg"]="$source"
    done < "$CONFIG_DIR/dependencies.txt"
    while IFS=$'\t' read -r kind parent child reason requirement; do
        [[ "$kind" == D && "$reason" == runtime && "$child" != '-' ]] || continue
        [[ -n "${dep_versions[$parent]+exists}" && -n "${dep_versions[$child]+exists}" ]] || continue
        if ((!all)); then
            [[ "${dep_sources[$parent]}" == AUR && "${dep_sources[$child]}" == AUR ]] || continue
        fi
        [[ -z "${dep_pairs[$parent:$child]:-}" ]] || continue
        dep_pairs["$parent:$child"]=1
        dep_edges["$parent"]+="$child"$'\n'
    done < "$CONFIG_DIR/dependencies.txt"
    if [[ -n "$target" ]]; then
        pkg="${alias_packages[$target]:-$target}"
        [[ -n "${dep_versions[$pkg]+exists}" ]] || { echo "Error: '$target' is not installed." >&2; return 1; }
        if ((!all)) && [[ "${dep_sources[$pkg]}" != AUR ]]; then
            echo "Error: '$target' is not a tracked AUR package. Use --all to show its installed dependencies." >&2
            return 1
        fi
        roots+=("$pkg")
    else
        for pkg in "${!dep_versions[@]}"; do
            [[ "${dep_sources[$pkg]}" == AUR ]] && root_set["$pkg"]=1
        done
        if ((${#root_set[@]})); then
            mapfile -t roots < <(printf '%s\n' "${!root_set[@]}" | LC_ALL=C sort)
        fi
    fi
    if ((tree)); then
        if [[ -z "$target" ]]; then
            for parent in "${roots[@]}"; do
                while IFS= read -r child; do
                    [[ -n "$child" && -n "${root_set[$child]:-}" ]] && root_has_parent["$child"]=1
                done <<< "${dep_edges[$parent]:-}"
            done
        fi
        for arg in outer remaining; do
            for pkg in "${roots[@]}"; do
                [[ -n "${dep_edges[$pkg]:-}" && -z "${dep_seen[$pkg]:-}" ]] || continue
                if [[ "$arg" == outer && -n "${root_has_parent[$pkg]:-}" ]]; then continue; fi
                printf '%s\n' "${dep_aliases[$pkg]:-$pkg}"
                dep_seen["$pkg"]=1; shown=1
                _deps_tree_node "$pkg" '' "|$pkg|" 0
            done
        done
        if ((!shown)); then
            if ((all)); then echo 'No installed dependency relations found.'
            else echo 'No dependency relations between installed AUR packages.'; fi
        fi
    else
        if ((all)) && [[ -z "$target" ]]; then
            for pkg in "${!dep_versions[@]}"; do [[ "${dep_reasons[$pkg]}" == dependency ]] && dep_selected["$pkg"]=1; done
        else
            for pkg in "${roots[@]}"; do _deps_collect "$pkg"; done
        fi
        if ((${#dep_selected[@]} == 0)); then
            if ((all)); then echo 'No installed dependencies found.'
            else echo 'No dependency relations between installed AUR packages.'; fi
            return 0
        fi
        if ((all)); then
            printf '%-32s %s\n' 'PACKAGE' 'VERSION'
            for pkg in "${!dep_selected[@]}"; do
                printf '%-32s %s\n' "${dep_aliases[$pkg]:-$pkg}" "${dep_versions[$pkg]}"
            done | LC_ALL=C sort
        else
            printf '%-32s %s\n' 'PACKAGE' 'REQUIRED BY'
            for pkg in "${!dep_selected[@]}"; do
                while IFS= read -r parent; do
                    [[ -n "$parent" ]] || continue
                    printf '%s\t%s\n' "${dep_aliases[$pkg]:-$pkg}" "${dep_aliases[$parent]:-$parent}"
                done <<< "${dep_required_by[$pkg]}"
            done | LC_ALL=C sort -u | awk -F '\t' '
                $1 != package {
                    if (NR > 1) printf "%-32s %s\n", package, parents
                    package=$1; parents=$2; next
                }
                { parents=parents ", " $2 }
                END { if (NR > 0) printf "%-32s %s\n", package, parents }
            ' | LC_ALL=C sort
        fi
    fi
}
