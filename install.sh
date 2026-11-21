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
# It numbers its steps ([2/6] checking the signature, and so on) and names
# the archive and its size before the download (sub-spec c01/032 phase 5).
# The download shows curl's (or wget's) progress bar only when standard
# error is a terminal, which it still is under `curl ... | sh`; in a pipe or
# a log every line is plain text, with no bar and no control characters.
#
# Each version goes into a folder of its own (sub-spec c01/032),
# ${XDG_DATA_HOME:-$HOME/.local/share}/cube/versions/<version>/, with its
# programs, LICENSE and THIRD-PARTY-NOTICES.md. The commands in the install
# folder, cube and each cube-* tool (cube-index, cube-graph, cube-audit,
# cube-archive, cube-ghost and cube-ledger), are links into the current
# version's folder; one switch of those links makes a version current. No file is
# written in place: each is written under a new name and renamed. The
# version that was current before is kept, older ones are removed, and the
# binaries of a 0.1.0 install (in the install folder itself) become the
# folder of their version.
#
# A release may have no build for your system (Linux first: a macOS build
# that failed is left out). The installer then installs nothing, exits 1,
# and prints the command that installs the newest earlier release with a
# build for it, when the manifest names one ("last_builds"), with what that
# release lacks. It installs that release only when you run that command.
#
# Environment:
#   CUBE_CHANNEL       alpha (the default), beta or stable
#   CUBE_VERSION       install this version instead of the channel's newest:
#                      the manifest's own version, or the earlier build it
#                      names for your system ("last_builds"), checked the same
#                      way; any other version is refused
#   CUBE_INSTALL_DIR   where the commands go (default: $HOME/.local/bin)
#   XDG_DATA_HOME      holds cube/versions/ (default: $HOME/.local/share)
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
VERSIONS=''
STEPS=6
# The topmost folder this run made for the install folder (empty when the
# install folder was there) and whether the install finished: a run that
# stops removes the folders it made, while they are empty, so a refusal
# leaves nothing behind.
MADE=''
DONE=''
# CUBE_VERSION, when set.
PIN=''

say() {
    printf 'install.sh: %s\n' "$*"
}

# step <n> <what>: the start of step n of $STEPS.
step() {
    say "[$1/$STEPS] $2"
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
    for folder in "$INSTALL_DIR" "$VERSIONS"; do
        [ -n "$folder" ] || continue
        for leftover in "$folder"/.cube-new."$$".* "$folder"/.cube-old."$$".*; do
            if [ -e "$leftover" ] || [ -L "$leftover" ]; then
                rm -rf -- "$leftover"
            fi
        done
    done
    case "$STAGE" in
        */.cube-install.*)
            if [ -d "$STAGE" ]; then
                rm -rf -- "$STAGE"
            fi
            ;;
    esac
    if [ -z "$DONE" ] && [ -n "$MADE" ] && [ -n "$INSTALL_DIR" ]; then
        folder=$INSTALL_DIR
        while rmdir "$folder" 2>/dev/null && [ "$folder" != "$MADE" ]; do
            folder=$(dirname "$folder")
        done
    fi
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

# The archive: with the downloader's progress bar when standard error is a
# terminal, silent otherwise (fetch). GNU wget draws only its bar with
# --show-progress; BusyBox wget has no such option and draws its bar when it
# is not quiet.
fetch_archive() {
    check_url "$1"
    if [ ! -t 2 ]; then
        fetch "$1" "$2"
        return
    fi
    if [ "$DOWNLOADER" = curl ]; then
        case "$1" in
            https://*) curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL --progress-bar -o "$2" "$1" ;;
            *) curl -fL --progress-bar -o "$2" "$1" ;;
        esac
    elif wget --help 2>&1 | grep -q -e '--show-progress'; then
        wget -q --show-progress -O "$2" "$1"
    else
        wget -O "$2" "$1"
    fi
}

# A size in bytes as people read it: 12.3 MB, 45.6 kB or 789 bytes.
human_size() {
    LC_ALL=C awk -v b="$1" 'BEGIN {
        n = b + 0
        if (n >= 1000000) printf "%.1f MB\n", n / 1000000
        else if (n >= 1000) printf "%.1f kB\n", n / 1000
        else printf "%d bytes\n", n
    }'
}

