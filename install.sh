#!/bin/sh
# The Cube installer for Linux and macOS (sub-spec c01/016 phase 3).
#
#   curl -fsSL https://happonomyorg.github.io/cube-releases/install.sh | sh
#
# It installs cube and the cube-* tool binaries of one release channel for
# your own account. Nothing is installed unless every check passes:
#
#   1. the channel manifest <channel>.json and its minisign signature are
#      fetched; when a `minisign` binary is on PATH the signature must match
#      one of the two public keys below (the CI key or the offline backup key);
#   2. the manifest must be schema 1, name the requested channel and not be
#      expired;
#   3. GitHub's own record of the release (its REST API) must mark the release
#      immutable and give the archive the same SHA-256 digest as the manifest;
#   4. the downloaded archive's SHA-256 must equal the manifest's;
#   5. the cube binary in the archive must run and report the manifest's
#      version.
#
# On any failure it exits non-zero, removes what it downloaded and leaves no
# new binary. Success is printed only after the binaries are in place.
#
# Environment:
#   CUBE_CHANNEL       alpha (the default), beta or stable
#   CUBE_INSTALL_DIR   where the binaries go (default: $HOME/.local/bin)
#   CUBE_BASE_URL      where the manifests are (default: CUBE_SITE below)
#   CUBE_GITHUB_API    GitHub's REST API (default: https://api.github.com)
#   CUBE_INSTALL_SKIP_GITHUB_CHECK=1
#                      skip check 3 (offline, behind a proxy, or past GitHub's
#                      60 anonymous requests an hour); only the site's
#                      manifest then vouches for the file
#
# POSIX sh; every line below is wrapped in functions and `main` runs on the
# last line, so a download cut short runs nothing.

set -eu

# The two minisign public keys: the CI key and the offline backup key. The
# release job refuses to publish this file while the marker below remains.
CUBE_PUBKEY_CI='RWR3FugwULgFneOK2w98cIpSzUD9BAFixr5+IDM5NxR9n9bkguhZ0mI1'
CUBE_PUBKEY_BACKUP='RWQi5Mj6AgIPOzxx3x0ci4Bzn7f5VBgjy8o0ZHOZ4ddLbYqlBln0Q1VV'

# Where the site, the installers and the channel manifests are: GitHub Pages
# of cube-releases until https://cube.happonomy.org is live (after that,
# GitHub forwards this address there). install.ps1 names the same address;
# the site and the release job read it here (docs/custom-domain.md).
CUBE_SITE='https://happonomyorg.github.io/cube-releases'

CUBE_RELEASES_REPO='HapponomyOrg/cube-releases'

STAGE=''
INSTALL_DIR=''

say() {
    printf 'install.sh: %s\n' "$*"
}

warn() {
    printf 'install.sh: warning: %s\n' "$*" >&2
}

die() {
    printf 'install.sh: error: %s\n' "$*" >&2
    exit 1
}

has() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    if [ -n "$INSTALL_DIR" ]; then
        for leftover in "$INSTALL_DIR"/.cube-new."$$".*; do
            if [ -e "$leftover" ] || [ -L "$leftover" ]; then
                rm -f -- "$leftover"
            fi
        done
    fi
    case "$STAGE" in
        */.cube-install.*)
            if [ -d "$STAGE" ]; then
                rm -rf -- "$STAGE"
            fi
            ;;
    esac
}

# Only https:// is fetched; plain http only from this machine (a local test
# server).
check_url() {
    case "$1" in
        https://*) ;;
        http://127.0.0.1:* | http://127.0.0.1/* | http://localhost:* | http://localhost/*) ;;
        *) die "refusing to fetch $1: only https:// URLs are allowed" ;;
    esac
}

fetch() {
    check_url "$1"
    if [ "$DOWNLOADER" = curl ]; then
        case "$1" in
            https://*) curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL -o "$2" "$1" ;;
            *) curl -fsSL -o "$2" "$1" ;;
        esac
    else
        wget -q -O "$2" "$1"
    fi
}

