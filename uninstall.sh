#!/bin/sh
# The Cube uninstaller for Linux and macOS (sub-spec c01/016; KB note 13,
# P14).
#
#   curl -fsSL https://happonomyorg.github.io/cube-releases/uninstall.sh | sh
#   curl -fsSL https://happonomyorg.github.io/cube-releases/uninstall.sh | sh -s -- [--dry-run] [--find <folder>]... [<kb>]...
#
# It removes what install.sh and `cube setup` put on this machine for your
# account, and nothing else, in this order:
#
#   1. in each knowledge base it is pointed at -- the git repository it runs
#      in, every <kb> given, and every repository found under a --find
#      folder -- the hooks `cube setup` turned on: core.hooksPath when it is
#      .cube/hooks, and then merge.ff when it is false. This comes first: a KB
#      still hooked once cube is gone stops every commit. The KB's own files
#      (.cube/ and .claude/skills/cube/, committed by `cube adopt`) stay; the
#      uninstaller names them;
#   2. the global git settings `cube setup` writes: cube.path, cube.gitPath,
#      cube.ghPath and cube.python3Path, and cube.allowUserOwned (your
#      opt-in);
#   3. the commands and the programs (sub-spec c01/032): each command in the
#      install folder (cube, cube-index, cube-graph, and any other cube-*)
#      that is a link into The Cube's versions folder, the switch install.sh
#      makes; a link to anywhere else stays (another program's); every
#      version folder in ${XDG_DATA_HOME:-~/.local/share}/cube/versions; the
#      binaries of a 0.1.0 install (cube, cube-index and cube-graph in the
#      install folder itself), each only when it reports its own name and a
#      version (another program of the same name stays); and what an
#      interrupted install left: .cube-new.*, .cube-old.* and .cube-install.*
#      in the install folder, beside it and in the versions folder;
#   4. the hook cache: ${XDG_CACHE_HOME:-~/.cache}/cube on Linux,
#      ~/Library/Caches/org.Happonomy.cube on macOS.
#
# It never follows a symbolic link: a link is removed itself or left as it
# is. --dry-run prints every step and changes nothing. It refuses to run as
# root through sudo, as the installer does.
#
# Environment:
#   CUBE_INSTALL_DIR   where the commands are (default: $HOME/.local/bin)
#   XDG_DATA_HOME      holds cube/versions/ (default: $HOME/.local/share)
set -eu

DRY_RUN=0
KBS=''
FIND_DIRS=''
SEEN=''
DONE=0
UNHOOKED=0
CUBE_PATH_SET=0
NL='
'

say() {
    printf 'uninstall.sh: %s\n' "$*"
}

warn() {
    printf 'uninstall.sh: warning: %s\n' "$*" >&2
}

die() {
    printf 'uninstall.sh: error: %s\n' "$*" >&2
    exit 1
}

has() {
    command -v "$1" >/dev/null 2>&1
}

usage() {
    cat <<'EOF'
usage: uninstall.sh [--dry-run] [--find <folder>]... [<kb>]...

Removes The Cube from this account: the hooks `cube setup` turned on in the
knowledge bases it is pointed at (the git repository it runs in, each <kb>,
each repository under a --find folder), the global git settings cube setup
wrote, the commands cube, cube-index and cube-graph, every installed version
and the hook cache. The files of a knowledge base stay. --dry-run changes
nothing.
EOF
}

# act <description> <command>...: prints the step, then runs it (or, with
# --dry-run, only prints what it would do).
act() {
    description=$1
    shift
    DONE=$((DONE + 1))
    if [ "$DRY_RUN" = 1 ]; then
        say "would $description"
        return 0
    fi
    say "$description"
    "$@" || die "could not $description"
}

# unhook <folder> <quiet>: undoes cube setup in the git repository that holds
# <folder>. With quiet=1 (a repository it found or runs in) it says nothing
# about a repository that is not hooked.
unhook() {
    if ! top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
        [ "$2" = 1 ] || warn "$1 is not in a git repository: nothing to unhook there"
        return 0
    fi
    case "$SEEN$NL" in
        *"$NL$top$NL"*) return 0 ;;
    esac
    SEEN="$SEEN$NL$top"
    hooks=$(git -C "$top" config --local --get core.hooksPath 2>/dev/null) || hooks=''
    if [ "$hooks" != .cube/hooks ]; then
        [ "$2" = 1 ] || say "$top is not hooked by cube setup (core.hooksPath: ${hooks:-not set}); left as it is"
        return 0
    fi
    act "unhook $top: unset core.hooksPath (.cube/hooks)" \
        git -C "$top" config --local --unset-all core.hooksPath
    ff=$(git -C "$top" config --local --get merge.ff 2>/dev/null) || ff=''
    if [ "$ff" = false ]; then
        act "unhook $top: unset merge.ff (false, as cube setup sets it)" \
            git -C "$top" config --local --unset-all merge.ff
    fi
    UNHOOKED=$((UNHOOKED + 1))
    kept=''
    if [ -d "$top/.cube" ]; then
        kept='.cube/'
    fi
    if [ -d "$top/.claude/skills/cube" ]; then
        kept="${kept:+$kept and }.claude/skills/cube/"
    fi
    if [ -n "$kept" ]; then
        say "$top keeps $kept: the knowledge base's own committed files; remove them with a commit if you no longer want them"
    fi
}

