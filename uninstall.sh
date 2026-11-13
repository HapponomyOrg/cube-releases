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
#   3. cube, cube-index and cube-graph in the install folder, each only when
#      it reports its own name and a version (another program of the same
#      name stays), and what an interrupted install left: .cube-new.* in the
#      install folder and .cube-install.* beside it;
#   4. the hook cache: ${XDG_CACHE_HOME:-~/.cache}/cube on Linux,
#      ~/Library/Caches/org.Happonomy.cube on macOS.
#
# --dry-run prints every step and changes nothing. It refuses to run as root
# through sudo, as the installer does.
#
# Environment:
#   CUBE_INSTALL_DIR   where the binaries are (default: $HOME/.local/bin)
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
wrote, cube, cube-index and cube-graph, and the hook cache. The files of a
knowledge base stay. --dry-run changes nothing.
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
for tool in id dirname uname rm find; do
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

# 3. The binaries and what an interrupted install left.
dir=${CUBE_INSTALL_DIR:-$HOME/.local/bin}
case "$dir" in
    /*) ;;
    *) die "CUBE_INSTALL_DIR must be an absolute path, not '$dir'" ;;
esac
while [ "$dir" != / ] && [ "${dir%/}" != "$dir" ]; do
    dir=${dir%/}
done
[ "$dir" != / ] || die "CUBE_INSTALL_DIR must not be /"
for name in cube cube-index cube-graph; do
    file="$dir/$name"
    if [ -L "$file" ]; then
        warn "$file is a symbolic link, which the installer never writes; it stays"
        continue
    fi
    [ -f "$file" ] || continue
    reported=$("$file" --version 2>/dev/null | head -n 1) || reported=''
    case "$reported" in
        "$name "[0-9]*) act "remove $file ($reported)" rm -f -- "$file" ;;
        *) warn "$file does not report '$name <version>' (it reports: ${reported:-nothing}); it may be another program, so it stays" ;;
    esac
done
for leftover in "$dir"/.cube-new.*; do
    if [ -f "$leftover" ] && [ ! -L "$leftover" ]; then
        act "remove $leftover (left by an interrupted install)" rm -f -- "$leftover"
    fi
done
parent=$(dirname "$dir")
for stage in "$parent"/.cube-install.*; do
    if [ -d "$stage" ] && [ ! -L "$stage" ]; then
        act "remove $stage (left by an interrupted install)" rm -rf -- "$stage"
    fi
done

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
