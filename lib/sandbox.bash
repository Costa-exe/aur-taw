#!/bin/bash

_sandbox_configure() {
    local state="$1" uid="$2" gid="$3" file
    mkdir -p "$state/etc/ssl/certs" "$state/home" "$state/empty" "$state/db" \
        "$state/var/lib/pacman" "$state/opt" "$state/inputs" || return 1
    printf 'root:x:0:0:root:/root:/usr/bin/nologin\nbuilder:x:%s:%s:builder:/home/builder:/bin/bash\n' "$uid" "$gid" > "$state/etc/passwd" || return 1
    printf 'root:x:0:\nbuilder:x:%s:\n' "$gid" > "$state/etc/group" || return 1
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' > "$state/etc/nsswitch.conf" || return 1
    printf '127.0.0.1 localhost\n::1 localhost\n' > "$state/etc/hosts" || return 1
    printf '[options]\nArchitecture = auto\nDBPath = /var/lib/pacman/\nSigLevel = Never\nLocalFileSigLevel = Never\n' > "$state/etc/pacman.conf" || return 1
    for file in makepkg.conf resolv.conf localtime os-release ld.so.cache; do
        [[ ! -f "/etc/$file" ]] || cp -L -- "/etc/$file" "$state/etc/$file" || return 1
    done
    [[ ! -d /etc/makepkg.conf.d ]] || cp -a -- /etc/makepkg.conf.d "$state/etc/" || return 1
    for file in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
        [[ ! -f "$file" ]] || cp -L -- "$file" "$state$file" || return 1
    done
    [[ -f "$state/etc/makepkg.conf" ]] || { printf 'Error: /etc/makepkg.conf is unavailable.\n' >&2; return 1; }
    cp -a -- /var/lib/pacman/local "$state/db/local" || return 1
}