# A version folder's name, as install.sh writes it: no path separator and no
# leading dot.
is_version_name() {
    case "$1" in
        '' | .* | *[!0-9A-Za-z.+-]*) return 1 ;;
    esac
    return 0
}

# The folder of the version folders, read as install.sh reads it: a relative
# XDG_DATA_HOME is ignored, as the XDG Base Directory specification says.
versions_dir() {
    data=${XDG_DATA_HOME:-}
    case "$data" in
        /*) ;;
        *) data="$HOME/.local/share" ;;
    esac
    VERSIONS="${data%/}/cube/versions"
}

# into_versions <target>: whether a link's target is a file in one of The
# Cube's version folders, <versions>/<version>/<program>, as install.sh
# writes its links.
into_versions() {
    case "$1" in
        "$VERSIONS"/*/*) ;;
        *) return 1 ;;
    esac
    rest=${1#"$VERSIONS"/}
    version=${rest%%/*}
    program=${rest#*/}
    case "$program" in
        '' | */*) return 1 ;;
    esac
    is_version_name "$version"
}

# remove_leftovers <folder>: what an interrupted install left in <folder>,
# its names starting .cube-new., .cube-old. or .cube-install. A link is
# removed itself, never what it points to.
remove_leftovers() {
    for left in "$1"/.cube-new.* "$1"/.cube-old.* "$1"/.cube-install.*; do
        if [ -L "$left" ] || [ -f "$left" ]; then
            act "remove $left (left by an interrupted install)" rm -f -- "$left"
        elif [ -d "$left" ]; then
            act "remove $left (left by an interrupted install)" rm -rf -- "$left"
        fi
    done
}

# Everything runs from main, called on the last line, so a download cut
# short runs nothing.
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --find)
                [ $# -ge 2 ] || die "--find needs a folder"
                FIND_DIRS="$FIND_DIRS$2$NL"
                shift
                ;;
            --find=*) FIND_DIRS="$FIND_DIRS${1#--find=}$NL" ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) die "unknown option $1 (see --help)" ;;
            *) KBS="$KBS$1$NL" ;;
        esac
        shift
    done

    if [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
        die "run the uninstaller as yourself, without sudo: The Cube is installed for your own account"
    fi
    [ -n "${HOME:-}" ] || die "HOME is not set"
    for tool in id dirname uname rm rmdir readlink find; do
        has "$tool" || die "this uninstaller needs '$tool', which is not on PATH"
    done
    if [ "$DRY_RUN" = 1 ]; then
        say "dry run: nothing is changed"
    fi

    # 1. The knowledge bases cube setup hooked.
    if has git; then
        unhook "$PWD" 1
        while IFS= read -r kb; do
            [ -n "$kb" ] || continue
            unhook "$kb" 0
        done <<EOF
$KBS
EOF
        while IFS= read -r folder; do
            [ -n "$folder" ] || continue
            if [ ! -d "$folder" ]; then
                warn "$folder is not a folder: not searched"
                continue
            fi
            say "searching $folder for knowledge bases cube setup hooked"
            found=$(find "$folder" -name .cube -type d -prune -print 2>/dev/null) || true
            while IFS= read -r dot_cube; do
                [ -n "$dot_cube" ] || continue
                unhook "${dot_cube%/.cube}" 1
            done <<EOF
$found
EOF
        done <<EOF
$FIND_DIRS
EOF
    else
        if [ -n "$KBS$FIND_DIRS" ]; then
            warn "git is not on PATH, so no knowledge base can be unhooked"
        fi
    fi

    # 2. The global git settings cube setup wrote.
    if has git; then
        for key in cube.path cube.gitPath cube.ghPath cube.python3Path cube.allowUserOwned; do
            if values=$(git config --global --get-all "$key" 2>/dev/null); then
                if [ "$key" = cube.path ]; then
                    CUBE_PATH_SET=1
                fi
                shown=$(printf '%s' "$values" | tr '\n' ' ')
                act "remove $key from your global git config (${shown% })" \
                    git config --global --unset-all "$key"
            fi
        done
        if [ "$DRY_RUN" = 0 ] && ! git config --global --get-regexp '^cube\.' >/dev/null 2>&1; then
            git config --global --remove-section cube >/dev/null 2>&1 || true
        fi
        if system=$(git config --system --get-all cube.path 2>/dev/null); then
            warn "cube.path is also set in the system git config ($system); an administrator removes it with: sudo git config --system --unset-all cube.path"
        fi
    fi

    # 3. The commands, the version folders, a 0.1.0 install and what an
    # interrupted install left.
    dir=${CUBE_INSTALL_DIR:-$HOME/.local/bin}
    case "$dir" in
        /*) ;;
        *) die "CUBE_INSTALL_DIR must be an absolute path, not '$dir'" ;;
    esac
    while [ "$dir" != / ] && [ "${dir%/}" != "$dir" ]; do
        dir=${dir%/}
    done
    [ "$dir" != / ] || die "CUBE_INSTALL_DIR must not be /"
    versions_dir
    # The commands first, so none is left pointing at a removed folder: a
    # link into the versions folder is the switch install.sh made; the
    # binaries themselves in the install folder are a 0.1.0 install.
    for file in "$dir"/cube "$dir"/cube-*; do
        name=${file##*/}
        if [ -L "$file" ]; then
            target=$(readlink "$file") || target=''
            if into_versions "$target"; then
                act "remove the command $file (a link to $target)" rm -f -- "$file"
            else
                case "$name" in
                    cube | cube-index | cube-graph)
                        warn "$file is a link to ${target:-a target it cannot read}, not into The Cube's versions folder $VERSIONS; it may be another program's, so it stays"
                        ;;
                esac
            fi
            continue
        fi
        case "$name" in
            cube | cube-index | cube-graph) ;;
            *) continue ;;
        esac
        [ -f "$file" ] || continue
        reported=$("$file" --version 2>/dev/null | head -n 1) || reported=''
        case "$reported" in
            "$name "[0-9]*) act "remove $file ($reported)" rm -f -- "$file" ;;
            *) warn "$file does not report '$name <version>' (it reports: ${reported:-nothing}); it may be another program, so it stays" ;;
        esac
    done
    remove_leftovers "$dir"
    parent=$(dirname "$dir")
    remove_leftovers "$parent"
    holder=$(dirname "$VERSIONS")
    if [ -L "$holder" ]; then
        warn "$holder is a symbolic link, which the installer never makes; it stays, and so does what it points to"
    elif [ -L "$VERSIONS" ]; then
        warn "$VERSIONS is a symbolic link, which the installer never makes; it stays, and so does what it points to"
    elif [ -d "$VERSIONS" ]; then
        for version in "$VERSIONS"/*; do
            if [ -L "$version" ]; then
                warn "$version is a symbolic link, which the installer never makes; it stays"
            elif [ -d "$version" ] && is_version_name "${version##*/}"; then
                act "remove cube ${version##*/} ($version)" rm -rf -- "$version"
            fi
        done
        remove_leftovers "$VERSIONS"
        if [ "$DRY_RUN" = 0 ]; then
            rmdir "$VERSIONS" 2>/dev/null || say "$VERSIONS still holds other files, so the folder stays"
            if [ ! -e "$VERSIONS" ]; then
                rmdir "$holder" 2>/dev/null || true
            fi
        fi
    fi

    # 4. The hook cache.
    if [ "$(uname -s)" = Darwin ]; then
        cache="$HOME/Library/Caches/org.Happonomy.cube"
    else
        base=${XDG_CACHE_HOME:-}
        case "$base" in
            /*) ;;
            *) base="$HOME/.cache" ;;
        esac
        cache="${base%/}/cube"
    fi
    if [ -L "$cache" ]; then
        warn "$cache is a symbolic link, which cube never makes; it stays"
    elif [ -d "$cache" ]; then
        act "remove the hook cache $cache" rm -rf -- "$cache"
    fi

    # What is left to you.
    if [ "$CUBE_PATH_SET" = 1 ]; then
        if [ "$UNHOOKED" = 0 ]; then
            warn "cube setup ran on this account (cube.path was set), but no knowledge base was unhooked: one still hooked stops every commit. In each knowledge base where you ran cube setup, run: git config --unset core.hooksPath && git config --unset merge.ff (or run this uninstaller again there, or with --find <folder>)"
        else
            say "if you ran cube setup in other knowledge bases too, unhook each: git config --unset core.hooksPath && git config --unset merge.ff (or run this uninstaller with --find <folder>)"
        fi
    fi
    case ":${PATH:-}:" in
        *":$dir:"*)
            if [ "$dir" = "$HOME/.local/bin" ]; then
                :
            else
                say "$dir is still on your PATH; remove it from your shell's startup file if you added it for The Cube"
            fi
            ;;
    esac
    if [ "$DONE" = 0 ]; then
        say "nothing of The Cube was found for this account"
    elif [ "$DRY_RUN" = 1 ]; then
        say "dry run done: $DONE step(s) would run; run it again without --dry-run to do them"
    else
        say "The Cube is removed ($DONE step(s))"
    fi
}

main "$@"
