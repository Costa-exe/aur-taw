#!/bin/bash

_aur_http() {
    curl --fail --silent --show-error --globoff --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 30 --max-filesize 8388608 "$@"
}

_aur_validate_json() {
    jq -ce '
        select(type == "object" and .type != "error" and (.error == null)) |
        select(.results | type == "array") |
        select(all(.results[];
            (.Name | type == "string") and
            (.Name | test("^[A-Za-z0-9@_+][A-Za-z0-9@._+\\-]*$")) and
            (.PackageBase | type == "string") and
            (.PackageBase | test("^[A-Za-z0-9@_+][A-Za-z0-9@._+\\-]*$")) and
            (.Version | type == "string") and
            (.Version | test("^[^[:space:][:cntrl:]]+$")))) |
        select((.results | length) == (.results | unique_by(.Name) | length))'
}

_aur_rpc() {
    local endpoint="$1" response validated
    shift
    if ! response=$(_aur_http --get "https://aur.archlinux.org/rpc/v5/$endpoint" "$@"); then
        echo "Error: AUR request failed; saved versions have been retained." >&2
        return 1
    fi
    if ! validated=$(_aur_validate_json <<< "$response"); then
        echo "Error: Invalid AUR response; saved versions have been retained." >&2
        return 1
    fi
    printf '%s\n' "$validated"
}

