#!/bin/bash

plan_upgrade_order() {
    declare -ga UPGRADE_ORDER=()
    declare -gA UPGRADE_GROUP_OF=() UPGRADE_GROUP_REQUIRES=() UPGRADE_GROUP_LABEL=()
    local item alias_name url latest pkg origin commit group existing_group comparison
    local kind parent child reason requirement cursor ready dependent remaining label
    local -a groups=() queue=() planned=() prerequisites=()
    local -A rows=() versions=() edges=() url_group=() group_commit=() group_items=()
    local -A group_packages=() package_group=() active=() pairs=() seen=() emitted=() dependents=()

    refresh_dependencies || {
        printf 'Error: cannot determine upgrade order from installed dependencies.\n' >&2
        return 1
    }
    [[ -r "$CONFIG_DIR/dependencies.txt" ]] || {
        printf 'Error: installed dependency snapshot is unavailable.\n' >&2
        return 1
    }
    while read -r alias_name url latest pkg origin; do
        [[ -n "$alias_name" ]] || continue
        rows["$alias_name"]="$url $latest $pkg $origin"
    done < "$CONFIG_FILE"
    while IFS=$'\t' read -r kind parent child reason requirement; do
        case "$kind" in
            P) versions["$parent"]="$child" ;;
            D)
                [[ "$reason" == runtime && "$child" != '-' ]] || continue
                edges["$parent"]+="$child"$'\n'
                ;;
        esac
    done < "$CONFIG_DIR/dependencies.txt"

    for item in "$@"; do
        alias_name="${item%@*}"; commit=''; url=''; latest=''; pkg=''; origin=''
        [[ "$item" != *@* ]] || commit="${item#*@}"
        if [[ -n "${rows[$alias_name]:-}" ]]; then
            read -r url latest pkg origin <<< "${rows[$alias_name]}"
        fi
        if [[ -n "$url" && -n "${url_group[$url]+exists}" ]]; then
            group="${url_group[$url]}"
            if [[ "${group_commit[$group]}" != "$commit" ]]; then
                printf 'Error: conflicting commits requested for the same recipe: %s, %s. Use one commit per repository.\n' \
                    "${UPGRADE_GROUP_LABEL[$group]}" "$item" >&2
                return 1
            fi
        else
            group="${#groups[@]}"
            groups+=("$group")
            prerequisites[group]=0
            group_commit["$group"]="$commit"
            UPGRADE_GROUP_REQUIRES["$group"]=''
            [[ -z "$url" ]] || url_group["$url"]="$group"
        fi
        UPGRADE_GROUP_OF["$item"]="$group"
        UPGRADE_GROUP_LABEL["$group"]+="${UPGRADE_GROUP_LABEL[$group]:+, }$item"
        group_items["$group"]+="$item"$'\n'
        [[ -n "$pkg" ]] || continue
        if _check_is_dev_package "$alias_name" "$url" "$pkg"; then continue; fi
        if [[ -n "$commit" || -z "${versions[$pkg]+exists}" || -z "$latest" || "$latest" == Unknown ]]; then
            active["$group"]=1
        else
            comparison=$(vercmp "${versions[$pkg]}" "$latest") || {
                printf 'Error: cannot compare versions for %s.\n' "$alias_name" >&2
                return 1
            }
            ((comparison >= 0)) || active["$group"]=1
        fi
    done

    while read -r alias_name url latest pkg origin; do
        [[ -n "$pkg" && -n "${url_group[$url]+exists}" ]] || continue
        group="${url_group[$url]}"
        package_group["$pkg"]="$group"
        group_packages["$group"]+="$pkg"$'\n'
    done < "$CONFIG_FILE"

    for group in "${groups[@]}"; do
        [[ -n "${active[$group]:-}" ]] || continue
        queue=(); seen=(); cursor=0
        while IFS= read -r pkg; do
            [[ -n "$pkg" && -z "${seen[$pkg]:-}" ]] || continue
            queue+=("$pkg")
            seen["$pkg"]=1
        done <<< "${group_packages[$group]:-}"
        while ((cursor < ${#queue[@]})); do
            parent="${queue[$cursor]}"; cursor=$((cursor + 1))
            while IFS= read -r child; do
                [[ -n "$child" ]] || continue
                if [[ -n "${package_group[$child]+exists}" ]]; then
                    existing_group="${package_group[$child]}"
                    if [[ "$existing_group" != "$group" && -n "${active[$existing_group]:-}" &&
                          -z "${pairs[$group:$existing_group]:-}" ]]; then
                        pairs["$group:$existing_group"]=1
                        UPGRADE_GROUP_REQUIRES["$group"]+="$existing_group"$'\n'
                        dependents["$existing_group"]+="$group"$'\n'
                        prerequisites[group]=$((prerequisites[group] + 1))
                    fi
                fi
                if [[ -z "${seen[$child]:-}" ]]; then
                    queue+=("$child")
                    seen["$child"]=1
                fi
            done <<< "${edges[$parent]:-}"
        done
    done

    remaining="${#groups[@]}"
    while ((remaining > 0)); do
        ready=''
        for group in "${groups[@]}"; do
            [[ -z "${emitted[$group]:-}" ]] || continue
            if ((prerequisites[group] == 0)); then ready="$group"; break; fi
        done
        if [[ -z "$ready" ]]; then
            label=''
            for group in "${groups[@]}"; do
                [[ -z "${emitted[$group]:-}" ]] || continue
                label+="${label:+; }${UPGRADE_GROUP_LABEL[$group]}"
            done
            printf 'Error: an installed dependency cycle prevents ordering these upgrades: %s. No build started.\n' "$label" >&2
            return 1
        fi
        emitted["$ready"]=1
        remaining=$((remaining - 1))
        while IFS= read -r dependent; do
            [[ -n "$dependent" ]] || continue
            prerequisites[dependent]=$((prerequisites[dependent] - 1))
        done <<< "${dependents[$ready]:-}"
        while IFS= read -r item; do
            [[ -z "$item" ]] || planned+=("$item")
        done <<< "${group_items[$ready]}"
    done
    UPGRADE_ORDER=("${planned[@]}")
}