_sandbox_arguments() {
    local state="$1" network="$2" stage_mode="${3:-0}" prefix base layer uid gid
    local -a sources=()
    uid=$(id -u) || return 1
    gid=$(id -g) || return 1
    SANDBOX_ARGS=(--unshare-all --unshare-user --disable-userns --die-with-parent --new-session
        --cap-drop ALL --clearenv --setenv PATH /usr/bin --setenv LANG C
        --setenv HOME /home/builder --setenv USER builder --setenv LOGNAME builder
        --setenv XDG_CONFIG_HOME /home/builder/.config
        --setenv XDG_CACHE_HOME /home/builder/.cache
        --setenv GNUPGHOME /home/builder/.gnupg
        --setenv GIT_CONFIG_NOSYSTEM 1 --setenv GIT_CONFIG_GLOBAL /dev/null
        --setenv TMPDIR /tmp --setenv PKGDEST /output
        --setenv SRCDEST /work --setenv SRCPKGDEST /output --setenv LOGDEST /work)
    [[ "$network" == 0 ]] || SANDBOX_ARGS+=(--share-net)
    if [[ "$stage_mode" == 0 ]]; then
        SANDBOX_ARGS+=(--uid "$uid" --gid "$gid")
    else
        SANDBOX_ARGS+=(--uid 0 --gid 0)
    fi
    for prefix in usr etc opt var; do
        case "$prefix" in
            usr) base=/usr ;;
            etc) base="$state/etc" ;;
            opt) base=/opt; [[ -d "$base" ]] || base="$state/opt" ;;
            var) base="$state/var" ;;
        esac
        sources=("$base")
        if [[ "$stage_mode" == 0 ]]; then
            for layer in "${SANDBOX_LAYERS[@]}"; do
                [[ ! -d "$layer/$prefix" ]] || sources+=("$layer/$prefix")
            done
        fi
        if [[ ${#sources[@]} -gt 1 ]]; then
            for layer in "${sources[@]}"; do SANDBOX_ARGS+=(--overlay-src "$layer"); done
            SANDBOX_ARGS+=(--ro-overlay "/$prefix")
        else
            SANDBOX_ARGS+=(--ro-bind "$base" "/$prefix")
        fi
    done
    SANDBOX_ARGS+=(--symlink usr/bin /bin --symlink usr/bin /sbin
        --symlink usr/lib /lib --symlink usr/lib /lib64
        --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run
        --dir /home --bind "$state/home" /home/builder --dir /root)
    if [[ "$stage_mode" == 0 ]]; then
        SANDBOX_ARGS+=(--ro-bind "$state/db" /var/lib/pacman)
    else
        SANDBOX_ARGS+=(--bind "$state/db" /var/lib/pacman)
    fi
}

_sandbox_stage_archive() {
    local state="$1" archive="$2" index="$3" layer prefix
    local -a SANDBOX_ARGS=()
    layer="$state/layer-$index"
    mkdir -p -- "$layer" || return 1
    cp --reflink=auto -- "$archive" "$state/inputs/$index.pkg" || return 1
    _sandbox_arguments "$state" 0 1 || return 1
    bwrap "${SANDBOX_ARGS[@]}" --ro-bind "$state/inputs/$index.pkg" /input.pkg \
        --bind "$layer" /stage --chdir /stage -- \
        /usr/bin/bsdtar -xf /input.pkg --no-same-owner --no-same-permissions || return 1
    for prefix in usr etc opt var; do
        if [[ -L "$layer/$prefix" || ( -e "$layer/$prefix" && ! -d "$layer/$prefix" ) ]]; then
            printf 'Error: staged package replaces a system directory (%s).\n' "$prefix" >&2
            return 1
        fi
    done
    bwrap "${SANDBOX_ARGS[@]}" --ro-bind "$state/inputs/$index.pkg" /input.pkg \
        --dir /staging-root --dir /empty-hooks -- \
        /usr/bin/pacman --config /etc/pacman.conf --root /staging-root \
        --dbpath /var/lib/pacman --logfile /dev/null --hookdir /empty-hooks \
        -U --dbonly -dd --noscriptlet --noconfirm -- /input.pkg || return 1
    SANDBOX_LAYERS+=("$layer")
}

_sandbox_public_keys() {
    local state="$1" srcinfo="$2" field separator fingerprint extra key_file
    local -a SANDBOX_ARGS=() import_files=()
    local -A exported=()
    [[ -f "$srcinfo" && ! -L "$srcinfo" ]] || {
        printf 'Error: committed .SRCINFO is required to select public verification keys.\n' >&2
        return 1
    }
    while read -r field separator fingerprint extra; do
        [[ "$field" == validpgpkeys ]] || continue
        if [[ "$separator" != = || -n "$extra" || ! "$fingerprint" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
            printf 'Error: invalid validpgpkeys fingerprint in approved .SRCINFO: %q\n' "$fingerprint" >&2
            return 1
        fi
        fingerprint=${fingerprint^^}
        [[ -z ${exported[$fingerprint]:-} ]] || continue
        command -v gpg >/dev/null || { printf 'Error: source signatures require gpg.\n' >&2; return 1; }
        mkdir -p -m 700 -- "$state/public-keys" "$state/home/.gnupg" || return 1
        key_file="$state/public-keys/$fingerprint.gpg"
        if ! gpg --no-options --batch --no-autostart --export-options export-minimal \
            --export "$fingerprint" > "$key_file" || [[ ! -s "$key_file" ]]; then
            printf 'Error: required public source-signing key %s is unavailable.\n' "$fingerprint" >&2
            printf 'Verify its full fingerprint, then import the trusted public key with gpg --import /path/to/key.asc and retry.\n' >&2
            return 1
        fi
        exported["$fingerprint"]=1
        import_files+=("/public-keys/$fingerprint.gpg")
    done < "$srcinfo"
    [[ ${#import_files[@]} -gt 0 ]] || return 0
    _sandbox_arguments "$state" 0 || return 1
    bwrap "${SANDBOX_ARGS[@]}" --ro-bind "$state/public-keys" /public-keys -- \
        /usr/bin/gpg --no-options --batch --no-autostart --import-options import-minimal \
        --import "${import_files[@]}" || {
        printf 'Error: cannot import public source-signing keys into the private build keyring.\n' >&2
        return 1
    }
}

sandbox_makepkg() (
    local repo="$1" output="$2" state archive index=0 uid gid command
    local -a SANDBOX_ARGS=() SANDBOX_LAYERS=()
    shift 2
    for command in bwrap bsdtar pacman makepkg fakeroot; do
        command -v "$command" >/dev/null || {
            printf 'Error: isolated builds require %s. Install it before retrying; no unsandboxed build will run.\n' "$command" >&2
            return 1
        }
    done
    uid=$(id -u) || return 1
    gid=$(id -g) || return 1
    [[ "$uid" != 0 ]] || { printf 'Error: run aur-taw builds as a regular user.\n' >&2; return 1; }
    [[ -d "$repo" && -d "$output" && ! -L "$repo" && ! -L "$output" ]] || return 1
    repo=$(realpath -e -- "$repo") || return 1
    output=$(realpath -e -- "$output") || return 1
    if [[ "$output" == "$repo" || "$output" == "$repo/"* ]]; then
        printf 'Error: isolated build output must be outside the recipe directory.\n' >&2
        return 1
    fi
    state=$(mktemp -d /tmp/aur-taw-sandbox-XXXXXX) || return 1
    trap 'rm -rf -- "$state"' EXIT
    _sandbox_configure "$state" "$uid" "$gid" || return 1
    for archive in "$@"; do
        [[ -f "$archive" && ! -L "$archive" ]] || { printf 'Error: invalid staged package archive.\n' >&2; return 1; }
        index=$((index + 1))
        _sandbox_stage_archive "$state" "$archive" "$index" || {
            printf 'Error: cannot prepare the isolated dependency environment.\n' >&2
            return 1
        }
    done
    _sandbox_arguments "$state" 0 || return 1
    if ! bwrap "${SANDBOX_ARGS[@]}" -- /usr/bin/true; then
        printf 'Error: bubblewrap isolation is unavailable (user namespaces/overlayfs required). No package code was executed.\n' >&2
        return 1
    fi
    _sandbox_public_keys "$state" "$repo/.SRCINFO" || return 1
    printf 'Fetching, verifying and preparing sources in an isolated environment...\n'
    _sandbox_arguments "$state" 1 || return 1
    bwrap "${SANDBOX_ARGS[@]}" --bind "$repo" /work --bind "$output" /output \
        --chdir /work -- /usr/bin/makepkg --nobuild --noconfirm || {
        printf 'Error: isolated source preparation failed. Missing official dependencies must be installed explicitly before retrying. No host packages were changed.\n' >&2
        return 1
    }
    printf 'Building offline in the isolated environment...\n'
    _sandbox_arguments "$state" 0 || return 1
    bwrap "${SANDBOX_ARGS[@]}" --bind "$repo" /work --bind "$output" /output \
        --chdir /work -- /usr/bin/makepkg --noextract --holdver --noconfirm || {
        printf 'Error: isolated build failed. Missing official dependencies must be installed explicitly before retrying.\n' >&2
        return 1
    }
)