check_tools() {
    for tool in uname id dirname tar mkdir rmdir mv cp ln readlink rm chmod sed grep awk tail date; do
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

# A version is also a folder name under versions/: no path separator, and
# no leading dot (no hidden name, no `..`).
is_version_name() {
    case "$1" in
        '' | .* | *[!0-9A-Za-z.+-]*) return 1 ;;
    esac
    return 0
}

check_manifest() {
    schema=$(manifest_number schema)
    [ "$schema" = 1 ] || die "the manifest is schema $schema; this installer reads schema 1 (download the newest installer)"
    manifest_channel=$(manifest_string channel)
    [ "$manifest_channel" = "$CHANNEL" ] || die "$CHANNEL.json names the channel '$manifest_channel'; nothing was installed"
    VERSION=$(manifest_string version)
    is_version_name "$VERSION" || die "the manifest's version '$VERSION' is not a version"
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
    NEWEST=$VERSION
    count=$(grep -c "^    \"$TARGET\": {" "$MANIFEST" || true)
    [ "$count" -le 1 ] || die "the manifest lists more than one build for $TARGET"
    if [ -n "$PIN" ] && [ "$PIN" != "$VERSION" ]; then
        # An earlier build, as the manifest names it for this target.
        line=$(grep "^    {\"target\": \"$TARGET\", \"version\": \"$PIN\", " "$MANIFEST" || true)
        case "$line" in
            '' | *'
'*) die "CUBE_VERSION=$PIN: the $CHANNEL manifest offers cube $VERSION$(earlier_note), and no build of cube $PIN for $TARGET; nothing was installed" ;;
        esac
        VERSION=$PIN
        TAG="cube-v$PIN"
    elif [ "$count" = 0 ]; then
        no_build
    else
        line=$(grep "^    \"$TARGET\": {" "$MANIFEST")
    fi
    URL=$(printf '%s\n' "$line" | sed -n 's/.*"url": "\([^"]*\)".*/\1/p')
    SHA=$(printf '%s\n' "$line" | sed -n 's/.*"sha256": "\([0-9a-f]*\)".*/\1/p')
    # The size is shown, never trusted: the SHA-256 vouches for the file.
    SIZE=$(printf '%s\n' "$line" | sed -n 's/.*"size": \([0-9][0-9]*\).*/\1/p')
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

# The system $TARGET is a build for, as people name it.
system_name() {
    case "$TARGET" in
        *-apple-darwin) echo macOS ;;
        *) echo Linux ;;
    esac
}

# The newest earlier release with a build for $TARGET that the manifest names
# ("last_builds"); empty when it names none.
earlier_build() {
    found=$(sed -n "s/^    {\"target\": \"$TARGET\", \"version\": \"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\", .*/\1/p" "$MANIFEST")
    case "$found" in
        *'
'*) ;;
        *) printf '%s\n' "$found" ;;
    esac
}

# ", and cube <v> as the newest earlier build for $TARGET", when the manifest
# names one.
earlier_note() {
    found=$(earlier_build)
    [ -z "$found" ] || printf ', and cube %s as the newest earlier build for %s' "$found" "$TARGET"
}

