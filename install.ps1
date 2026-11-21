# The Cube installer for Windows (sub-spec c01/016 phase 3).
#
#   irm https://happonomyorg.github.io/cube-releases/install.ps1 | iex
#
# Windows PowerShell 5.1 and PowerShell 7. It installs cube.exe and the
# cube-*.exe tool binaries of one release channel for your own account.
# Nothing is installed unless every check passes:
#
#   1. the channel manifest <channel>.json and its minisign signature are
#      fetched; when a `minisign` program is on PATH the signature must match
#      one of the two public keys below (the CI key or the offline backup key);
#   2. the manifest must be schema 1, name the requested channel and not be
#      expired;
#   3. GitHub's own record of the release (its REST API) must mark the release
#      immutable and give the archive the same SHA-256 digest as the manifest;
#   4. the downloaded archive's SHA-256 must equal the manifest's;
#   5. cube.exe from the archive must run and report the manifest's version.
#
# On any failure it stops with an error, removes what it downloaded and
# leaves no new binary. Success is printed only after the binaries are in
# place.
#
# It numbers its steps ([2/6] checking the signature, and so on), each a
# line of text and a Write-Progress record, and names the archive and its
# size before the download (sub-spec c01/032 phase 5). Invoke-WebRequest's
# own progress display stays off: it slows downloads in Windows PowerShell
# 5.1 many times over.
#
# Each version goes into a folder of its own (sub-spec c01/032),
# <install folder>\versions\<version>\, with its programs, LICENSE and
# THIRD-PARTY-NOTICES.md. A directory junction <install folder>\current
# names the current version's folder, and your user PATH names ...\current
# once (after saying so); a junction needs neither admin rights nor Developer
# Mode. No file is written in place: each is written under a new name and
# renamed, and a running cube keeps running from its own version folder. The
# version that was current before is kept, older ones are removed, and the
# binaries of a 0.1.0 install (in the install folder itself) become the
# folder of their version.
#
# A release may have no build for Windows (Linux first: a Windows build that
# failed is left out). The installer then installs nothing, stops with an
# error, and prints the command that installs the newest earlier release
# with a Windows build, when the manifest names one ("last_builds"), with
# what that release lacks. It installs that release only when you run that
# command.
#
# Environment:
#   CUBE_CHANNEL       alpha (the default), beta or stable
#   CUBE_VERSION       install this version instead of the channel's newest:
#                      the manifest's own version, or the earlier Windows
#                      build it names ("last_builds"), checked the same way;
#                      any other version is refused
#   CUBE_INSTALL_DIR   the install folder (default: %LOCALAPPDATA%\Programs\cube)
#   CUBE_BASE_URL      where the manifests are (default: $CubeSite below)
#   CUBE_GITHUB_API    GitHub's REST API (default: https://api.github.com)
#   CUBE_INSTALL_SKIP_GITHUB_CHECK=1
#                      skip check 3 (offline, behind a proxy, or past GitHub's
#                      60 anonymous requests an hour); only the site's
#                      manifest then vouches for the file
#
# ASCII only: Windows PowerShell 5.1 reads a script without a BOM as ANSI.
# Everything runs inside one script block, so nothing is left defined in
# your session and a download cut short does not parse.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # The two minisign public keys: the CI key and the offline backup key. The
    # release job refuses to publish this file while the marker below remains.
    $CubePubkeyCi = 'RWR3FugwULgFneOK2w98cIpSzUD9BAFixr5+IDM5NxR9n9bkguhZ0mI1'
    $CubePubkeyBackup = 'RWQi5Mj6AgIPOzxx3x0ci4Bzn7f5VBgjy8o0ZHOZ4ddLbYqlBln0Q1VV'

    # Where the site, the installers and the channel manifests are: GitHub
    # Pages of cube-releases until https://cube.happonomy.org is live (after
    # that, GitHub forwards this address there). install.sh names the same
    # address (CUBE_SITE; docs/custom-domain.md).
    $CubeSite = 'https://happonomyorg.github.io/cube-releases'

    $releasesRepo = 'HapponomyOrg/cube-releases'
    $target = 'x86_64-pc-windows-msvc'
    $stepCount = 6
    $activity = 'Installing The Cube'

    function Write-Step([string]$message) {
        Write-Host "install.ps1: $message"
    }

    # Step $number of $stepCount: a line of text and a Write-Progress record.
    # The preference set here holds inside this function only, so
    # Invoke-WebRequest keeps its own progress display off.
    function Write-InstallStep([int]$number, [string]$message) {
        $text = "[$number/$stepCount] $message"
        Write-Step $text
        $ProgressPreference = 'Continue'
        Write-Progress -Activity $activity -Status $text -PercentComplete ([int](($number - 1) * 100 / $stepCount))
    }

    function Complete-InstallProgress {
        $ProgressPreference = 'Continue'
        Write-Progress -Activity $activity -Completed
    }

    # A size in bytes as people read it: 12.3 MB, 45.6 kB or 789 bytes.
    function Format-CubeSize([long]$bytes) {
        $culture = [Globalization.CultureInfo]::InvariantCulture
        if ($bytes -ge 1000000) { return ($bytes / 1000000).ToString('0.0', $culture) + ' MB' }
        if ($bytes -ge 1000) { return ($bytes / 1000).ToString('0.0', $culture) + ' kB' }
        return "$bytes bytes"
    }

    function Write-Caution([string]$message) {
        Write-Host "install.ps1: warning: $message" -ForegroundColor Yellow
    }

    function Stop-Install([string]$message) {
        throw "install.ps1: error: $message"
    }

    # Only https:// is fetched; plain http only from this machine (a local
    # test server).
    function Test-CubeUrl([string]$url) {
        if ($url -cnotmatch '^https://' -and $url -cnotmatch '^http://(127\.0\.0\.1|localhost)[:/]') {
            Stop-Install "refusing to fetch ${url}: only https:// URLs are allowed"
        }
    }

    function Get-CubeFile([string]$url, [string]$path) {
        Test-CubeUrl $url
        try {
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
        } catch {
            Stop-Install "could not download $url ($($_.Exception.Message))"
        }
    }

    # Runs a program with an argument vector and returns its exit code; the
    # error preference is relaxed so that Windows PowerShell 5.1 does not turn
    # the program's stderr into a terminating error.
    function Invoke-Program([string]$path, [string[]]$arguments) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $path @arguments *> $null
            return $LASTEXITCODE
        } catch {
            return -1
        } finally {
            $ErrorActionPreference = $saved
        }
    }

    # The manifest's layout is fixed (2-space indent, one target per line), so
    # its fields are read line by line; a missing or doubled field is refused.
    function Get-ManifestField([string[]]$lines, [string]$name, [string]$pattern) {
        $found = @($lines | Where-Object { $_ -cmatch ('^  "' + $name + '": ' + $pattern + ',?$') })
        if ($found.Count -ne 1) {
            Stop-Install "the manifest has no single `"$name`" field in the expected layout"
        }
        $null = $found[0] -cmatch ('^  "' + $name + '": ' + $pattern + ',?$')
        return $Matches[1]
    }

    # Removes a file or a folder and returns whether it is gone. A junction is
    # removed itself, never its target's files: [IO.Directory]::Delete without
    # recursion removes the link only.
    function Remove-CubePath([string]$path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not $item) { return $true }
        try {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.PSIsContainer) {
                    [IO.Directory]::Delete($item.FullName, $false)
                } else {
                    [IO.File]::Delete($item.FullName)
                }
            } elseif ($item.PSIsContainer) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            } else {
                Remove-Item -LiteralPath $item.FullName -Force
            }
            return $true
        } catch {
            return $false
        }
    }

    # Removes the .cube-new.<pid>.* and .cube-old.<pid>.* names in $folder
    # whose installer is gone; a program that still runs stays until the next
    # install.
    function Remove-CubeLeftover([string]$folder) {
        $pattern = '^\.cube-(new|old)\.([0-9]{1,9})\.'
        foreach ($left in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch $pattern })) {
            $null = $left.Name -cmatch $pattern
            $owner = [int]$Matches[2]
            if ($owner -ne $PID -and -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
                $null = Remove-CubePath $left.FullName
            }
        }
    }

    if ($env:OS -ne 'Windows_NT') {
        Stop-Install "install.ps1 is for Windows; on Linux and macOS run: curl -fsSL $CubeSite/install.sh | sh"
    }
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'ARM64') {
        Write-Step 'Windows on Arm: installing the x86_64 build, which runs under the x64 emulation of Windows 11'
    } elseif ($arch -ne 'AMD64') {
        Stop-Install "The Cube has no build for Windows $arch; builds exist for Windows x86_64, Linux (x86_64, aarch64) and macOS (arm64, x86_64)"
    }

    $channel = 'alpha'
    if ($env:CUBE_CHANNEL) { $channel = $env:CUBE_CHANNEL }
    if ($channel -cnotmatch '^(alpha|beta|stable)$') {
        Stop-Install "CUBE_CHANNEL must be alpha, beta or stable, not '$channel'"
    }
    $pin = ''
    if ($env:CUBE_VERSION) {
        $pin = $env:CUBE_VERSION
        if ($pin -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
            Stop-Install "CUBE_VERSION must be a version such as 0.2.0, not '$pin'"
        }
    }
    if ($env:CUBE_INSTALL_DIR) {
        $dir = $env:CUBE_INSTALL_DIR
    } else {
        if (-not $env:LOCALAPPDATA) {
            Stop-Install 'LOCALAPPDATA is not set; set CUBE_INSTALL_DIR to the folder for the binaries'
        }
        $dir = Join-Path $env:LOCALAPPDATA 'Programs\cube'
    }
    if ($dir -notmatch '^[A-Za-z]:[\\/]' -and $dir -notmatch '^\\\\[^\\]') {
        Stop-Install "CUBE_INSTALL_DIR must be a full path such as C:\Tools\cube, not '$dir'"
    }
    $dir = $dir.TrimEnd('\', '/')
    $versionsDir = Join-Path $dir 'versions'
    $current = Join-Path $dir 'current'
    $base = $CubeSite
    if ($env:CUBE_BASE_URL) { $base = $env:CUBE_BASE_URL.TrimEnd('/') }
    $apiBase = 'https://api.github.com'
    if ($env:CUBE_GITHUB_API) { $apiBase = $env:CUBE_GITHUB_API.TrimEnd('/') }

    # Windows PowerShell 5.1 on an older .NET may not offer TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # The topmost folder this run makes for the install folder ($null when
    # the install folder is there): a run that stops before the install
    # finished removes the folders it made, while they are empty, so a
    # refusal leaves nothing behind.
    $made = $null
    $probe = $dir
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $made = $probe
        $probe = Split-Path -Parent $probe
    }
    $installed = $false
    $null = New-Item -ItemType Directory -Force -Path $dir
    $parent = Split-Path -Parent $dir
    # The download is staged next to the install folder, never in %TEMP%.
    $stage = Join-Path $parent ('.cube-install.' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $stage
    $leftovers = @()
    try {
        $manifestPath = Join-Path $stage "$channel.json"
        Write-InstallStep 1 "downloading the $channel manifest and its signature"
        Get-CubeFile "$base/$channel.json" $manifestPath
        Get-CubeFile "$base/$channel.json.minisig" "$manifestPath.minisig"

        # Check 1: the signature, when minisign is installed.
        Write-InstallStep 2 'checking the signature'
        $minisign = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $keyShape = '^RW[A-Za-z0-9+/]{54}$'
        if (-not $minisign) {
            Write-Step "minisign is not installed, so the manifest's signature is not checked (install minisign to check it too)"
        } elseif ($CubePubkeyCi -cnotmatch $keyShape -or $CubePubkeyBackup -cnotmatch $keyShape) {
            Write-Caution "this copy of the installer carries no public keys yet, so the manifest's signature is not checked"
        } else {
            $signed = $false
            foreach ($key in @($CubePubkeyCi, $CubePubkeyBackup)) {
                $code = Invoke-Program $minisign.Source @('-V', '-q', '-P', $key, '-m', $manifestPath, '-x', "$manifestPath.minisig")
                if ($code -eq 0) { $signed = $true; break }
            }
            if (-not $signed) {
                Stop-Install "the signature of $channel.json matches neither Happonomy key; nothing was installed"
            }
            Write-Step "the manifest's signature matches a Happonomy key"
        }

        # Check 2: schema, channel, expiry; then the target's line.
        $lines = [IO.File]::ReadAllText($manifestPath) -split "`r?`n"
        $schema = Get-ManifestField $lines 'schema' '([0-9]+)'
        if ($schema -ne '1') {
            Stop-Install "the manifest is schema $schema; this installer reads schema 1 (download the newest installer)"
        }
        $manifestChannel = Get-ManifestField $lines 'channel' '"([^"]*)"'
        if ($manifestChannel -cne $channel) {
            Stop-Install "$channel.json names the channel '$manifestChannel'; nothing was installed"
        }
        $version = Get-ManifestField $lines 'version' '"([0-9A-Za-z.+-]+)"'
        # The version is also a folder name under versions\: no leading dot.
        if ($version.StartsWith('.')) {
            Stop-Install "the manifest's version '$version' is not a version"
        }
        $tag = Get-ManifestField $lines 'tag' '"(cube-v[0-9A-Za-z.+-]+)"'
        $expires = Get-ManifestField $lines 'expires' '"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"'
        $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        # Both are UTC YYYY-MM-DDTHH:MM:SSZ, so string order is time order.
        if ([string]::CompareOrdinal($expires, $now) -le 0) {
            Stop-Install "the release manifest for $channel expired on $expires; new installs resume when Happonomy re-signs it; an installed cube keeps working"
        }
        $newest = $version
        $targetLines = @($lines | Where-Object { $_.StartsWith('    "' + $target + '": {') })
        if ($targetLines.Count -gt 1) {
            Stop-Install "the manifest lists more than one build for $target"
        }
        # The newest earlier release with a Windows build, as the manifest
        # names it ("last_builds"); a line that never matches a target line.
        $earlierLines = @($lines | Where-Object { $_.StartsWith('    {"target": "' + $target + '", "version": "') })
        $earlier = $null
        if ($earlierLines.Count -eq 1 -and $earlierLines[0] -cmatch '^    \{"target": "[^"]+", "version": "([0-9]+\.[0-9]+\.[0-9]+)", ') {
            $earlier = $Matches[1]
        }
        if ($pin -and $pin -cne $version) {
            if ($earlier -cne $pin) {
                $note = ''
                if ($earlier) { $note = ", and cube $earlier as the newest earlier build for $target" }
                Stop-Install "CUBE_VERSION=${pin}: the $channel manifest offers cube $version$note, and no build of cube $pin for $target; nothing was installed"
            }
            $buildLine = $earlierLines[0]
            $version = $pin
            $tag = "cube-v$pin"
            Write-Step "CUBE_VERSION=${pin}: the $channel channel's newest release, cube $newest, has no build for $target; cube $pin is the newest earlier release with one, older and without fixes since"
        } elseif ($targetLines.Count -eq 0) {
            # A release is published once its Linux tests pass; a Windows
            # build that failed is left out of it, and so out of the manifest.
            # Refuse, but name the older version (owner, 2026-11-20): the
            # command that installs it runs only when the user runs it.
            Write-Step "error: cube $version has no build for Windows (${target}): the release left Windows out, as its build or its tests failed; nothing was installed, and a cube installed before keeps working (release notes: https://github.com/$releasesRepo/releases/tag/$tag)"
            if ($earlier) {
                $options = "`$env:CUBE_VERSION = '$earlier'; "
                if ($channel -cne 'alpha') { $options = "`$env:CUBE_CHANNEL = '$channel'; " + $options }
                Write-Step "the newest earlier release with a build for Windows is cube $earlier; to install it, run:"
                Write-Step "  ${options}irm $CubeSite/install.ps1 | iex; Remove-Item Env:CUBE_VERSION"
                $parts = $earlier.Split('.')
                if ([int]$parts[0] -eq 0 -and [int]$parts[1] -le 2) {
                    Write-Step "cube $earlier is older than cube $version and gets no fixes, and it has no cube self update: to update it later, run the installer again"
                } else {
                    Write-Step "cube $earlier is older than cube $version and gets no fixes until a release has a build for Windows again"
                }
            } else {
                Write-Step "no earlier release of the $channel channel has a build for Windows ($target) either"
            }
            Stop-Install "cube $version has no build for Windows ($target); nothing was installed (the lines above say more)"
        } else {
            $buildLine = $targetLines[0]
        }
        if ($buildLine -cmatch '"url": "([^"]+)"') {
            $url = $Matches[1]
        } else {
            Stop-Install "the manifest's entry for $target has no url"
        }
        if ($buildLine -cmatch '"sha256": "([0-9a-f]{64})"') {
            $sha = $Matches[1]
        } else {
            Stop-Install "the manifest's entry for $target has no SHA-256"
        }
        # The size is shown, never trusted: the SHA-256 vouches for the file.
        $sizeText = 'the manifest gives no size'
        if ($buildLine -cmatch '"size": ([0-9]{1,15})[,}]') {
            $sizeText = Format-CubeSize ([long]$Matches[1])
        }
        Test-CubeUrl $url
        $archiveName = $url.Substring($url.LastIndexOf('/') + 1)
        if ($archiveName -cnotmatch '^[0-9A-Za-z._+-]+\.zip$') {
            Stop-Install "the build for $target is not a .zip archive: $archiveName"
        }
        Write-Step "installing cube $version ($channel channel) for $target into $dir"

        # Check 3: GitHub's own record of the release must vouch for the archive.
        Write-InstallStep 3 "checking GitHub's record of release $tag"
        if ($env:CUBE_INSTALL_SKIP_GITHUB_CHECK -eq '1') {
            Write-Caution "CUBE_INSTALL_SKIP_GITHUB_CHECK=1: GitHub's record of the release is not checked; only the site's manifest vouches for the file"
        } else {
            $apiUrl = "$apiBase/repos/$releasesRepo/releases/tags/$tag"
            Test-CubeUrl $apiUrl
            $recordPath = Join-Path $stage 'release.json'
            try {
                Invoke-WebRequest -Uri $apiUrl -OutFile $recordPath -UseBasicParsing -Headers @{
                    'Accept'               = 'application/vnd.github+json'
                    'X-GitHub-Api-Version' = '2022-11-28'
                }
            } catch {
                $cause = $_.Exception.Message
                $status = 0
                if ($_.Exception.Response) {
                    try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
                }
                if ($status -eq 403 -or $status -eq 429) {
                    $cause = "GitHub answered HTTP $status (the limit for anonymous calls is 60 an hour per address)"
                } elseif ($status -ne 0) {
                    $cause = "GitHub answered HTTP $status"
                }
                Stop-Install ("could not read GitHub's record of release $tag (${apiUrl}): $cause. Nothing was installed. " +
                    "To install with only the site's manifest vouching for the file, set `$env:CUBE_INSTALL_SKIP_GITHUB_CHECK = '1' and run the installer again")
            }
            try {
                $release = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
            } catch {
                Stop-Install "GitHub's record of release $tag is not JSON"
            }
            if (-not ($release.immutable -is [bool] -and $release.immutable)) {
                Stop-Install "GitHub does not mark release $tag immutable (immutable: $($release.immutable)); nothing was installed"
            }
            $assets = @($release.assets | Where-Object { $_.browser_download_url -ceq $url })
            if ($assets.Count -ne 1 -or -not $assets[0].digest) {
                Stop-Install "GitHub's record of release $tag has no single asset at $url with a digest; nothing was installed"
            }
            if ($assets[0].digest -cne "sha256:$sha") {
                Stop-Install "GitHub's digest of $archiveName is $($assets[0].digest), the manifest says sha256:$sha; nothing was installed"
            }
            Write-Step "GitHub's record agrees: release $tag is immutable and the archive's digest matches"
        }

        # Check 4: the archive's SHA-256.
        $archive = Join-Path $stage $archiveName
        Write-InstallStep 4 "downloading $archiveName ($sizeText)"
        Get-CubeFile $url $archive
        Write-InstallStep 5 'checking the archive'
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($got -cne $sha) {
            Stop-Install "the SHA-256 of $archiveName is $got, the manifest says $sha; nothing was installed"
        }
        Write-Step "the archive's SHA-256 matches the manifest"

        # The archive holds cube.exe, the cube-*.exe tools, LICENSE,
        # THIRD-PARTY-NOTICES.md and README.md, at its root (dist's zip
        # layout) or in one top folder.
        $extracted = Join-Path $stage 'x'
        try {
            Expand-Archive -LiteralPath $archive -DestinationPath $extracted
        } catch {
            Stop-Install "could not extract $archiveName ($($_.Exception.Message))"
        }
        $payload = $null
        if (Test-Path -LiteralPath (Join-Path $extracted 'cube.exe') -PathType Leaf) {
            $payload = $extracted
        } else {
            $top = @(Get-ChildItem -LiteralPath $extracted -Force)
            if ($top.Count -eq 1 -and $top[0].PSIsContainer -and (Test-Path -LiteralPath (Join-Path $top[0].FullName 'cube.exe') -PathType Leaf)) {
                $payload = $top[0].FullName
            }
        }
        if (-not $payload) {
            Stop-Install 'the archive has no cube.exe at its root or in one top folder; nothing was installed'
        }
        $binaries = @(Get-ChildItem -LiteralPath $payload -File -Force | Where-Object { $_.Name -cmatch '^cube(-[a-z0-9-]+)?\.exe$' } | Sort-Object Name)
        foreach ($binary in $binaries) {
            if ($binary.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Stop-Install "the archive's $($binary.Name) is a link; nothing was installed"
            }
        }

        # Check 5: cube.exe runs here and is the manifest's version.
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $reported = (& (Join-Path $payload 'cube.exe') --version 2> $null | Out-String).Trim()
            $ran = ($LASTEXITCODE -eq 0)
        } catch {
            $ran = $false
        } finally {
            $ErrorActionPreference = $saved
        }
        if (-not $ran) {
            Stop-Install 'the downloaded cube.exe does not run on this machine; nothing was installed'
        }
        if ($reported -cne "cube $version") {
            Stop-Install "the downloaded cube.exe reports '$reported', the manifest says cube $version; nothing was installed"
        }

        Write-InstallStep 6 "installing cube $version into $(Join-Path $versionsDir $version)"
        $names = @($binaries | ForEach-Object { $_.Name })
        $files = $names
        foreach ($name in @('LICENSE', 'THIRD-PARTY-NOTICES.md')) {
            if (Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf) { $files += $name }
        }
        $versionDir = Join-Path $versionsDir $version
        $versionItem = Get-Item -LiteralPath $versionDir -Force -ErrorAction SilentlyContinue
        if ($versionItem -and (-not $versionItem.PSIsContainer -or ($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            Stop-Install "$versionDir is a link or a file, not a folder; nothing was installed"
        }
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($currentItem -and -not ($currentItem.PSIsContainer -and ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            Stop-Install "$current is not a junction; move it away and run the installer again; nothing was installed"
        }

        # The version current now: the version folder the current junction
        # names or, for a 0.1.0 install (the binaries in the install folder
        # itself), the version its cube.exe reports.
        $previous = $null
        $flatCube = Join-Path $dir 'cube.exe'
        $flat = (-not $currentItem) -and (Test-Path -LiteralPath $flatCube -PathType Leaf)
        if ($currentItem) {
            $named = ([string]@($currentItem.Target)[0]) -replace '^(\\\\\?\\|\\\?\?\\)', ''
            if ($named -and (Split-Path -Parent $named).TrimEnd('\') -ieq $versionsDir) {
                $leaf = Split-Path -Leaf $named
                if ($leaf -cmatch '^[0-9A-Za-z+-][0-9A-Za-z.+-]*$' -and (Test-Path -LiteralPath (Join-Path $versionsDir $leaf) -PathType Container)) {
                    $previous = $leaf
                }
            }
        } elseif ($flat) {
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $flatReported = (& $flatCube --version 2> $null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) { $flatReported = '' }
            } catch {
                $flatReported = ''
            } finally {
                $ErrorActionPreference = $saved
            }
            if ($flatReported -cmatch '^cube ([0-9A-Za-z+-][0-9A-Za-z.+-]*)$') {
                $previous = $Matches[1]
            } else {
                Write-Caution "$flatCube reports no version, so it is replaced and not kept"
            }
        }
        $null = New-Item -ItemType Directory -Force -Path $versionsDir

        # A 0.1.0 install moves into the layout: copies of its binaries become
        # the folder of the version they report, written under a new name and
        # renamed; the binaries themselves go after the switch.
        if ($flat -and $previous -and $previous -ine $version -and -not (Test-Path -LiteralPath (Join-Path $versionsDir $previous))) {
            $kept = Join-Path $versionsDir ".cube-new.$PID.$previous"
            $null = New-Item -ItemType Directory -Path $kept
            $leftovers += $kept
            foreach ($name in $names) {
                $old = Join-Path $dir $name
                if (Test-Path -LiteralPath $old -PathType Leaf) {
                    Copy-Item -LiteralPath $old -Destination (Join-Path $kept $name)
                }
            }
            Move-Item -LiteralPath $kept -Destination (Join-Path $versionsDir $previous)
            $leftovers = @($leftovers | Where-Object { $_ -ne $kept })
            Write-Step "moved the cube $previous install from $dir into $(Join-Path $versionsDir $previous)"
        }

        # The new version's files are written into a new folder, which is
        # renamed to versions\<version> in one step. When that folder is there
        # already (the same version again), each file is renamed over its
        # copy instead: a running program's copy is first renamed aside, as
        # Windows renames a running program but does not replace it.
        $new = Join-Path $versionsDir ".cube-new.$PID.$version"
        $null = New-Item -ItemType Directory -Path $new
        $leftovers += $new
        foreach ($name in $files) {
            Move-Item -LiteralPath (Join-Path $payload $name) -Destination (Join-Path $new $name)
        }
        if ($versionItem) {
            foreach ($name in $files) {
                $final = Join-Path $versionDir $name
                $aside = Join-Path $versionDir ".cube-old.$PID.$name"
                $movedAside = $false
                if (Test-Path -LiteralPath $final) {
                    Move-Item -LiteralPath $final -Destination $aside
                    $movedAside = $true
                }
                try {
                    Move-Item -LiteralPath (Join-Path $new $name) -Destination $final
                } catch {
                    if ($movedAside) { Move-Item -LiteralPath $aside -Destination $final }
                    Stop-Install "could not replace ${final}: $($_.Exception.Message)"
                }
                if ($movedAside -and -not (Remove-CubePath $aside)) {
                    Write-Step "the old $name is still running; $aside goes at the next install"
                }
            }
            $null = Remove-CubePath $new
        } else {
            Move-Item -LiteralPath $new -Destination $versionDir
        }
        $leftovers = @($leftovers | Where-Object { $_ -ne $new })

        # The switch: a new junction under a new name, renamed to current.
        # Windows renames no folder over another, so an old current is first
        # renamed aside and removed after (the link only, never the version
        # folder it names). A cube that runs keeps running from its own
        # version folder.
        $newJunction = Join-Path $dir ".cube-new.$PID.current"
        $null = New-Item -ItemType Junction -Path $newJunction -Value $versionDir
        $leftovers += $newJunction
        $oldJunction = $null
        if ($currentItem) {
            $oldJunction = Join-Path $dir ".cube-old.$PID.current"
            Move-Item -LiteralPath $current -Destination $oldJunction
        }
        try {
            Move-Item -LiteralPath $newJunction -Destination $current
        } catch {
            if ($oldJunction) { Move-Item -LiteralPath $oldJunction -Destination $current }
            Stop-Install "could not make $current name cube ${version}: $($_.Exception.Message)"
        }
        $leftovers = @($leftovers | Where-Object { $_ -ne $newJunction })
        if ($oldJunction) { $null = Remove-CubePath $oldJunction }

        # The new version and the one current before it are kept; every other
        # version folder is first renamed to a hidden name, then removed. With
        # no previous version known nothing is removed.
        if ($previous -and $previous -ine $version) {
            foreach ($old in @(Get-ChildItem -LiteralPath $versionsDir -Directory -Force)) {
                if ($old.Name -cnotmatch '^[0-9A-Za-z+-][0-9A-Za-z.+-]*$' -or $old.Name -ieq $version -or $old.Name -ieq $previous -or
                    ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    continue
                }
                $gone = Join-Path $versionsDir ".cube-old.$PID.$($old.Name)"
                try {
                    Move-Item -LiteralPath $old.FullName -Destination $gone
                } catch {
                    Write-Step "cube $($old.Name) is in use, so $($old.FullName) stays until the next install"
                    continue
                }
                $null = Remove-CubePath $gone
                Write-Step "removed cube $($old.Name) ($($old.FullName))"
            }
        }
        foreach ($folder in @($dir, $versionsDir, $versionDir)) { Remove-CubeLeftover $folder }
        $installed = $true
    } finally {
        Complete-InstallProgress
        foreach ($leftover in $leftovers) {
            $null = Remove-CubePath $leftover
        }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        if (-not $installed -and $made) {
            # [IO.Directory]::Delete without recursion removes an empty
            # folder only.
            $folder = $dir
            while ($folder) {
                try { [IO.Directory]::Delete($folder, $false) } catch { break }
                if ($folder -eq $made) { break }
                $folder = Split-Path -Parent $folder
            }
        }
    }

    # The user PATH lives in HKCU\Environment as an expandable string; it is
    # read without expanding %VARIABLES% so they survive the rewrite. It names
    # ...\current once; the install folder itself, which a 0.1.0 install put
    # there, gives its place to ...\current.
    $pathReady = $false
    try {
        $userKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $rawPath = [string]$userKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($rawPath -split ';' | Where-Object { $_ })
            $rewritten = @()
            $listed = $false
            $replaced = $false
            foreach ($entry in $entries) {
                $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                if ($expanded -ieq $current -or $expanded -ieq $dir) {
                    if ($expanded -ieq $dir) { $replaced = $true }
                    if (-not $listed) {
                        if ($expanded -ieq $current) { $rewritten += $entry } else { $rewritten += $current }
                        $listed = $true
                    }
                } else {
                    $rewritten += $entry
                }
            }
            if (-not $listed) { $rewritten += $current }
            if (($rewritten -join ';') -cne ($entries -join ';')) {
                if ($replaced) {
                    Write-Step "your user PATH (HKCU\Environment, value Path) named $dir; it now names $current instead; open a new terminal to use cube"
                } else {
                    Write-Step "adding $current to your user PATH (HKCU\Environment, value Path); open a new terminal to use cube"
                }
                $userKey.SetValue('Path', ($rewritten -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                # Setting and clearing a user variable tells running programs
                # (Explorer, new terminals) that the environment changed.
                [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', '1', 'User')
                [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', $null, 'User')
                $env:Path = "$current;$env:Path"
            }
            $pathReady = $true
        } finally {
            $userKey.Close()
        }
    } catch {
        Write-Caution "could not add $current to your user PATH ($($_.Exception.Message)); add it in Settings, System, About, Advanced system settings, Environment Variables"
    }

    # The binaries of a 0.1.0 install go once the PATH names ...\current; one
    # that still runs is renamed aside and goes at the next install.
    if ($flat -and $pathReady) {
        foreach ($left in @(Get-ChildItem -LiteralPath $dir -File -Force | Where-Object { $_.Name -cmatch '^cube(-[a-z0-9-]+)?(\.old)?\.exe$' })) {
            if (-not (Remove-CubePath $left.FullName)) {
                try {
                    Move-Item -LiteralPath $left.FullName -Destination (Join-Path $dir ".cube-old.$PID.$($left.Name)")
                    Write-Step "$($left.FullName) is still running; it goes at the next install"
                } catch {
                    Write-Caution "could not remove $($left.FullName) ($($_.Exception.Message)); remove it when no cube runs"
                }
            }
        }
    }

    Write-Step "installed cube $version ($channel) in ${dir}: $($names -join ' ')"
    Write-Step "cube $version is in $versionDir; the junction $current names it"
    if ($previous -and $previous -ine $version) {
        Write-Step "the previous version, cube $previous, is kept in $(Join-Path $versionsDir $previous)"
    }
    $tagPage = $url.Substring(0, $url.LastIndexOf('/')) -replace '/download/[^/]+$', "/tag/$tag"
    Write-Step "the licence (LICENSE) and the third-party notices (THIRD-PARTY-NOTICES.md) are in $versionDir and in the release: $tagPage"
}