check_tools() {
    for tool in uname id dirname tar mkdir mv rm chmod sed grep awk tail date; do
        has "$tool" || die "this installer needs '$tool', which is not on PATH"
    done
    if has curl; then
        DOWNLOADER=curl
    elif has wget; then
        DOWNLOADER=wget
    else
        die "this installer needs curl or wget to download; install one and run it again"
    fi
    if has sha256sum; then
        SHA_TOOL=sha256sum
    elif has shasum; then
        SHA_TOOL=shasum
    else
        die "no SHA-256 tool found (sha256sum or shasum), so the download cannot be checked; install one (coreutils or perl) and run it again"
    fi
}

file_sha256() {
    if [ "$SHA_TOOL" = sha256sum ]; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux)
            suffix=unknown-linux-musl
            ;;
        Darwin)
            suffix=apple-darwin
            # A shell under Rosetta reports x86_64 on Apple silicon.
            if [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
                arch=arm64
            fi
            ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            die "on Windows, run in PowerShell: irm $CUBE_SITE/install.ps1 | iex"
            ;;
        *)
            die "The Cube has no build for $os $arch; builds exist for Linux (x86_64, aarch64), macOS (arm64, x86_64) and Windows (x86_64)"
            ;;
    esac
    case "$arch" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        *) die "The Cube has no build for $os $arch; builds exist for Linux (x86_64, aarch64), macOS (arm64, x86_64) and Windows (x86_64)" ;;
    esac
    TARGET="$cpu-$suffix"
}

# The manifest's layout is fixed (2-space indent, one target per line), so
# its fields are read with sed; a missing or doubled field is refused.
manifest_string() {
    value=$(sed -n "s/^  \"$1\": \"\\([^\"]*\\)\",\\{0,1\\}\$/\\1/p" "$MANIFEST")
    case "$value" in
        '' | *'
'*) die "the manifest has no single \"$1\" field in the expected layout" ;;
    esac
    printf '%s\n' "$value"
}

manifest_number() {
    value=$(sed -n "s/^  \"$1\": \\([0-9][0-9]*\\),\\{0,1\\}\$/\\1/p" "$MANIFEST")
    case "$value" in
        '' | *'
'*) die "the manifest has no single \"$1\" field in the expected layout" ;;
    esac
    printf '%s\n' "$value"
}

verify_signature() {
    if ! has minisign; then
        say "minisign is not installed, so the manifest's signature is not checked (install minisign to check it too)"
        return 0
    fi
    # A minisign public key is "RW" and 54 more base64 characters; anything
    # else is the placeholder of a pre-release copy.
    for key in "$CUBE_PUBKEY_CI" "$CUBE_PUBKEY_BACKUP"; do
        if ! printf '%s\n' "$key" | grep -Eq '^RW[A-Za-z0-9+/]{54}$'; then
            warn "this copy of the installer carries no public keys yet, so the manifest's signature is not checked"
            return 0
        fi
    done
    for key in "$CUBE_PUBKEY_CI" "$CUBE_PUBKEY_BACKUP"; do
        if minisign -V -q -P "$key" -m "$MANIFEST" -x "$MANIFEST.minisig" </dev/null >/dev/null 2>&1; then
            say "the manifest's signature matches a Happonomy key"
            return 0
        fi
    done
    die "the signature of $CHANNEL.json matches neither Happonomy key; nothing was installed"
}