# The release has no build for $TARGET (Linux first: its build or tests
# failed): the error, then, when the manifest names the newest earlier
# release with a build for it, the command that installs that release and
# what it lacks; exit 1, nothing written (owner, 2026-11-20: refuse, but name
# the older version; never a silent fallback).
no_build() {
    system=$(system_name)
    printf 'install.sh: error: %s\n' "cube $VERSION has no build for $system ($TARGET): the release left $system out, as its build or its tests failed; nothing was installed, and a cube installed before keeps working (release notes: https://github.com/$CUBE_RELEASES_REPO/releases/tag/$TAG)" >&2
    earlier=$(earlier_build)
    if [ -z "$earlier" ]; then
        printf 'install.sh: %s\n' "no earlier release of the $CHANNEL channel has a build for $system ($TARGET) either" >&2
        exit 1
    fi
    options="CUBE_VERSION=$earlier"
    [ "$CHANNEL" = alpha ] || options="CUBE_CHANNEL=$CHANNEL $options"
    printf 'install.sh: %s\n' "the newest earlier release with a build for $system is cube $earlier; to install it, run:" >&2
    printf 'install.sh:   %s\n' "curl -fsSL $CUBE_SITE/install.sh | $options sh" >&2
    major=${earlier%%.*}
    minor=${earlier#*.}
    minor=${minor%%.*}
    if [ "$major" = 0 ] && [ "$minor" -le 2 ]; then
        printf 'install.sh: %s\n' "cube $earlier is older than cube $VERSION and gets no fixes, and it has no cube self update: to update it later, run the installer again" >&2
    else
        printf 'install.sh: %s\n' "cube $earlier is older than cube $VERSION and gets no fixes until a release has a build for $system again" >&2
    fi
    exit 1
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

# The folder of the version folders. A relative XDG_DATA_HOME is ignored,
# as the XDG Base Directory specification says.
versions_dir() {
    data=${XDG_DATA_HOME:-}
    case "$data" in
        '' | /*) ;;
        *)
            warn "XDG_DATA_HOME is not an absolute path ('$data'), so it is ignored"
            data=''
            ;;
    esac
    if [ -z "$data" ]; then
        [ -n "${HOME:-}" ] || die "HOME is not set; set XDG_DATA_HOME to the folder that holds cube/versions"
        data="$HOME/.local/share"
    fi
    VERSIONS="${data%/}/cube/versions"
}

# The programs in the archive: cube and every cube-* file.
payload_programs() {
    NAMES=''
    for file in "$PAYLOAD/cube" "$PAYLOAD"/cube-*; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        name=${file##*/}
        case "$name" in
            *[!a-z0-9-]*) continue ;;
        esac
        [ ! -L "$file" ] || die "the archive's $name is a link; nothing was installed"
        [ -f "$file" ] || continue
        NAMES="$NAMES $name"
    done
}