aur_info() {
    local -a names=("$@") args=() batch_names=() responses=()
    local response name offset
    for name in "${names[@]}"; do
        if [[ ! "$name" =~ ^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$ ]]; then
            echo "Error: Invalid AUR package name: $name" >&2
            return 1
        fi
    done
    for ((offset = 0; offset < ${#names[@]}; offset += 100)); do
        args=()
        batch_names=("${names[@]:offset:100}")
        for name in "${batch_names[@]}"; do args+=(--data-urlencode "arg[]=$name"); done
        response=$(_aur_rpc info "${args[@]}") || return 1
        if ! jq -e --args '($ARGS.positional | INDEX(.)) as $names |
            all(.results[]; $names[.Name] != null)' -- "${batch_names[@]}" <<< "$response" >/dev/null; then
            echo "Error: AUR returned an unexpected package identity." >&2
            return 1
        fi
        responses+=("$response")
    done
    if ((${#responses[@]})); then
        printf '%s\n' "${responses[@]}" | jq -sc '{results: ([.[].results[]] | unique_by(.Name))}'
    else
        printf '{"results":[]}\n'
    fi
}

_aur_url_base() {
    [[ "$1" =~ ^https://aur\.archlinux\.org/([A-Za-z0-9@_+][A-Za-z0-9@._+-]*)\.git/?$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

aur_repo_info() {
    local url="$1" base srcinfo parsed_base response
    local -a names=()
    if ! base=$(_aur_url_base "$url"); then
        echo "Error: Expected an HTTPS AUR Git repository URL." >&2
        return 1
    fi
    if ! srcinfo=$(_aur_http --get 'https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO' --data-urlencode "h=$base"); then
        echo "Error: Cannot read package metadata for $base." >&2
        return 1
    fi
    parsed_base=$(awk '$1 == "pkgbase" && $2 == "=" {print $3}' <<< "$srcinfo")
    mapfile -t names < <(awk '$1 == "pkgname" && $2 == "=" {print $3}' <<< "$srcinfo" | sort -u)
    if [[ "$parsed_base" != "$base" || ${#names[@]} -eq 0 ]]; then
        echo "Error: Invalid .SRCINFO for $base." >&2
        return 1
    fi
    response=$(aur_info "${names[@]}") || return 1
    if ! jq -e --arg base "$base" --argjson count "${#names[@]}" \
        '(.results | length) == $count and all(.results[]; .PackageBase == $base)' <<< "$response" >/dev/null; then
        echo "Error: AUR package-base identity mismatch for $base." >&2
        return 1
    fi
    printf '%s\n' "$response"
}

search_aur() {
    if [[ $# -ne 1 || -z "$1" ]]; then
        echo "Usage: aur-taw search <query>" >&2
        return 1
    fi
    local response
    response=$(_aur_rpc search --data-urlencode "arg=$1" --data-urlencode 'by=name') || return 1
    echo "Searching for '$1' on AUR..."
    echo "------------------------------------------------------------------------"
    jq -r '.results | sort_by(.NumVotes) | reverse | .[] |
        "\(.Name) \(.Version) [Votes: \(.NumVotes)]\n   \(.Description // "No description")\n   https://aur.archlinux.org/\(.PackageBase).git\n"' <<< "$response"
}

_check_is_dev_package() {
    local alias_name="$1" url="$2" pkgname="$3" base
    [[ "${VERSION:-}" == *-dev* ]] || return 1
    base="${url%/}"; base="${base##*/}"; base="${base%.git}"
    [[ "$alias_name" == aur-taw || "$pkgname" == aur-taw || "$pkgname" == aur-taw-dev || "$base" == aur-taw ]]
}

_registry_merge_latest() {
    local updates="$1"
    awk 'NR == FNR { versions[$1 SUBSEP $2] = $3; next }
        { key = $2 SUBSEP $4; if (key in versions) $3 = versions[key]; print }' "$updates" "$CONFIG_FILE"
}

check_updates() (
    local installed_only=0 quiet=0 option
    for option in "$@"; do
        case "$option" in
            --installed) installed_only=1 ;;
            --quiet) quiet=1 ;;
            *) echo "Usage: aur-taw check [--installed] [--quiet]" >&2; return 1 ;;
        esac
    done
    local alias_name url latest pkgname origin installed_ver remote_ver response updates comparison base check_lock
    local snapshot metadata missing=0 refreshed=0
    local -a names=() installed_names=()
    local -A requested=() versions=() remote_bases=() repository_bases=() check_installed=()
    exec {check_lock}>"$CONFIG_DIR/version-check.lock" || return 1
    if ! flock -n "$check_lock"; then
        ((quiet)) || echo 'Another version check is running; waiting for it to finish...'
        flock -x "$check_lock" || return 1
    fi
    snapshot=$(cat -- "$CONFIG_FILE") || return 1
    while read -r alias_name url latest pkgname origin; do
        [[ -n "$alias_name" ]] || continue
        _check_is_dev_package "$alias_name" "$url" "$pkgname" && continue
        if ! _aur_url_base "$url" >/dev/null; then
            echo "  [!] $alias_name: skipping version lookup for a non-HTTPS-AUR repository ($url)." >&2
            continue
        fi
        repository_bases["$url"]="${BASH_REMATCH[1]}"
        if [[ ! -v requested["$pkgname"] ]]; then
            names+=("$pkgname"); requested["$pkgname"]=1
        fi
    done <<< "$snapshot"
    if ((installed_only)); then
        _db_installed_versions check_installed "${names[@]}"
        for pkgname in "${names[@]}"; do
            if [[ -v check_installed["$pkgname"] ]]; then
                installed_names+=("$pkgname")
            else
                unset 'requested[$pkgname]'
            fi
        done
        names=("${installed_names[@]}")
    fi
    if ((${#names[@]} == 0)); then
        ((quiet)) || echo "No eligible packages to check (development aur-taw builds are excluded)."
        return 0
    fi
    ((quiet)) || echo "Checking ${#names[@]} package(s) for AUR updates..."
    response=$(aur_info "${names[@]}") || return 1
    if ((!quiet)); then
        _db_installed_versions check_installed "${names[@]}"
    fi
    metadata=$(jq -r '.results[] | [.Name, .Version, .PackageBase] | @tsv' <<< "$response") || return 1
    while IFS=$'\t' read -r pkgname remote_ver base; do
        if [[ -n "$pkgname" ]]; then
            versions["$pkgname"]="$remote_ver"
            remote_bases["$pkgname"]="$base"
        fi
    done <<< "$metadata"
    updates=$(mktemp "$CACHE_DIR/.versions.XXXXXX") || return 1
    trap 'rm -f -- "$updates"' EXIT
    while read -r alias_name url latest pkgname origin; do
        [[ -n "$alias_name" ]] || continue
        _check_is_dev_package "$alias_name" "$url" "$pkgname" && continue
        base="${repository_bases["$url"]:-}"
        [[ -n "$base" ]] || continue
        [[ -v requested["$pkgname"] ]] || continue
        remote_ver="${versions["$pkgname"]:-}"
        if [[ -z "$remote_ver" ]]; then
            echo "  [!] $alias_name ($pkgname): unavailable on AUR; retained latest $latest." >&2
            missing=1
            continue
        fi
        if [[ "${remote_bases["$pkgname"]}" != "$base" ]]; then
            echo "  [!] $alias_name ($pkgname): AUR package belongs to another repository; retained latest $latest." >&2
            missing=1
            continue
        fi
        printf '%s %s %s\n' "$url" "$pkgname" "$remote_ver" >> "$updates" || return 1
        refreshed=$((refreshed + 1))
        if ((!quiet)) && [[ -v check_installed["$pkgname"] ]]; then
            installed_ver="${check_installed["$pkgname"]}"
            comparison=$(vercmp "$installed_ver" "$remote_ver") || return 1
            if [[ "$comparison" -lt 0 ]]; then
                echo "  [UPDATE] $alias_name ($pkgname): $installed_ver -> $remote_ver"
            elif [[ "$installed_ver" != "$remote_ver" ]]; then
                warn_version_mismatch "$alias_name" "$pkgname" "$installed_ver" "$remote_ver" "$comparison"
            fi
        fi
    done <<< "$snapshot"
    if [[ -s "$updates" ]]; then
        registry_transaction _registry_merge_latest "$updates" || return 1
    fi
    if ((missing == 0)); then
        date -u '+%Y-%m-%dT%H:%M:%SZ' | atomic_write_file "$CACHE_DIR/last-check" || return 1
    fi
    if ((!quiet)); then
        echo "Check completed: $refreshed version(s) refreshed."
        echo "Use 'aur-taw list' or 'aur-taw install --all --upgrade'."
    fi
    return "$missing"
)

view_pkgbuild() (
    local alias_name="${1:-}" url temp_dir
    if [[ -z "$alias_name" ]]; then echo "Error: Provide the alias." >&2; return 1; fi
    url=$(awk -v name="$alias_name" '$1 == name {print $2}' "$CONFIG_FILE")
    if [[ -z "$url" ]]; then echo "Error: Alias not found." >&2; return 1; fi
    temp_dir=$(mktemp -d "$CACHE_DIR/aur-taw-view.XXXXXX") || return 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    safe_git clone -q --no-checkout --no-recurse-submodules -- "$url" "$temp_dir/repo" || return 1
    safe_git -C "$temp_dir/repo" show HEAD:PKGBUILD > "$temp_dir/PKGBUILD" || return 1
    ${PAGER:-less} "$temp_dir/PKGBUILD"
)

log_repo() (
    local alias_name="${1:-}" url temp_dir hash pkgver pkgrel commit_msg display_version
    if [[ -z "$alias_name" ]]; then echo "Error: Provide the alias." >&2; return 1; fi
    url=$(awk -v name="$alias_name" '$1 == name {print $2}' "$CONFIG_FILE")
    if [[ -z "$url" ]]; then echo "Error: Alias not found." >&2; return 1; fi
    temp_dir=$(mktemp -d "$CACHE_DIR/aur-taw-log.XXXXXX") || return 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    safe_git clone -q --no-checkout --no-recurse-submodules -- "$url" "$temp_dir/repo" || return 1
    printf '%-8s | %-15s | %s\n' COMMIT VERSION 'COMMIT MESSAGE'
    echo '------------------------------------------------------------------------'
    while read -r hash; do
        pkgver=$(safe_git -C "$temp_dir/repo" show "${hash}:PKGBUILD" 2>/dev/null | sed -n 's/^pkgver=//p' | tr -d '\"\047')
        pkgrel=$(safe_git -C "$temp_dir/repo" show "${hash}:PKGBUILD" 2>/dev/null | sed -n 's/^pkgrel=//p' | tr -d '\"\047')
        commit_msg=$(safe_git -C "$temp_dir/repo" log -1 --format='%s' "$hash")
        display_version='Not available'
        [[ -z "$pkgver" ]] || display_version="${pkgver}-${pkgrel}"
        printf '%-8s | %-15s | %s\n' "$hash" "$display_version" "$commit_msg"
    done < <(safe_git -C "$temp_dir/repo" log --format='%h' -n 10)
)