check_manifest() {
    schema=$(manifest_number schema)
    [ "$schema" = 1 ] || die "the manifest is schema $schema; this installer reads schema 1 (download the newest installer)"
    manifest_channel=$(manifest_string channel)
    [ "$manifest_channel" = "$CHANNEL" ] || die "$CHANNEL.json names the channel '$manifest_channel'; nothing was installed"
    VERSION=$(manifest_string version)
    case "$VERSION" in
        *[!0-9A-Za-z.+-]*) die "the manifest's version '$VERSION' is not a version" ;;
    esac
    TAG=$(manifest_string tag)
    case "$TAG" in
        cube-v*) ;;
        *) die "the manifest's tag '$TAG' is not a cube-v<version> tag" ;;
    esac
    case "$TAG" in
        *[!0-9A-Za-z.+-]*) die "the manifest's tag '$TAG' is not a cube-v<version> tag" ;;
    esac
    expires=$(manifest_string expires)
    if ! printf '%s\n' "$expires" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
        die "the manifest's expiry '$expires' is not a UTC time"
    fi
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Both are UTC YYYY-MM-DDTHH:MM:SSZ, so string order is time order.
    if LC_ALL=C awk -v e="$expires" -v n="$now" 'BEGIN { exit !(e "" <= n "") }'; then
        die "the release manifest for $CHANNEL expired on $expires; new installs resume when Happonomy re-signs it; an installed cube keeps working"
    fi
    count=$(grep -c "^    \"$TARGET\": {" "$MANIFEST" || true)
    [ "$count" = 1 ] || die "the manifest lists no single build for $TARGET"
    line=$(grep "^    \"$TARGET\": {" "$MANIFEST")
    URL=$(printf '%s\n' "$line" | sed -n 's/.*"url": "\([^"]*\)".*/\1/p')
    SHA=$(printf '%s\n' "$line" | sed -n 's/.*"sha256": "\([0-9a-f]*\)".*/\1/p')
    [ -n "$URL" ] || die "the manifest's entry for $TARGET has no url"
    printf '%s\n' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || die "the manifest's entry for $TARGET has no SHA-256"
    check_url "$URL"
    ARCHIVE_NAME=${URL##*/}
    case "$ARCHIVE_NAME" in
        *.tar.xz | *.tar.gz | *.tgz) ;;
        *) die "the build for $TARGET is not a .tar.xz or .tar.gz archive: $ARCHIVE_NAME" ;;
    esac
    case "$ARCHIVE_NAME" in
        *[!0-9A-Za-z._+-]*) die "the archive name '$ARCHIVE_NAME' has unexpected characters" ;;
    esac
}

# Prints "<path>\t<value>" for every scalar of a JSON document on stdin,
# paths joined with "/" (array items by index): enough to read GitHub's
# release record without jq. String escapes other than \" \\ \/ are kept.
json_flatten() {
    LC_ALL=C awk '
    function path(   p, d) {
        p = ""
        for (d = 1; d <= depth; d++) {
            p = p (d > 1 ? "/" : "") (kind[d] == "o" ? key[d] : idx[d])
        }
        return p
    }
    { doc = doc $0 "\n" }
    END {
        n = length(doc); i = 1; depth = 0
        while (i <= n) {
            c = substr(doc, i, 1)
            if (c == "{" || c == "[") {
                depth++; kind[depth] = (c == "{") ? "o" : "a"; idx[depth] = 0; key[depth] = ""
                wantkey[depth] = (c == "{"); i++; continue
            }
            if (c == "}" || c == "]") { depth--; i++; continue }
            if (c == ",") { if (kind[depth] == "a") idx[depth]++; else wantkey[depth] = 1; i++; continue }
            if (c == ":") { wantkey[depth] = 0; i++; continue }
            if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
            if (c == "\"") {
                s = ""; j = i + 1
                while (j <= n) {
                    d = substr(doc, j, 1)
                    if (d == "\\") {
                        e = substr(doc, j + 1, 1)
                        if (e == "\"" || e == "\\" || e == "/") s = s e; else s = s "\\" e
                        j += 2; continue
                    }
                    if (d == "\"") break
                    s = s d; j++
                }
                i = j + 1
                if (kind[depth] == "o" && wantkey[depth]) { key[depth] = s; continue }
                print path() "\t" s; continue
            }
            j = i
            while (j <= n && index(",}] \t\r\n", substr(doc, j, 1)) == 0) j++
            print path() "\t" substr(doc, i, j - i)
            i = j
        }
    }'
}