# The version the install folder runs now, in PREVIOUS: the version folder
# its cube link names or, for a 0.1.0 install (the binaries themselves in the
# install folder; FLAT=1), the version that cube reports.
current_state() {
    PREVIOUS=''
    FLAT=''
    if [ -L "$dir/cube" ]; then
        target=$(readlink "$dir/cube") || target=''
        case "$target" in
            "$VERSIONS"/*/cube)
                version=${target#"$VERSIONS"/}
                version=${version%/cube}
                if is_version_name "$version" && [ -d "$VERSIONS/$version" ] && [ ! -L "$VERSIONS/$version" ]; then
                    PREVIOUS=$version
                fi
                ;;
        esac
    elif [ -f "$dir/cube" ]; then
        reported=$("$dir/cube" --version </dev/null 2>/dev/null) || reported=''
        version=${reported#cube }
        if [ "$reported" = "cube $version" ] && is_version_name "$version"; then
            PREVIOUS=$version
            FLAT=1
        else
            warn "$dir/cube reports no version, so it is replaced and not kept"
        fi
    fi
}

# A 0.1.0 install moves into the layout: copies of the binaries this release
# replaces become the folder of the version they report, written under a new
# name and renamed. The switch then renames a link over each of them.
keep_flat_install() {
    if [ -z "$FLAT" ] || [ "$PREVIOUS" = "$VERSION" ] || [ -e "$VERSIONS/$PREVIOUS" ] || [ -L "$VERSIONS/$PREVIOUS" ]; then
        return 0
    fi
    kept="$VERSIONS/.cube-new.$$.$PREVIOUS"
    mkdir "$kept" || die "could not create $kept; nothing was installed"
    chmod 755 "$kept"
    for name in $NAMES; do
        if [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ]; then
            cp "$dir/$name" "$kept/$name" || die "could not copy $dir/$name into $kept; nothing was installed"
            chmod 755 "$kept/$name"
        fi
    done
    mv "$kept" "$VERSIONS/$PREVIOUS" || die "could not rename $kept to $VERSIONS/$PREVIOUS; nothing was installed"
    say "moved the cube $PREVIOUS install from $dir into $VERSIONS/$PREVIOUS"
}

# The new version's files are written into a new folder, which is renamed to
# versions/<version> in one step. When that folder is there already (the
# same version again), each file is renamed over its old copy instead.
place_version() {
    VERSION_DIR="$VERSIONS/$VERSION"
    if [ -L "$VERSION_DIR" ] || { [ -e "$VERSION_DIR" ] && [ ! -d "$VERSION_DIR" ]; }; then
        die "$VERSION_DIR is a link or a file, not a folder; nothing was installed"
    fi
    files=$NAMES
    for name in LICENSE THIRD-PARTY-NOTICES.md; do
        if [ -f "$PAYLOAD/$name" ] && [ ! -L "$PAYLOAD/$name" ]; then
            files="$files $name"
        fi
    done
    if [ -d "$VERSION_DIR" ]; then
        for name in $files; do
            [ ! -d "$VERSION_DIR/$name" ] || die "$VERSION_DIR/$name is a folder; nothing was installed"
        done
    fi
    new="$VERSIONS/.cube-new.$$.$VERSION"
    mkdir "$new" || die "could not create $new; nothing was installed"
    chmod 755 "$new"
    for name in $files; do
        case "$name" in
            cube | cube-*) chmod 755 "$PAYLOAD/$name" ;;
            *) chmod 644 "$PAYLOAD/$name" ;;
        esac
        mv -f "$PAYLOAD/$name" "$new/$name" || die "could not write $name into $new; nothing was installed"
    done
    if [ -d "$VERSION_DIR" ]; then
        for name in $files; do
            mv -f "$new/$name" "$VERSION_DIR/$name" || die "could not replace $VERSION_DIR/$name"
        done
        rmdir "$new" || die "could not remove $new"
    else
        mv "$new" "$VERSION_DIR" || die "could not rename $new to $VERSION_DIR; nothing was installed"
    fi
}

# Makes the version current: for each program, a new link into the version
# folder is made under a new name and renamed over the command, which is
# atomic for a link to a file on Linux and macOS. The cube link goes first,
# and its rename is the switch: cube runs its tools from beside its
# resolved path, so its link decides the version, and an install cut short
# before it leaves the previous version current, tools included (a 0.1.0
# cube runs only regular files beside it, never a link). The other links
# name each tool for a direct call.
switch_links() {
    for name in $NAMES; do
        [ ! -d "$dir/$name" ] || die "$dir/$name is a folder, so it cannot become a link to cube $VERSION; nothing was switched"
    done
    switch_link cube
    for name in $NAMES; do
        [ "$name" = cube ] || switch_link "$name"
    done
}

switch_link() {
    ln -s "$VERSION_DIR/$1" "$dir/.cube-new.$$.$1" || die "could not make a link in $dir"
    mv -f "$dir/.cube-new.$$.$1" "$dir/$1" || die "could not replace $dir/$1"
}

# Keeps the new version and the one current before it, and removes every
# other version folder, each first renamed to a hidden name so that no
# half-removed folder keeps a version's name. With no previous version known
# (a fresh install, or a cube link into no version folder here) nothing is
# removed: another install folder may run them. Then what a killed run of
# this installer left is removed.
prune_versions() {
    if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$VERSION" ]; then
        for old in "$VERSIONS"/*; do
            name=${old##*/}
            if [ ! -d "$old" ] || [ -L "$old" ] || ! is_version_name "$name" ||
                [ "$name" = "$VERSION" ] || [ "$name" = "$PREVIOUS" ]; then
                continue
            fi
            if mv "$old" "$VERSIONS/.cube-old.$$.$name"; then
                rm -rf -- "$VERSIONS/.cube-old.$$.$name"
                say "removed cube $name ($old)"
            else
                warn "could not remove $old"
            fi
        done
    fi
    sweep_stale "$VERSIONS"
    sweep_stale "$dir"
    sweep_stale "$parent"
}

