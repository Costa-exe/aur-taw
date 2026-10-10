#!/bin/bash

offer_import_installed() {
    local pkg="$1" answer
    printf "  [BLOCKED] '%s' is already installed on this computer. No installation will run.\n" "$pkg"
    if [[ -t 0 ]]; then
        read -r -p "Import '$pkg' into aur-taw? [y/N] " answer || return 0
        if [[ "$answer" == y || "$answer" == Y ]]; then
            import_installed_package "$pkg"
        fi
    else
        printf "  Run 'aur-taw import' to import installed packages.\n"
    fi
}

_record_built_packages() {
    local target_alias="$1" expected_url="$2" names="$3" alias_name url latest pkg origin candidate number
    local -A existing=() aliases=()
    if ! awk -v name="$target_alias" -v url="$expected_url" '$1==name && $2==url {found=1} END {exit !found}' "$CONFIG_FILE"; then
        printf 'Error: package was installed, but its registry entry changed during the build. Import it again.\n' >&2
        return 1
    fi
    while read -r alias_name url latest pkg origin; do
        [[ -n "$alias_name" ]] || continue
        existing["$pkg"]=1; aliases["$alias_name"]=1
        if [[ "$url" == "$expected_url" && " $names " == *" $pkg "* ]]; then origin=installed; fi
        printf '%s %s %s %s %s\n' "$alias_name" "$url" "$latest" "$pkg" "$origin"
    done < "$CONFIG_FILE"
    for pkg in $names; do
        [[ ${existing[$pkg]:-} ]] && continue
        candidate="${pkg//@/-}"; number=1
        [[ "$candidate" != -* ]] || candidate="pkg$candidate"
        while [[ ${aliases[$candidate]:-} ]]; do
            candidate="pkg-${pkg//@/-}-installed-$number"; number=$((number + 1))
        done
        aliases["$candidate"]=1
        printf '%s %s Unknown %s installed\n' "$candidate" "$expected_url" "$pkg"
    done
}

_delete_uninstalled_alias() {
    if ! awk -v name="$1" -v url="$2" -v pkg="$3" '$1==name && $2==url && $4==pkg {found=1} END {exit !found}' "$CONFIG_FILE"; then
        printf 'Error: registry entry changed during uninstall; leaving it intact.\n' >&2
        return 1
    fi
    if get_installed_pkg "$3" >/dev/null; then
        printf 'Error: package was reinstalled during uninstall; leaving its registry entry intact.\n' >&2
        return 1
    fi
    awk -v name="$1" '$1 != name' "$CONFIG_FILE"
}

_check_build_installed() {
    local upgrade="$1" historical="$2" expected_url="$3" name origin source blocked=0
    local entry_alias entry_url entry_latest entry_pkg entry_origin
    local -A sources=() origins=()
    shift 3
    while read -r entry_alias entry_url entry_latest entry_pkg entry_origin; do
        [[ -n "$entry_pkg" && -z "${sources[$entry_pkg]+present}" ]] || continue
        sources["$entry_pkg"]="$entry_url"
        origins["$entry_pkg"]="$entry_origin"
    done < "$CONFIG_FILE" || return 1
    for name in "$@"; do
        source="${sources[$name]:-}"
        if [[ -n "$source" && "${source%/}" != "${expected_url%/}" ]]; then
            printf '  [BLOCKED] %s belongs to another registered repository (%s).\n' "$name" "$source" >&2
            blocked=1
            continue
        fi
        if get_installed_pkg "$name" >/dev/null; then
            origin="${origins[$name]:-}"
            if [[ "$origin" != imported && "$origin" != installed ]]; then
                offer_import_installed "$name"; blocked=1
            elif [[ "$upgrade" == 0 && "$historical" == 0 ]]; then
                printf '  [BLOCKED] Split package %s is already installed; use --upgrade.\n' "$name"; blocked=1
            fi
        fi
    done
    [[ "$blocked" == 0 ]]
}