# Check 3: GitHub's own record of the release must vouch for the archive.
check_github_record() {
    if [ "${CUBE_INSTALL_SKIP_GITHUB_CHECK:-}" = 1 ]; then
        warn "CUBE_INSTALL_SKIP_GITHUB_CHECK=1: GitHub's record of the release is not checked; only the site's manifest vouches for the file"
        return 0
    fi
    api_base=${CUBE_GITHUB_API:-https://api.github.com}
    api_url="${api_base%/}/repos/$CUBE_RELEASES_REPO/releases/tags/$TAG"
    check_url "$api_url"
    record="$STAGE/release.json"
    api_err="$STAGE/release.err"
    cause=''
    if [ "$DOWNLOADER" = curl ]; then
        case "$api_url" in
            https://*) set -- --proto '=https' --proto-redir '=https' --tlsv1.2 ;;
            *) set -- ;;
        esac
        code=$(curl "$@" -sSL -o "$record" -w '%{http_code}' \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$api_url" 2>"$api_err") || code=000
        case "$code" in
            200) ;;
            000)
                cause=$(tail -n 1 "$api_err")
                [ -n "$cause" ] || cause="curl could not reach it"
                ;;
            403 | 429) cause="GitHub answered HTTP $code (the limit for anonymous calls is 60 an hour per address)" ;;
            *) cause="GitHub answered HTTP $code" ;;
        esac
    else
        rc=0
        wget -q -O "$record" \
            --header 'Accept: application/vnd.github+json' \
            --header 'X-GitHub-Api-Version: 2022-11-28' \
            "$api_url" 2>"$api_err" || rc=$?
        if [ "$rc" != 0 ]; then
            cause=$(tail -n 1 "$api_err")
            [ -n "$cause" ] || cause="wget exit $rc"
        fi
    fi
    if [ -n "$cause" ]; then
        die "could not read GitHub's record of release $TAG ($api_url): $cause. Nothing was installed. To install with only the site's manifest vouching for the file, run again with CUBE_INSTALL_SKIP_GITHUB_CHECK=1"
    fi
    if has jq; then
        immutable=$(jq -r '.immutable' "$record") || die "GitHub's record of release $TAG is not JSON"
        digest=$(jq -r --arg u "$URL" '[.assets[]? | select(.browser_download_url == $u) | .digest] | if length == 1 then .[0] // "" else "" end' "$record") ||
            die "GitHub's record of release $TAG is not JSON"
    else
        flat="$STAGE/release.flat"
        json_flatten <"$record" >"$flat"
        immutable=$(awk -F '\t' '$1 == "immutable" { print $2 }' "$flat")
        asset=$(awk -F '\t' -v u="$URL" '$1 ~ /^assets\/[0-9]+\/browser_download_url$/ && $2 == u { split($1, p, "/"); print p[2] }' "$flat")
        case "$asset" in
            '' | *'
'*) digest='' ;;
            *) digest=$(awk -F '\t' -v k="assets/$asset/digest" '$1 == k { print $2 }' "$flat") ;;
        esac
    fi
    [ "$immutable" = true ] || die "GitHub does not mark release $TAG immutable (immutable: ${immutable:-absent}); nothing was installed"
    [ -n "$digest" ] || die "GitHub's record of release $TAG has no single asset at $URL with a digest; nothing was installed"
    [ "$digest" = "sha256:$SHA" ] || die "GitHub's digest of $ARCHIVE_NAME is $digest, the manifest says sha256:$SHA; nothing was installed"
    say "GitHub's record agrees: release $TAG is immutable and the archive's digest matches"
}

