#!/bin/bash

safe_git() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git \
        -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        -c protocol.ext.allow=never -c protocol.file.allow=never "$@"
}

security_baseline_file() {
    local key
    key=$(printf '%s' "$1" | sha256sum) || return 1
    printf '%s/security/%s.json\n' "$CONFIG_DIR" "${key%% *}"
}

repo_package_names() {
    safe_git -C "$1" show HEAD:.SRCINFO 2>/dev/null |
        awk '$1 == "pkgname" && $2 == "=" && $3 ~ /^[a-zA-Z0-9_+@][a-zA-Z0-9@._+-]*$/ { print $3 }' |
        sort -u
}

security_scan_file() {
    local file="$1" label="$2" suspicious=0
    if LC_ALL=C grep -Eiq '(^|[^[:alnum:]_-])(atomic-lockfile|lockfile-js|nextfile-js)([^[:alnum:]_-]|$)' "$file"; then
        printf '  [!!!] %s: KNOWN AUR MALWARE CAMPAIGN NAME (atomic-lockfile / lockfile-js / nextfile-js).\n' "$label"
        printf '        Reject this build if this is an executable dependency or download.\n'
        suspicious=1
    fi
    if LC_ALL=C grep -Eiq '(curl|wget).*[|][[:space:]]*((/usr)?/bin/)?(ba|da|z|k)?sh|((ba|da|z|k)?sh)[[:space:]]+<[(].*(curl|wget)' "$file"; then
        printf '  [!] %s: downloads piped directly into a shell.\n' "$label"
        suspicious=1
    fi
    if LC_ALL=C grep -Eiq 'base64.*(-d|--decode)|eval[[:space:](]|xxd[[:space:]].*-r|python[^[:space:]]*[[:space:]]+-c|perl[[:space:]]+-e|openssl[[:space:]]+enc' "$file"; then
        printf '  [!] %s: encoded content, eval or inline interpreters; inspect carefully.\n' "$label"
        suspicious=1
    fi
    if LC_ALL=C grep -Eiq '(curl|wget)|https?://|npm[[:space:]]+(i|install|exec)|npx[[:space:]]|pip[[:space:]]+install|child_process|execSync|spawnSync' "$file"; then
        printf '  [!] %s: network/download or third-party execution references.\n' "$label"
        suspicious=1
    fi
    if LC_ALL=C grep -Eiq '(/etc/cron|crontab|systemctl|\.config/autostart|\.ssh/|/etc/shadow|/dev/tcp/|LD_PRELOAD|[[:space:]]sudo[[:space:]]|chmod[[:space:]]+([+]s|[2467][0-7]{3}))' "$file"; then
        printf '  [!] %s: persistence, privilege or credential-sensitive operations.\n' "$label"
        suspicious=1
    fi
    return "$suspicious"
}