_build_one_repo() (
    local item="$1" upgrade="$2" batch="$3" alias_name url latest pkg origin commit='' row temp_dir
    local dependency_batch="${4:-0}" blocked_status=0
    local name current comparison makepkg_status log_file historical=0 archive actual_name
    local stage="${5:-}" own_stage=0 keep=0 base info identity actual_base actual_version digest outputs='[]' manifest
    local -a produced=() actual_names=() archives=() STAGED_ARCHIVES=() STAGED_MANIFESTS=()
    local -A output_names=()
    [[ "$dependency_batch" == 0 ]] || blocked_status=4
    alias_name="${item%@*}"
    [[ "$item" != *@* ]] || commit="${item#*@}"
    [[ -z "$commit" ]] || historical=1
    if [[ "$item" == *@* && ! "$commit" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
        printf 'Error: @commit must be a hexadecimal Git commit ID (7-64 characters).\n'; return 1
    fi
    row=$(awk -v name="$alias_name" '$1 == name {print; exit}' "$CONFIG_FILE")
    if [[ -z "$row" ]]; then
        if get_installed_pkg "$alias_name" >/dev/null; then
            offer_import_installed "$alias_name" || return 1
            return "$blocked_status"
        fi
        printf "Error: '%s' is not tracked; use 'aur-taw add' first.\n" "$alias_name"; return 1
    fi
    read -r alias_name url latest pkg origin <<< "$row"
    if _check_is_dev_package "$alias_name" "$url" "$pkg"; then
        printf '  [!] %s: skipped (running development build %s).\n' "$alias_name" "$VERSION"
        return 0
    fi
    if get_installed_pkg "$pkg" >/dev/null; then
        if [[ "$origin" != imported && "$origin" != installed ]]; then
            offer_import_installed "$pkg" || return 1
            return "$blocked_status"
        fi
        if [[ -z "$commit" && "$upgrade" == 0 ]]; then
            printf "  [i] %s: already installed; use --upgrade to update it.\n" "$alias_name"; return 0
        fi
        if [[ -z "$commit" ]]; then
            if [[ -z "$latest" || "$latest" == Unknown ]]; then
                printf "  [?] %s: remote version unknown; run 'aur-taw check' first.\n" "$alias_name"; return 1
            fi
            current=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')
            comparison=$(vercmp "$current" "$latest") || return 1
            if [[ "$comparison" -ge 0 ]]; then
                if [[ "$current" != "$latest" ]]; then
                    warn_version_mismatch "$alias_name" "$pkg" "$current" "$latest" "$comparison"
                else
                    printf '  [i] %s: already up to date (%s).\n' "$alias_name" "$current"
                fi
                return 0
            fi
        fi
    fi
    if [[ -z "$stage" ]]; then
        stage=$(mktemp -d "$CACHE_DIR/aur-taw-transaction-XXXXXXXX") || return 1
        own_stage=1
    fi
    temp_dir=$(mktemp -d "$stage/recipe-XXXXXXXX") || return 1
    trap 'if ((own_stage)); then rm -rf -- "$stage"; elif ((!keep)); then rm -rf -- "$temp_dir"; fi' EXIT
    printf '\n=== Preparing %s ===\n' "$alias_name"
    if ! safe_git clone --no-recurse-submodules --no-checkout -- "$url" "$temp_dir/repo"; then
        printf 'Error: Git clone failed.\n'; return 1
    fi
    if [[ -n "$commit" ]]; then
        commit=$(safe_git -C "$temp_dir/repo" rev-parse --verify "$commit^{commit}") || return 1
        printf 'Using historical recipe %s; VCS sources may still fetch newer upstream code.\n' "$commit"
    else
        commit=HEAD
    fi
    safe_git -C "$temp_dir/repo" checkout --detach "$commit" || return 1
    mapfile -t produced < <(repo_package_names "$temp_dir/repo")
    if [[ ${#produced[@]} -eq 0 || " ${produced[*]} " != *" $pkg "* ]]; then
        printf 'Error: committed .SRCINFO does not declare the tracked package (%s). No build executed.\n' "$pkg"
        return 1
    fi
    _check_build_installed "$upgrade" "$historical" "$url" "${produced[@]}" || return "$blocked_status"
    security_review "$temp_dir/repo" "$url" || return 1
    security_verify_worktree "$temp_dir/repo" || return 1
    _check_build_installed "$upgrade" "$historical" "$url" "${produced[@]}" || return "$blocked_status"
    safe_git -C "$temp_dir/repo" show HEAD:.SRCINFO > "$temp_dir/approved.SRCINFO" || return 1
    base=$(awk '$1 == "pkgbase" && $2 == "=" {print $3}' "$temp_dir/approved.SRCINFO")
    if [[ ! "$base" =~ ^[a-zA-Z0-9_+@][a-zA-Z0-9_.+@-]*$ ]]; then
        printf 'Error: invalid or ambiguous approved package base.\n' >&2; return 1
    fi
    mkdir -p -- "$temp_dir/packages" || return 1
    _build_collect_staged "$stage" || return 1
    printf '\nCompiling the approved recipe in isolation...\n'
    log_file="$temp_dir/makepkg.log"
    sandbox_makepkg "$temp_dir/repo" "$temp_dir/packages" "${STAGED_ARCHIVES[@]}" </dev/null 2>&1 |
        tee "$log_file" | LC_ALL=C cat -v
    makepkg_status=${PIPESTATUS[0]}
    if [[ "$makepkg_status" -ne 0 ]]; then
        printf 'Error: isolated build failed. No packages from this transaction were installed.\n'
        return "$makepkg_status"
    fi
    for archive in "$temp_dir/packages/"*; do
        [[ -e "$archive" || -L "$archive" ]] || continue
        [[ "$archive" != *.sig ]] || continue
        if [[ ! -f "$archive" || -L "$archive" ]]; then
            printf 'Error: unexpected or symlinked build artifact; nothing will be installed.\n'; return 1
        fi
        info=$(bsdtar -xOf "$archive" .PKGINFO) || { printf 'Error: cannot inspect built package metadata.\n'; return 1; }
        identity=$(awk '$2=="=" && ($1=="pkgname" || $1=="pkgbase" || $1=="pkgver") {value[$1]=$3; count[$1]++}
            END {
                if (count["pkgname"] != 1 || count["pkgbase"] != 1 || count["pkgver"] != 1) exit 1
                printf "%s\t%s\t%s\n", value["pkgname"], value["pkgbase"], value["pkgver"]
            }' <<< "$info") || { printf 'Error: missing or duplicate built package identity fields.\n'; return 1; }
        IFS=$'\t' read -r actual_name actual_base actual_version <<< "$identity"
        if [[ ! "$actual_name" =~ ^[a-zA-Z0-9_+@][a-zA-Z0-9_.+@-]*$ || "$actual_base" != "$base" ||
              -z "$actual_version" || "$actual_version" == *[[:space:][:cntrl:]]* || -n "${output_names[$actual_name]:-}" ]]; then
            printf 'Error: invalid, duplicate or unexpected built package identity/base.\n'; return 1
        fi
        if [[ " ${produced[*]} " != *" $actual_name "* && "$actual_name" != "$base-debug" ]]; then
            printf 'Error: output %s was not declared by the approved recipe; nothing will be installed.\n' "$actual_name"
            return 1
        fi
        if [[ $(pacman -Qpq -- "$archive") != "$actual_name" ]]; then
            printf 'Error: pacman disagrees with the inspected package identity.\n'; return 1
        fi
        output_names["$actual_name"]=1
        digest=$(sha256sum < "$archive") || return 1; digest="${digest%% *}"
        outputs=$(jq -cn --argjson previous "$outputs" --arg path "$archive" --arg name "$actual_name" \
            --arg version "$actual_version" --arg digest "$digest" \
            '$previous + [{path:$path,name:$name,version:$version,sha256:$digest}]') || return 1
        archives+=("$archive"); actual_names+=("$actual_name")
    done
    if [[ ${#archives[@]} -eq 0 || " ${actual_names[*]} " != *" $pkg "* ]]; then
        printf 'Error: build did not produce the requested package; nothing will be installed.\n'; return 1
    fi
    _check_build_installed "$upgrade" "$historical" "$url" "${actual_names[@]}" || return "$blocked_status"
    manifest=$(jq -n --arg alias "$alias_name" --arg url "$url" --arg package "$pkg" --arg base "$base" \
        --arg commit "$SECURITY_REVIEW_COMMIT" --arg maintainer "$SECURITY_REVIEW_MAINTAINER" \
        --arg srcinfo "$temp_dir/approved.SRCINFO" --argjson historical "$historical" --argjson archives "$outputs" \
        '{alias:$alias,url:$url,package:$package,base:$base,commit:$commit,maintainer:$maintainer,srcinfo:$srcinfo,historical:$historical,archives:$archives}') || return 1
    atomic_write_file "$temp_dir/ready.json" <<< "$manifest" || return 1
    keep=1
    printf 'Prepared: %s. Installation waits for the complete transaction.\n' "${actual_names[*]}"
    if ((own_stage)); then _build_install_staged "$stage" "$upgrade" "$batch"; fi

)

_build_validate_manifest() {
    local manifest="$1" recipe_dir data srcinfo
    recipe_dir="${manifest%/*}"
    [[ "$recipe_dir" != "$manifest" ]] || recipe_dir=.
    if [[ ! -f "$manifest" || -L "$manifest" || -L "$recipe_dir" || -L "$recipe_dir/packages" ]]; then
        printf 'Error: missing or unsafe staged manifest.\n' >&2; return 1
    fi
    if ! data=$(jq -ce --arg directory "$recipe_dir" '
        def package_name: type == "string" and test("^[a-zA-Z0-9_+@][a-zA-Z0-9_.+@-]*$");
        def clean_path: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
        select(type == "object" and
            (.alias | type == "string" and test("^[a-zA-Z0-9_+][a-zA-Z0-9_.+-]*$")) and
            (.url | type == "string" and test("^https?://[^[:space:][:cntrl:]]+$")) and
            (.package | package_name) and (.base | package_name) and
            (.commit | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
            (.maintainer | type == "string" and test("^[a-zA-Z0-9_.@+-]+$")) and
            (.srcinfo | clean_path) and (.srcinfo == $directory + "/approved.SRCINFO") and
            (.historical == 0 or .historical == 1) and
            (.archives | type == "array" and length > 0) and
            all(.archives[];
                (.path | clean_path) and
                (.path | startswith($directory + "/packages/")) and
                (.path | ltrimstr($directory + "/packages/") | length > 0 and (contains("/") | not)) and
                (.name | package_name) and
                (.version | type == "string" and test("^[^[:space:][:cntrl:]]+$")) and
                (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
            ((.archives | length) == (.archives | unique_by(.name) | length)) and
            (.package as $package | any(.archives[]; .name == $package)))
    ' "$manifest"); then
        printf 'Error: invalid staged manifest.\n' >&2; return 1
    fi
    srcinfo="$recipe_dir/approved.SRCINFO"
    if [[ ! -f "$srcinfo" || -L "$srcinfo" ]]; then
        printf 'Error: staged recipe metadata is missing or outside its recipe directory.\n' >&2; return 1
    fi
    printf '%s\n' "$data"
}

_build_collect_staged() {
    local stage="$1" manifest path name digest actual data rows
    local -A seen=()
    STAGED_ARCHIVES=()
    STAGED_MANIFESTS=()
    for manifest in "$stage"/recipe-*/ready.json; do
        [[ -e "$manifest" || -L "$manifest" ]] || continue
        data=$(_build_validate_manifest "$manifest") || return 1
        STAGED_MANIFESTS+=("$data")
        rows=$(jq -er '.archives[] | [.path,.name,.sha256] | join("\t")' <<< "$data") || return 1
        while IFS=$'\t' read -r path name digest; do
            [[ -n "$path" && -f "$path" && ! -L "$path" && -z "${seen[$name]:-}" ]] || {
                printf 'Error: missing, duplicate or unsafe staged archive.\n' >&2; return 1;
            }
            actual=$(sha256sum < "$path") || return 1
            [[ "${actual%% *}" == "$digest" ]] || { printf 'Error: staged archive changed after inspection.\n' >&2; return 1; }
            seen["$name"]=1; STAGED_ARCHIVES+=("$path")
        done <<< "$rows"
    done
}

_build_install_staged() {
    local stage="$1" upgrade="$2" batch="$3" alias_name url pkg historical row name version
    local data rows commit maintainer srcinfo
    local -a STAGED_ARCHIVES=() STAGED_MANIFESTS=() names=() pacman_flags=()
    _build_collect_staged "$stage" || return 1
    ((${#STAGED_ARCHIVES[@]})) || return 0
    for data in "${STAGED_MANIFESTS[@]}"; do
        rows=$(jq -er '[.alias,.url,.package,(.historical|tostring)] | join("\t")' <<< "$data") || return 1
        IFS=$'\t' read -r alias_name url pkg historical <<< "$rows" || return 1
        row=$(awk -v a="$alias_name" '$1==a {print $2 " " $4}' "$CONFIG_FILE") || return 1
        if [[ "$row" != "$url $pkg" ]]; then
            printf 'Error: registry entry %s changed while preparing the transaction. Nothing installed.\n' "$alias_name" >&2
            return 1
        fi
        rows=$(jq -er '.archives[].name' <<< "$data") || return 1
        mapfile -t names <<< "$rows"
        _check_build_installed "$upgrade" "$historical" "$url" "${names[@]}" || return 1
    done
    [[ "$batch" == 0 ]] || pacman_flags+=(--noconfirm)
    printf '\nInstalling %s verified package archive(s) in one transaction...\n' "${#STAGED_ARCHIVES[@]}"
    sudo pacman -U "${pacman_flags[@]}" -- "${STAGED_ARCHIVES[@]}" || {
        printf 'Error: package transaction failed. Approved baselines were not advanced.\n' >&2; return 1;
    }
    for data in "${STAGED_MANIFESTS[@]}"; do
        rows=$(jq -er '.archives[] | [.name,.version] | join("\t")' <<< "$data") || return 1
        while IFS=$'\t' read -r name version; do
            if [[ $(pacman -Q -- "$name" 2>/dev/null) != "$name $version" ]]; then
                printf 'Error: installed version of %s differs from the prepared package. Baselines unchanged.\n' "$name" >&2
                return 1
            fi
        done <<< "$rows"
    done
    for data in "${STAGED_MANIFESTS[@]}"; do
        rows=$(jq -er '[.alias,.url,.commit,.maintainer,.srcinfo] | join("\t")' <<< "$data") || return 1
        IFS=$'\t' read -r alias_name url commit maintainer srcinfo <<< "$rows" || return 1
        rows=$(jq -er '.archives[].name' <<< "$data") || return 1
        mapfile -t names <<< "$rows"
        registry_transaction _record_built_packages "$alias_name" "$url" "${names[*]}" || return 1
        security_record_success "$url" "$commit" "$maintainer" || return 1
        record_srcinfo_dependencies "$srcinfo" || return 1
    done
    refresh_dependencies || return 1
    printf 'Success: all prepared packages installed.\n'
}

install_repos() (
    local upgrade=0 batch=0 arg build_lock_fd answer ordered=0 stage manifest url pkg row key commit
    local -a items=()
    local -A requested_commits=()
    for arg in "$@"; do
        case "$arg" in
            --upgrade) upgrade=1 ;;
            --all) batch=1 ;;
            --*) printf 'Error: unknown install option: %s\n' "$arg"; return 1 ;;
            *) items+=("$arg") ;;
        esac
    done
    if [[ "$batch" == 1 ]]; then
        [[ ${#items[@]} -eq 0 ]] || { printf 'Error: use aliases OR --all.\n'; return 1; }
        mapfile -t items < <(awk '{print $1}' "$CONFIG_FILE")
    fi
    [[ ${#items[@]} -gt 0 ]] || { printf 'Error: provide an alias or --all.\n'; return 1; }
    [[ ! -f /var/lib/pacman/db.lck ]] || { printf 'Error: pacman is locked.\n'; return 1; }
    exec {build_lock_fd}>"$CONFIG_DIR/build.lock" || return 1
    flock -n "$build_lock_fd" || { printf 'Error: another aur-taw install/uninstall is running.\n'; return 1; }
    for arg in "${items[@]}"; do
        url=$(awk -v a="${arg%@*}" '$1==a {print $2}' "$CONFIG_FILE")
        [[ -n "$url" ]] || continue
        commit=''; [[ "$arg" != *@* ]] || commit="${arg#*@}"
        if [[ -n "${requested_commits[$url]+present}" && "${requested_commits[$url]}" != "$commit" ]]; then
            printf 'Error: conflicting commits requested for the same repository.\n'; return 1
        fi
        requested_commits["$url"]="$commit"
    done
    if ((upgrade && ${#items[@]} > 1)); then
        plan_upgrade_order "${items[@]}" || return 1
        items=("${UPGRADE_ORDER[@]}"); ordered=1
        printf 'Upgrade order (dependencies first): %s\n' "${items[*]}"
    fi
    if [[ "$batch" == 1 ]]; then
        if ((!ordered)); then printf 'Packages to process: %s\n' "${items[*]}"; fi
        printf 'Each recipe requires security approval. Installation occurs only after every build succeeds.\n'
        if [[ ! -t 0 ]] || ! read -r -p 'Proceed with batch processing? [y/N] ' answer || [[ "$answer" != y && "$answer" != Y ]]; then
            printf 'Batch canceled.\n'; return 1
        fi
    fi
    stage=$(mktemp -d "$CACHE_DIR/aur-taw-transaction-XXXXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    for arg in "${items[@]}"; do
        row=$(awk -v a="${arg%@*}" '$1==a {print $2 " " $4}' "$CONFIG_FILE")
        read -r url pkg <<< "$row"
        key=''
        for manifest in "$stage"/recipe-*/ready.json; do
            [[ -f "$manifest" ]] || continue
            if jq -e --arg url "$url" --arg pkg "$pkg" '.url==$url and any(.archives[]; .name==$pkg)' "$manifest" >/dev/null; then
                key=prepared; break
            fi
        done
        [[ -z "$key" ]] || { printf '  [i] %s: already prepared by its split recipe.\n' "$arg"; continue; }
        if ! _build_one_repo "$arg" "$upgrade" "$batch" 1 "$stage"; then
            printf 'Transaction canceled: no prepared packages were installed.\n' >&2
            return 1
        fi
    done
    _build_install_staged "$stage" "$upgrade" "$batch"
)

uninstall_pkg() (
    local alias_name="${1:-}" row url latest pkg origin installed_name answer build_lock_fd
    [[ $# -eq 1 && -n "$alias_name" ]] || { printf 'Usage: aur-taw uninstall <alias>\n'; return 1; }
    row=$(awk -v name="$alias_name" '$1 == name {print; exit}' "$CONFIG_FILE")
    if [[ -n "$row" ]]; then
        read -r alias_name url latest pkg origin <<< "$row"
    else
        pkg="$alias_name"
    fi
    if _check_is_dev_package "$alias_name" "${url:-}" "$pkg"; then
        printf 'Development build %s: use sudo make uninstall from the source directory.\n' "$VERSION"; return 1
    fi
    installed_name=$(get_installed_pkg "$pkg") || { printf 'Package %s is not installed.\n' "$pkg"; return 1; }
    [[ ! -f /var/lib/pacman/db.lck ]] || { printf 'Error: pacman is locked.\n'; return 1; }
    exec {build_lock_fd}>"$CONFIG_DIR/build.lock" || return 1
    flock -n "$build_lock_fd" || { printf 'Error: another aur-taw install/uninstall is running.\n'; return 1; }
    if [[ "$pkg" == aur-taw ]]; then
        printf 'Uninstalling aur-taw leaves your other AUR packages and local registry intact.\n'
        read -r -p 'Uninstall aur-taw? [y/N] ' answer || return 1
        [[ "$answer" == y || "$answer" == Y ]] || return 0
    fi
    sudo pacman -Rns -- "$installed_name" || return 1
    if get_installed_pkg "$pkg" >/dev/null; then printf 'Error: package remains installed.\n'; return 1; fi
    printf 'Uninstalled: %s\n' "$pkg"
    if [[ -n "$row" && "$pkg" != aur-taw && -t 0 ]]; then
        read -r -p "Remove '$alias_name' from the registry too? [y/N] " answer || answer=n
        if [[ "$answer" == y || "$answer" == Y ]]; then registry_transaction _delete_uninstalled_alias "$alias_name" "$url" "$pkg" || return 1; fi
    fi
    refresh_dependencies
)