# Removes the .cube-new.<pid>.*, .cube-old.<pid>.* and .cube-install.<pid>.*
# names in folder $1 whose installer process is gone.
sweep_stale() {
    for left in "$1"/.cube-new.* "$1"/.cube-old.* "$1"/.cube-install.*; do
        [ -e "$left" ] || [ -L "$left" ] || continue
        pid=${left##*/}
        pid=${pid#.cube-*.}
        pid=${pid%%.*}
        case "$pid" in
            '' | *[!0-9]*) continue ;;
        esac
        if [ "$pid" != "$$" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf -- "$left"
        fi
    done
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
    versions_dir
    if [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
        die "run the installer as yourself, without sudo: it installs for your own account"
    fi
    base=${CUBE_BASE_URL:-$CUBE_SITE}
    base=${base%/}
    PIN=${CUBE_VERSION:-}
    if [ -n "$PIN" ] && ! printf '%s\n' "$PIN" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        die "CUBE_VERSION must be a version such as 0.2.0, not '$PIN'"
    fi

    check_tools
    detect_target

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    probe=$dir
    while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
        MADE=$probe
        probe=$(dirname "$probe")
    done
    INSTALL_DIR=$dir
    mkdir -p "$dir" || die "could not create the install folder $dir"
    parent=$(dirname "$dir")
    # The download is staged next to the install folder, never in the
    # system temp folder; its name carries this run's pid, so a later run
    # removes it when this one was killed (sweep_stale).
    if has mktemp; then
        STAGE=$(mktemp -d "$parent/.cube-install.$$.XXXXXX") || die "could not create a staging folder in $parent"
    else
        STAGE="$parent/.cube-install.$$"
        (umask 077 && mkdir "$STAGE") || die "could not create a staging folder in $parent"
    fi

    MANIFEST="$STAGE/$CHANNEL.json"
    step 1 "downloading the $CHANNEL manifest and its signature"
    fetch "$base/$CHANNEL.json" "$MANIFEST" || die "could not download $base/$CHANNEL.json"
    fetch "$base/$CHANNEL.json.minisig" "$MANIFEST.minisig" || die "could not download $base/$CHANNEL.json.minisig"
    step 2 "checking the signature"
    verify_signature
    check_manifest
    if [ "$VERSION" != "$NEWEST" ]; then
        say "CUBE_VERSION=$VERSION: the $CHANNEL channel's newest release, cube $NEWEST, has no build for $TARGET; cube $VERSION is the newest earlier release with one, older and without fixes since"
    fi
    say "installing cube $VERSION ($CHANNEL channel) for $TARGET into $dir"
    step 3 "checking GitHub's record of release $TAG"
    check_github_record

    archive="$STAGE/$ARCHIVE_NAME"
    if [ -n "$SIZE" ]; then
        step 4 "downloading $ARCHIVE_NAME ($(human_size "$SIZE"))"
    else
        step 4 "downloading $ARCHIVE_NAME (the manifest gives no size)"
    fi
    fetch_archive "$URL" "$archive" || die "could not download $URL"
    step 5 "checking the archive"
    got=$(file_sha256 "$archive")
    [ "$got" = "$SHA" ] || die "the SHA-256 of $ARCHIVE_NAME is $got, the manifest says $SHA; nothing was installed"
    say "the archive's SHA-256 matches the manifest"

    mkdir "$STAGE/x"
    tar -xf "$archive" -C "$STAGE/x" || die "could not extract $ARCHIVE_NAME (a .tar.xz needs tar with xz support)"
    find_payload

    reported=$("$PAYLOAD/cube" --version </dev/null 2>/dev/null) || die "the downloaded cube does not run on this machine; nothing was installed"
    [ "$reported" = "cube $VERSION" ] || die "the downloaded cube reports '$reported', the manifest says cube $VERSION; nothing was installed"

    step 6 "installing cube $VERSION into $VERSIONS/$VERSION"
    payload_programs
    current_state
    mkdir -p "$VERSIONS" || die "could not create $VERSIONS; nothing was installed"
    keep_flat_install
    place_version
    switch_links
    prune_versions
    DONE=1

    say "installed cube $VERSION ($CHANNEL) in $dir:$NAMES"
    say "cube $VERSION is in $VERSION_DIR; the commands in $dir are links to it"
    if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$VERSION" ]; then
        say "the previous version, cube $PREVIOUS, is kept in $VERSIONS/$PREVIOUS"
    fi
    tag_page=${URL%/*}
    say "the licence (LICENSE) and the third-party notices (THIRD-PARTY-NOTICES.md) are in $VERSION_DIR and in the release: ${tag_page%/download/*}/tag/$TAG"
    case ":${PATH:-}:" in
        *":$dir:"*) ;;
        *)
            say "$dir is not on your PATH; add this line to your shell's startup file (~/.profile, ~/.bashrc or ~/.zshrc), then open a new terminal:"
            say "  export PATH=\"$dir:\$PATH\""
            ;;
    esac
}

main "$@"