security_review() {
    local repo="$1" url="$2" baseline previous='' previous_maintainer='' metadata maintainer='Unknown'
    local entry mode type object path size total=0 count=0 scan_dir blob status=0 answer
    baseline=$(security_baseline_file "$url") || return 1
    SECURITY_REVIEW_COMMIT=$(safe_git -C "$repo" rev-parse --verify HEAD) || return 1
    SECURITY_REVIEW_MAINTAINER='Unknown'
    if [[ -f "$baseline" ]]; then
        previous=$(jq -er '.commit | select(test("^[0-9a-f]{40,64}$"))' "$baseline" 2>/dev/null) || previous=''
        previous_maintainer=$(jq -r '.maintainer // "Unknown"' "$baseline" 2>/dev/null) || previous_maintainer=''
    fi
    printf '\n=== Security review: %s ===\n' "$url"
    printf 'Commit to build: %s\n' "$SECURITY_REVIEW_COMMIT"
    if metadata=$(aur_repo_info "$url" 2>/dev/null) && [[ $(jq '.results | length' <<< "$metadata") -gt 0 ]]; then
        maintainer=$(jq -r '.results[0].Maintainer // "ORPHANED"' <<< "$metadata")
        maintainer=$(printf '%s' "$maintainer" | LC_ALL=C tr -cd '[:alnum:]_.@+-')
        [[ -n "$maintainer" ]] || maintainer='Unknown'
        [[ "$maintainer" != 'ORPHANED' ]] || printf '  [!] This AUR package is currently ORPHANED.\n'
        if [[ -n "$previous_maintainer" && "$previous_maintainer" != "$maintainer" ]]; then
            printf '  [!] Maintainer changed since the last approved installation: %s -> %s\n' \
                "$(printf '%s' "$previous_maintainer" | LC_ALL=C tr -cd '[:alnum:]_.@+-')" "$maintainer"
        fi
    else
        printf '  [!] Cannot verify current AUR ownership; review with extra care.\n'
    fi
    SECURITY_REVIEW_MAINTAINER="$maintainer"
    printf 'Current maintainer: %s\n' "$maintainer"
    scan_dir=$(mktemp -d "$CACHE_DIR/security-review-XXXXXX") || return 1
    if ! safe_git -C "$repo" ls-tree -rlz HEAD > "$scan_dir/tree"; then
        rm -rf -- "$scan_dir"
        printf '[BLOCKED] Unable to enumerate every tracked Git file.\n'
        return 1
    fi
    while IFS= read -r -d '' entry; do
        read -r mode type object size <<< "${entry%%$'\t'*}"
        path=${entry#*$'\t'}
        if [[ "$mode" != 100644 && "$mode" != 100755 ]]; then
            printf '  [BLOCKED] Symlink, submodule or unsupported Git object: %q\n' "$path"
            status=1; break
        fi
        if [[ "$path" == *[$'\001'-$'\037'$'\177']* ]]; then
            printf '  [BLOCKED] Control characters in filename: %q\n' "$path"
            status=1; break
        fi
        [[ "$type" == blob && "$size" =~ ^[0-9]+$ ]] || { status=1; break; }
        total=$((total + size)); count=$((count + 1))
        if ((size > 2097152 || total > 8388608 || count > 1000)); then
            printf '  [BLOCKED] Repository exceeds review limits (2 MiB/file, 8 MiB total, 1000 files).\n'
            status=1; break
        fi
        blob="$scan_dir/$count"
        safe_git -C "$repo" cat-file blob "$object" > "$blob" || { status=1; break; }
        if [[ $(LC_ALL=C tr -cd '\000-\010\013\014\016-\037\177' < "$blob" | wc -c) -ne 0 ]]; then
            printf '  [BLOCKED] Binary or control-byte content: %q\n' "$path"
            status=1; break
        fi
        security_scan_file "$blob" "$path" || :
    done < "$scan_dir/tree"
    if [[ $status -ne 0 || $count -eq 0 ]] || ! safe_git -C "$repo" cat-file -e HEAD:PKGBUILD 2>/dev/null; then
        rm -rf -- "$scan_dir"
        printf 'Security review failed; no package code was executed.\n'
        return 1
    fi
    if [[ -n "$previous" ]] && safe_git -C "$repo" cat-file -e "$previous^{commit}" 2>/dev/null; then
        printf '\nDiff from the last successfully installed, approved commit (%s):\n' "$previous"
        if ! safe_git -C "$repo" --no-pager diff --text --no-ext-diff --no-textconv --no-renames \
            --src-prefix=before/ --dst-prefix=after/ "$previous" HEAD -- > "$scan_dir/diff"; then
            rm -rf -- "$scan_dir"
            printf '[BLOCKED] Unable to produce the security diff.\n'
            return 1
        fi
        LC_ALL=C cat -v "$scan_dir/diff"
        if [[ "$previous" == "$SECURITY_REVIEW_COMMIT" ]]; then
            printf '(No recipe changes; downloaded/upstream sources may still change.)\n'
        fi
    else
        printf '\nNo usable approved baseline. Review ALL tracked files:\n'
        count=0
        while IFS= read -r -d '' entry; do
            path=${entry#*$'\t'}; count=$((count + 1))
            printf '\n--- %s ---\n' "$path"
            LC_ALL=C cat -v "$scan_dir/$count"
            printf '\n'
        done < "$scan_dir/tree"
    fi
    rm -rf -- "$scan_dir"
    printf '\nThis static review is not a malware guarantee. PKGBUILD and .install hooks execute code;\n'
    printf 'downloaded sources and dependencies are outside this Git diff. Approval is required for every build.\n'
    if [[ ! -t 0 ]]; then
        printf '[BLOCKED] Security approval requires an interactive terminal; --all does not bypass it.\n'
        return 1
    fi
    read -r -p 'Type APPROVE to execute this reviewed package: ' answer || return 1
    if [[ "$answer" != 'APPROVE' ]]; then
        printf 'Build canceled; no package code was executed.\n'
        return 1
    fi
    security_verify_worktree "$repo"
}

security_verify_worktree() (
    local repo="$1" entry mode type object path actual untracked verify_dir index
    local -a paths=() objects=() hashes=()
    if ! actual=$(safe_git -C "$repo" rev-parse HEAD) || [[ "$actual" != "$SECURITY_REVIEW_COMMIT" ]] ||
        ! safe_git -C "$repo" diff --quiet HEAD -- ||
        ! untracked=$(safe_git -C "$repo" ls-files --others) || [[ -n "$untracked" ]]; then
        printf '[BLOCKED] Repository changed during review. Start the installation again.\n'
        return 1
    fi
    verify_dir=$(mktemp -d "$CACHE_DIR/security-verify-XXXXXXXX") || return 1
    trap 'rm -rf -- "$verify_dir"' EXIT
    safe_git -C "$repo" ls-tree -rz HEAD > "$verify_dir/tree" || return 1
    : > "$verify_dir/paths" || return 1
    while IFS= read -r -d '' entry; do
        read -r mode type object <<< "${entry%%$'\t'*}"
        path=${entry#*$'\t'}
        if [[ ( "$mode" != 100644 && "$mode" != 100755 ) || "$type" != blob ||
              "$path" == *[$'\001'-$'\037'$'\177']* || ! -f "$repo/$path" || -L "$repo/$path" ]]; then
            printf '[BLOCKED] Reviewed file is missing or no longer regular: %q\n' "$path"
            return 1
        fi
        paths+=("$path"); objects+=("$object")
        printf './%s\n' "$path" >> "$verify_dir/paths" || return 1
    done < "$verify_dir/tree"
    ((${#paths[@]})) || return 1
    safe_git -C "$repo" hash-object --no-filters --stdin-paths < "$verify_dir/paths" > "$verify_dir/hashes" || return 1
    mapfile -t hashes < "$verify_dir/hashes"
    [[ ${#hashes[@]} -eq ${#objects[@]} ]] || return 1
    for index in "${!objects[@]}"; do
        if [[ "${hashes[index]}" != "${objects[index]}" ]]; then
            printf '[BLOCKED] Checked-out bytes differ from the reviewed Git object: %q\n' "${paths[index]}"
            return 1
        fi
    done
)

security_record_success() {
    local url="$1" commit="$2" maintainer="$3" baseline content
    baseline=$(security_baseline_file "$url") || return 1
    mkdir -p -- "$CONFIG_DIR/security" || return 1
    content=$(jq -n --arg url "$url" --arg commit "$commit" --arg maintainer "$maintainer" \
        '{url:$url,commit:$commit,maintainer:$maintainer,installed_at:(now|floor)}') || return 1
    atomic_write_file "$baseline" <<< "$content"
}