# The archive holds cube, the cube-* tools, LICENSE, THIRD-PARTY-NOTICES.md
# and README.md, at its root or in one top folder (dist's tar layout).
find_payload() {
    extracted="$STAGE/x"
    if [ -f "$extracted/cube" ] && [ ! -L "$extracted/cube" ]; then
        PAYLOAD=$extracted
        return 0
    fi
    set -- "$extracted"/*
    if [ "$#" -eq 1 ] && [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/cube" ] && [ ! -L "$1/cube" ]; then
        PAYLOAD=$1
        return 0
    fi
    die "the archive has no cube binary at its root or in one top folder; nothing was installed"
}

main() {
    CHANNEL=${CUBE_CHANNEL:-alpha}
    case "$CHANNEL" in
        alpha | beta | stable) ;;
        *) die "CUBE_CHANNEL must be alpha, beta or stable, not '$CHANNEL'" ;;
    esac
    if [ -n "${CUBE_INSTALL_DIR:-}" ]; then
        dir=$CUBE_INSTALL_DIR
    else
        [ -n "${HOME:-}" ] || die "HOME is not set; set CUBE_INSTALL_DIR to the folder for the binaries"
        dir="$HOME/.local/bin"
    fi
    case "$dir" in
        /*) ;;
        *) die "CUBE_INSTALL_DIR must be an absolute path, not '$dir'" ;;
    esac
    dir=${dir%/}
    [ -n "$dir" ] || die "CUBE_INSTALL_DIR must not be /"
    if [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
        die "run the installer as yourself, without sudo: it installs for your own account"
    fi
    base=${CUBE_BASE_URL:-$CUBE_SITE}
    base=${base%/}

    check_tools
    detect_target

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    mkdir -p "$dir" || die "could not create the install folder $dir"
    INSTALL_DIR=$dir
    parent=$(dirname "$dir")
    # The download is staged next to the install folder, never in the
    # system temp folder.
    if has mktemp; then
        STAGE=$(mktemp -d "$parent/.cube-install.XXXXXX") || die "could not create a staging folder in $parent"
    else
        STAGE="$parent/.cube-install.$$"
        (umask 077 && mkdir "$STAGE") || die "could not create a staging folder in $parent"
    fi

    MANIFEST="$STAGE/$CHANNEL.json"
    fetch "$base/$CHANNEL.json" "$MANIFEST" || die "could not download $base/$CHANNEL.json"
    fetch "$base/$CHANNEL.json.minisig" "$MANIFEST.minisig" || die "could not download $base/$CHANNEL.json.minisig"
    verify_signature
    check_manifest
    say "installing cube $VERSION ($CHANNEL channel) for $TARGET into $dir"
    check_github_record

    archive="$STAGE/$ARCHIVE_NAME"
    fetch "$URL" "$archive" || die "could not download $URL"
    got=$(file_sha256 "$archive")
    [ "$got" = "$SHA" ] || die "the SHA-256 of $ARCHIVE_NAME is $got, the manifest says $SHA; nothing was installed"
    say "the archive's SHA-256 matches the manifest"

    mkdir "$STAGE/x"
    tar -xf "$archive" -C "$STAGE/x" || die "could not extract $ARCHIVE_NAME (a .tar.xz needs tar with xz support)"
    find_payload

    reported=$("$PAYLOAD/cube" --version </dev/null 2>/dev/null) || die "the downloaded cube does not run on this machine; nothing was installed"
    [ "$reported" = "cube $VERSION" ] || die "the downloaded cube reports '$reported', the manifest says cube $VERSION; nothing was installed"

    # Every binary is first moved next to its final name, then renamed over
    # it, so each name holds either the old file or the whole new one.
    names=''
    for file in "$PAYLOAD/cube" "$PAYLOAD"/cube-*; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        name=${file##*/}
        case "$name" in
            *[!a-z0-9-]*) continue ;;
        esac
        [ ! -L "$file" ] || die "the archive's $name is a link; nothing was installed"
        [ -f "$file" ] || continue
        chmod 755 "$file"
        mv -f "$file" "$dir/.cube-new.$$.$name" || die "could not write $name into $dir; nothing was installed"
        names="$names $name"
    done
    for name in $names; do
        mv -f "$dir/.cube-new.$$.$name" "$dir/$name" || die "could not replace $dir/$name"
    done

    say "installed cube $VERSION ($CHANNEL) in $dir:$names"
    tag_page=${URL%/*}
    say "the licence (LICENSE) and the third-party notices (THIRD-PARTY-NOTICES.md) are in the release archive: ${tag_page%/download/*}/tag/$TAG"
    case ":${PATH:-}:" in
        *":$dir:"*) ;;
        *)
            say "$dir is not on your PATH; add this line to your shell's startup file (~/.profile, ~/.bashrc or ~/.zshrc), then open a new terminal:"
            say "  export PATH=\"$dir:\$PATH\""
            ;;
    esac
}

main "$@"
