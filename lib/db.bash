#!/bin/bash

_db_valid_name() { [[ "$1" =~ ^[a-zA-Z0-9_+][a-zA-Z0-9_.+-]*$ ]]; }
_db_valid_package() { [[ "$1" =~ ^[a-zA-Z0-9_+@][a-zA-Z0-9_.+@-]*$ ]]; }
_db_valid_url() { [[ "$1" =~ ^https?://[^[:space:][:cntrl:]]+$ ]]; }

_db_installed_versions() {
    local -n result_versions="$1"
    shift
    result_versions=()
    (($#)) || return 0
    local package_version package_name
    while read -r package_name package_version; do
        [[ -n "$package_name" && -n "$package_version" ]] || continue
        result_versions["$package_name"]="$package_version"
    done < <(pacman -Q -- "$@" 2>/dev/null)
}

_db_resolve_metadata() {
    local url="$1" requested="${2:-}" json candidate package version metadata
    local -a packages=()
    local -A versions=()
    candidate="${url%/}"
    candidate="${candidate##*/}"
    candidate="${candidate%.git}"
    DB_PACKAGE="${requested:-$candidate}"
    DB_LATEST=Unknown
    if ! _db_valid_package "$DB_PACKAGE"; then
        echo 'Error: Cannot infer a valid package name; provide --package <name>.' >&2
        return 1
    fi
    if ! json=$(aur_repo_info "$url"); then
        echo 'Warning: AUR metadata unavailable; latest saved as Unknown. Run aur-taw check later.' >&2
        return 0
    fi
    metadata=$(jq -r '.results[] | [.Name, .Version] | @tsv' <<< "$json") || return 1
    while IFS=$'\t' read -r package version; do
        [[ -n "$package" ]] || continue
        packages+=("$package")
        versions["$package"]="$version"
    done <<< "$metadata"
    if [[ ${#packages[@]} -eq 0 ]]; then
        echo 'Warning: Repository not found on AUR; latest saved as Unknown.' >&2
        return 0
    fi
    if [[ -z "$requested" && ! -v versions["$candidate"] ]]; then
        if [[ ${#packages[@]} -eq 1 ]]; then
            DB_PACKAGE="${packages[0]}"
        else
            echo 'Error: Split repository: select a package with --package <name>:' >&2
            printf '  %s\n' "${packages[@]}" >&2
            return 1
        fi
    fi
    DB_LATEST="${versions["$DB_PACKAGE"]:-}"
    if [[ -z "$DB_LATEST" ]]; then
        printf "Error: Package '%s' is not produced by this AUR repository.\n" "$DB_PACKAGE" >&2
        return 1
    fi
}

_db_add_row() {
    local name="$1" url="$2" latest="$3" package="$4" existing
    if awk -v name="$name" '$1 == name { found=1 } END { exit !found }' "$CONFIG_FILE"; then
        printf "Error: Alias '%s' already exists. Use aur-taw edit %s.\n" "$name" "$name" >&2
        return 1
    fi
    existing=$(awk -v package="$package" '$4 == package { print $1; exit }' "$CONFIG_FILE")
    if [[ -n "$existing" ]]; then
        printf "Error: Package '%s' is already tracked as '%s'; use edit.\n" "$package" "$existing" >&2
        return 1
    fi
    cat "$CONFIG_FILE" || return 1
    printf '%s %s %s %s added\n' "$name" "$url" "$latest" "$package"
}

add_repo() {
    if [[ $# -ne 2 && $# -ne 4 ]]; then
        echo 'Usage: aur-taw add <alias> <url> [--package <name>]' >&2
        return 1
    fi
    local name="$1" url="${2%/}" package=""
    if [[ $# -eq 4 ]]; then
        [[ "$3" == --package ]] || { echo 'Error: Expected --package <name>.' >&2; return 1; }
        package="$4"
    fi
    if ! _db_valid_name "$name" || ! _db_valid_url "$url" || { [[ -n "$package" ]] && ! _db_valid_package "$package"; }; then
        echo 'Error: Use a simple alias/package name and an HTTP(S) URL without whitespace.' >&2
        return 1
    fi
    _db_resolve_metadata "$url" "$package" || return 1
    registry_transaction _db_add_row "$name" "$url" "$DB_LATEST" "$DB_PACKAGE" || return 1
    printf 'Added: %s -> %s\n  Package: %s | Latest AUR: %s | Origin: added\n' "$name" "$url" "$DB_PACKAGE" "$DB_LATEST"
}

_db_edit_row() {
    local old_name="$1" name="$2" url="$3" latest="$4" package="$5" old_url="$6" old_package="$7" changed="$8"
    local a u v p origin found=0
    while read -r a u v p origin; do
        [[ -n "$a" ]] || continue
        if [[ "$a" == "$name" && "$a" != "$old_name" ]]; then
            printf "Error: Alias '%s' is already in use.\n" "$name" >&2
            return 1
        fi
        if [[ "$p" == "$package" && "$a" != "$old_name" ]]; then
            printf "Error: Package '%s' is already tracked as '%s'.\n" "$package" "$a" >&2
            return 1
        fi
        if [[ "$a" == "$old_name" ]]; then
            found=1
            if [[ "$u" != "$old_url" || "$p" != "$old_package" ]]; then
                echo 'Error: Entry changed concurrently; retry edit.' >&2
                return 1
            fi
            if [[ "$changed" -eq 1 ]]; then
                v="$latest"
                origin=added
            fi
            printf '%s %s %s %s %s\n' "$name" "$url" "$v" "$package" "$origin"
        else
            printf '%s %s %s %s %s\n' "$a" "$u" "$v" "$p" "$origin"
        fi
    done < "$CONFIG_FILE"
    [[ "$found" -eq 1 ]] || { echo 'Error: Entry no longer exists; retry edit.' >&2; return 1; }
}

edit_repo() {
    if [[ $# -lt 2 ]]; then
        echo 'Usage: aur-taw edit <alias> [--name <alias>] [--url <url>] [--package <name>]' >&2
        return 1
    fi
    local old_name="$1" row name url latest package origin old_url old_package changed=0 package_set=0
    shift
    _db_valid_name "$old_name" || { echo 'Error: Invalid alias.' >&2; return 1; }
    row=$(awk -v name="$old_name" '$1 == name { print; exit }' "$CONFIG_FILE")
    [[ -n "$row" ]] || { printf "Error: Alias '%s' not found.\n" "$old_name" >&2; return 1; }
    read -r name url latest package origin <<< "$row"
    old_url="$url"
    old_package="$package"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name|--url|--package)
                [[ $# -ge 2 && -n "$2" ]] || { printf 'Error: %s needs a value.\n' "$1" >&2; return 1; }
                case "$1" in
                    --name) name="$2" ;;
                    --url) url="${2%/}" ;;
                    --package) package="$2"; package_set=1 ;;
                esac
                shift 2 ;;
            http://*|https://*) url="${1%/}"; shift ;;
            *) printf 'Error: Unknown edit argument: %s\n' "$1" >&2; return 1 ;;
        esac
    done
    if ! _db_valid_name "$name" || ! _db_valid_package "$package" || ! _db_valid_url "$url"; then
        echo 'Error: Invalid alias, package name, or HTTP(S) URL.' >&2
        return 1
    fi
    if [[ "$old_name" == aur-taw || "$old_package" == aur-taw ]]; then
        if [[ "$name" != "$old_name" || "$url" != "$old_url" || "$package" != "$old_package" ]]; then
            echo 'Error: The aur-taw self-update entry cannot be renamed or redirected.' >&2
            return 1
        fi
    fi
    if [[ "$url" != "$old_url" || "$package" != "$old_package" ]]; then
        changed=1
        if [[ "$url" != "$old_url" && "$package_set" -eq 0 ]]; then package=""; fi
        _db_resolve_metadata "$url" "$package" || return 1
        package="$DB_PACKAGE"
        latest="$DB_LATEST"
    fi
    registry_transaction _db_edit_row "$old_name" "$name" "$url" "$latest" "$package" "$old_url" "$old_package" "$changed" || return 1
    printf 'Edited: %s -> %s\n  Package: %s | Repository: %s\n' "$old_name" "$name" "$package" "$url"
    if declare -F refresh_dependencies >/dev/null; then refresh_dependencies; fi
}

_db_remove_row() {
    local name="$1" package
    package=$(awk -v name="$name" '$1 == name { print $4; exit }' "$CONFIG_FILE")
    [[ -n "$package" ]] || { printf "Error: Alias '%s' not found.\n" "$name" >&2; return 1; }
    if get_installed_pkg "$package" >/dev/null; then
        printf "Error: '%s' is still installed. Run aur-taw uninstall %s first.\n" "$package" "$name" >&2
        return 1
    fi
    awk -v name="$name" '$1 != name' "$CONFIG_FILE"
}

remove_repo() {
    if [[ $# -ne 1 ]] || ! _db_valid_name "$1"; then echo 'Usage: aur-taw remove <alias>' >&2; return 1; fi
    local name="$1" package
    package=$(awk -v name="$name" '$1 == name { print $4; exit }' "$CONFIG_FILE")
    if [[ "$name" == aur-taw || "$package" == aur-taw ]]; then
        if [[ "$VERSION" == *-dev* ]]; then
            echo "Error: aur-taw is a development build ($VERSION). Use sudo make uninstall from the source directory." >&2
        else
            echo 'Error: The aur-taw entry is required for self-updates and cannot be removed.' >&2
        fi
        return 1
    fi
    registry_transaction _db_remove_row "$name" || return 1
    printf 'Removed from memory: %s\n' "$name"
    if declare -F refresh_dependencies >/dev/null; then refresh_dependencies; fi
}

_db_table() {
    if command -v column >/dev/null 2>&1; then column -t -s '|'; else cat; fi
}

list_repos() {
    if [[ ! -s "$CONFIG_FILE" ]]; then echo 'No repositories added.'; return 0; fi
    echo "Saved repositories (run 'aur-taw check' to refresh latest versions):"
    local name url latest package origin installed snapshot
    local -a packages=()
    local -A db_installed=()
    snapshot=$(cat -- "$CONFIG_FILE") || return 1
    while read -r name url latest package origin; do
        [[ -n "$name" ]] && packages+=("$package")
    done <<< "$snapshot"
    _db_installed_versions db_installed "${packages[@]}"
    {
        echo 'ALIAS|PACKAGE|INSTALLED VERSION|LATEST AUR|ORIGIN|REPO LINK'
        while read -r name url latest package origin; do
            [[ -n "$name" ]] || continue
            installed=Not-installed
            if [[ "$package" == aur-taw && "$VERSION" == *-dev* ]]; then
                installed="$VERSION (Dev Build)"
            elif [[ -v db_installed["$package"] ]]; then
                installed="${db_installed["$package"]}"
            fi
            printf '%s|%s|%s|%s|%s|%s\n' "$name" "$package" "$installed" "${latest:-Unknown}" "$origin" "$url"
        done <<< "$snapshot"
    } | _db_table
}

_db_foreign_packages() {
    local output
    if output=$(pacman -Qmq 2>&1); then
        [[ -z "$output" ]] || printf '%s\n' "$output"
    elif [[ -n "$output" ]]; then
        printf 'Error: Cannot query installed foreign packages: %s\n' "$output" >&2
        return 1
    fi
    return 0
}

_db_import_is_managed() {
    awk -v package="$1" '$4 == package && ($5 == "imported" || $5 == "installed") {
        found=1; exit
    } END {exit !found}' "$CONFIG_FILE"
}

_db_import_row() {
    local package="$1" url="$2" latest="$3" row name alias_base a u v p origin suffix=1
    row=$(awk -v package="$package" '$4 == package { print; exit }' "$CONFIG_FILE")
    if [[ -n "$row" ]]; then
        read -r name _ _ _ origin <<< "$row"
        if [[ "$origin" == imported || "$origin" == installed ]]; then
            return 10
        fi
        while read -r a u v p origin; do
            [[ -n "$a" ]] || continue
            if [[ "$a" == "$name" ]]; then
                [[ "$u" != "$url" ]] || v="$latest"
                origin=imported
            fi
            printf '%s %s %s %s %s\n' "$a" "$u" "$v" "$p" "$origin"
        done < "$CONFIG_FILE"
        printf '  [IMPORTED] %s: existing alias %s, repository preserved.\n' "$package" "$name" >&2
        return 0
    fi
    alias_base="${package//@/_}"
    name="$alias_base"
    while awk -v name="$name" '$1 == name { found=1 } END { exit !found }' "$CONFIG_FILE"; do
        name="$alias_base-imported"
        [[ "$suffix" -eq 1 ]] || name+="-$suffix"
        suffix=$((suffix + 1))
    done
    cat "$CONFIG_FILE" || return 1
    printf '%s %s %s %s imported\n' "$name" "$url" "$latest" "$package"
    printf '  [IMPORTED] %s as %s -> %s\n' "$package" "$name" "$url" >&2
}

_db_import_from_metadata() {
    local package="$1" metadata="$2" base latest installed status
    _db_import_is_managed "$package" && return 10
    if ! installed=$(pacman -Q -- "$package" 2>/dev/null); then
        printf '  [NOT INSTALLED] %s: skipped.\n' "$package" >&2
        return 11
    fi
    if [[ -z "$metadata" ]]; then
        printf '  [NOT ON AUR] %s: foreign/local package or removed from AUR; skipped.\n' "$package" >&2
        return 12
    fi
    read -r base latest <<< "$metadata"
    installed="${installed#* }"
    printf '  %s | Installed: %s | Latest AUR: %s | Package base: %s\n' "$package" "$installed" "$latest" "$base"
    if registry_transaction _db_import_row "$package" "https://aur.archlinux.org/$base.git" "$latest"; then
        return 0
    else
        status=$?
        return "$status"
    fi
}

_db_import_from_json() {
    local metadata
    metadata=$(jq -r --arg name "$1" '.results[] | select(.Name == $name) | [.PackageBase, .Version] | @tsv' <<< "$2") || return 1
    _db_import_from_metadata "$1" "$metadata"
}

import_installed_package() {
    if [[ $# -ne 1 ]] || ! _db_valid_package "$1"; then echo 'Error: Invalid package name.' >&2; return 1; fi
    local json status
    if ! get_installed_pkg "$1" >/dev/null; then printf "Error: '%s' is not installed.\n" "$1" >&2; return 1; fi
    if _db_import_is_managed "$1"; then echo 'No new packages to import.'; return 0; fi
    if ! json=$(aur_info "$1"); then echo 'Error: AUR verification failed; package was not imported.' >&2; return 1; fi
    if _db_import_from_json "$1" "$json"; then status=0; else status=$?; fi
    [[ "$status" -eq 0 || "$status" -eq 10 ]] || return 1
    if [[ "$status" -eq 0 ]] && declare -F record_aur_dependencies >/dev/null; then record_aur_dependencies "$json" || return 1; fi
    if declare -F refresh_dependencies >/dev/null; then refresh_dependencies || return 1; fi
}

import_repos() {
    local automatic=0 scan=0 foreign json package response status name url latest origin base metadata
    local added=0 skipped=0 absent=0 failed=0
    local -a packages=() candidates=() imported_names=()
    local -A seen=() origins=() metadata_by_package=()
    if [[ "${1:-}" == --all ]]; then
        [[ $# -eq 1 ]] || { echo 'Usage: aur-taw import [--all | <package> ...]' >&2; return 1; }
        automatic=1
        shift
    elif [[ $# -gt 0 ]]; then
        automatic=1
        for package in "$@"; do
            _db_valid_package "$package" || { printf 'Error: Invalid package name: %s\n' "$package" >&2; return 1; }
            [[ -z "${seen[$package]:-}" ]] || continue
            packages+=("$package")
            seen[$package]=1
        done
    fi
    if [[ ${#packages[@]} -eq 0 ]]; then
        scan=1
        foreign=$(_db_foreign_packages) || return 1
        if [[ -z "$foreign" ]]; then echo 'No foreign packages found on the system.'; return 0; fi
        mapfile -t packages <<< "$foreign"
    fi
    while read -r name url latest package origin; do
        [[ -n "$name" ]] && origins["$package"]="$origin"
    done < "$CONFIG_FILE"
    for package in "${packages[@]}"; do
        case "${origins["$package"]:-}" in
            imported|installed) continue ;;
            tracked|bootstrap) ((scan)) && continue ;;
        esac
        candidates+=("$package")
    done
    packages=("${candidates[@]}")
    if [[ ${#packages[@]} -eq 0 ]]; then echo 'No new packages to import.'; return 0; fi
    printf 'Verifying %s installed package(s) with AUR...\n' "${#packages[@]}"
    if ! json=$(aur_info "${packages[@]}"); then
        echo 'Error: AUR verification failed; no packages were imported. Retry when the service is available.' >&2
        return 1
    fi
    metadata=$(jq -r '.results[] | [.Name, .PackageBase, .Version] | @tsv' <<< "$json") || return 1
    while IFS=$'\t' read -r package base latest; do
        [[ -n "$package" ]] || continue
        metadata_by_package["$package"]="$base"$'\t'"$latest"
    done <<< "$metadata"
    for package in "${packages[@]}"; do
        if ((!automatic)) && _db_import_is_managed "$package"; then continue; fi
        metadata="${metadata_by_package["$package"]:-}"
        if [[ "$automatic" -eq 0 && -n "$metadata" ]] && get_installed_pkg "$package" >/dev/null; then
            printf "Import '%s'? [y/N] " "$package"
            IFS= read -r response || response=""
            if [[ "$response" != y && "$response" != Y ]]; then
                printf '  [SKIPPED] %s: declined.\n' "$package"
                skipped=$((skipped + 1))
                continue
            fi
        fi
        if _db_import_from_metadata "$package" "$metadata"; then status=0; else status=$?; fi
        case "$status" in
            0) added=$((added + 1)); imported_names+=("$package") ;;
            10) continue ;;
            11|12) absent=$((absent + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done
    printf '\nImport summary: %s imported, %s skipped, %s unavailable, %s failed.\n' "$added" "$skipped" "$absent" "$failed"
    if [[ "$added" -gt 0 ]] && declare -F record_aur_dependencies >/dev/null; then
        local selected
        selected=$(jq --args '($ARGS.positional | INDEX(.)) as $names |
            {results: [.results[] | select($names[.Name] != null)]}' -- "${imported_names[@]}" <<< "$json") || return 1
        record_aur_dependencies "$selected" || return 1
    fi
    if declare -F refresh_dependencies >/dev/null; then refresh_dependencies || return 1; fi
    [[ "$failed" -eq 0 ]]
}

discover_repos() {
    [[ $# -eq 0 ]] || { echo 'Usage: aur-taw discover' >&2; return 1; }
    local foreign json package name origin status base installed url latest metadata verified=1
    local untracked=0 external=0 imported=0 installed_count=0 other=0 unknown=0
    local -a packages=()
    local -A aliases=() origins=() bases=() db_installed=()
    foreign=$(_db_foreign_packages) || return 1
    if [[ -z "$foreign" ]]; then echo 'No foreign packages found on the system.'; return 0; fi
    mapfile -t packages <<< "$foreign"
    if ! json=$(aur_info "${packages[@]}"); then
        verified=0
        json='{"results":[]}'
        echo 'Warning: AUR unavailable; membership cannot be verified. Local tracking status is still shown.' >&2
    fi
    while read -r name url latest package origin; do
        [[ -n "$name" ]] || continue
        aliases["$package"]="$name"
        origins["$package"]="$origin"
    done < "$CONFIG_FILE"
    metadata=$(jq -r '.results[] | [.Name, .PackageBase] | @tsv' <<< "$json") || return 1
    while IFS=$'\t' read -r package base; do
        [[ -n "$package" ]] && bases["$package"]="$base"
    done <<< "$metadata"
    _db_installed_versions db_installed "${packages[@]}"
    echo 'Installed foreign packages (read-only; provenance reflects recorded operations):'
    {
        echo 'PACKAGE|INSTALLED VERSION|AUR BASE|STATUS|ALIAS'
        for package in "${packages[@]}"; do
            name="${aliases["$package"]:--}"
            origin="${origins["$package"]:-}"
            base="${bases["$package"]:-}"
            case "$origin" in
                imported) status=IMPORTED; imported=$((imported + 1)) ;;
                installed) status=INSTALLED-BY-AUR-TAW; installed_count=$((installed_count + 1)) ;;
                added) status=ADDED-NOT-IMPORTED; external=$((external + 1)) ;;
                tracked|bootstrap) status=TRACKED-ORIGIN-UNKNOWN; unknown=$((unknown + 1)) ;;
                *) status=UNTRACKED; untracked=$((untracked + 1)) ;;
            esac
            if [[ "$verified" -eq 0 ]]; then
                base=Unverified
            elif [[ -z "$base" ]]; then
                base=Not-on-AUR
                status+='/LOCAL-OR-REMOVED'
                other=$((other + 1))
            fi
            installed="${db_installed["$package"]:-Unknown}"
            printf '%s|%s|%s|%s|%s\n' "$package" "$installed" "$base" "$status" "$name"
        done
        printf '\nSummary: %s untracked, %s added but not imported, %s imported, %s installed by aur-taw, %s unknown origin; %s not on AUR.\n' "$untracked" "$external" "$imported" "$installed_count" "$unknown" "$other"
    } | _db_table
    echo "Use 'aur-taw import <package>' or 'aur-taw import --all' to record installed AUR packages."
    [[ "$verified" -eq 1 ]]
}
