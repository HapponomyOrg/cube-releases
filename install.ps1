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
# place. The install folder is added to your user PATH (after saying so).
#
# Environment:
#   CUBE_CHANNEL       alpha (the default), beta or stable
#   CUBE_INSTALL_DIR   where the binaries go (default: %LOCALAPPDATA%\Programs\cube)
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

    function Write-Step([string]$message) {
        Write-Host "install.ps1: $message"
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
    $base = $CubeSite
    if ($env:CUBE_BASE_URL) { $base = $env:CUBE_BASE_URL.TrimEnd('/') }
    $apiBase = 'https://api.github.com'
    if ($env:CUBE_GITHUB_API) { $apiBase = $env:CUBE_GITHUB_API.TrimEnd('/') }

    # Windows PowerShell 5.1 on an older .NET may not offer TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $null = New-Item -ItemType Directory -Force -Path $dir
    $parent = Split-Path -Parent $dir
    # The download is staged next to the install folder, never in %TEMP%.
    $stage = Join-Path $parent ('.cube-install.' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $stage
    $staged = @()
    try {
        $manifestPath = Join-Path $stage "$channel.json"
        Get-CubeFile "$base/$channel.json" $manifestPath
        Get-CubeFile "$base/$channel.json.minisig" "$manifestPath.minisig"

        # Check 1: the signature, when minisign is installed.
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
        $tag = Get-ManifestField $lines 'tag' '"(cube-v[0-9A-Za-z.+-]+)"'
        $expires = Get-ManifestField $lines 'expires' '"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"'
        $now = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        # Both are UTC YYYY-MM-DDTHH:MM:SSZ, so string order is time order.
        if ([string]::CompareOrdinal($expires, $now) -le 0) {
            Stop-Install "the release manifest for $channel expired on $expires; new installs resume when Happonomy re-signs it; an installed cube keeps working"
        }
        $targetLines = @($lines | Where-Object { $_.StartsWith('    "' + $target + '": {') })
        if ($targetLines.Count -ne 1) {
            Stop-Install "the manifest lists no single build for $target"
        }
        if ($targetLines[0] -cmatch '"url": "([^"]+)"') {
            $url = $Matches[1]
        } else {
            Stop-Install "the manifest's entry for $target has no url"
        }
        if ($targetLines[0] -cmatch '"sha256": "([0-9a-f]{64})"') {
            $sha = $Matches[1]
        } else {
            Stop-Install "the manifest's entry for $target has no SHA-256"
        }
        Test-CubeUrl $url
        $archiveName = $url.Substring($url.LastIndexOf('/') + 1)
        if ($archiveName -cnotmatch '^[0-9A-Za-z._+-]+\.zip$') {
            Stop-Install "the build for $target is not a .zip archive: $archiveName"
        }
        Write-Step "installing cube $version ($channel channel) for $target into $dir"

        # Check 3: GitHub's own record of the release must vouch for the archive.
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
        Get-CubeFile $url $archive
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

        # Every binary is first moved next to its final name. An old copy left
        # by an earlier install must go first, so nothing is swapped while one
        # is still running.
        foreach ($binary in $binaries) {
            $old = Join-Path $dir ($binary.BaseName + '.old.exe')
            if (Test-Path -LiteralPath $old) {
                try {
                    Remove-Item -LiteralPath $old -Force
                } catch {
                    Stop-Install "$old is still running; close every cube window and run the installer again; nothing was installed"
                }
            }
            $temp = Join-Path $dir ".cube-new.$PID.$($binary.Name)"
            Move-Item -LiteralPath $binary.FullName -Destination $temp
            $staged += $temp
        }
        # A running cube.exe cannot be overwritten but can be renamed: the
        # current copy moves aside to <name>.old.exe, then the new one takes
        # its name.
        $names = @()
        foreach ($binary in $binaries) {
            $final = Join-Path $dir $binary.Name
            $old = Join-Path $dir ($binary.BaseName + '.old.exe')
            $temp = Join-Path $dir ".cube-new.$PID.$($binary.Name)"
            $movedAside = $false
            if (Test-Path -LiteralPath $final) {
                Move-Item -LiteralPath $final -Destination $old
                $movedAside = $true
            }
            try {
                Move-Item -LiteralPath $temp -Destination $final
            } catch {
                if ($movedAside) { Move-Item -LiteralPath $old -Destination $final }
                Stop-Install "could not replace ${final}: $($_.Exception.Message)"
            }
            $staged = @($staged | Where-Object { $_ -ne $temp })
            if ($movedAside) {
                try { Remove-Item -LiteralPath $old -Force } catch { Write-Step "the old $($binary.Name) is still running; $old goes at the next install" }
            }
            $names += $binary.Name
        }
    } finally {
        foreach ($leftover in $staged) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force }
        }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }

    # The user PATH lives in HKCU\Environment as an expandable string; it is
    # read without expanding %VARIABLES% so they survive the rewrite.
    try {
        $userKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $rawPath = [string]$userKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($rawPath -split ';' | Where-Object { $_ })
            $present = @($entries | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $dir })
            if ($present.Count -eq 0) {
                Write-Step "adding $dir to your user PATH (HKCU\Environment, value Path); open a new terminal to use cube"
                $userKey.SetValue('Path', (($entries + $dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                # Setting and clearing a user variable tells running programs
                # (Explorer, new terminals) that the environment changed.
                [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', '1', 'User')
                [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', $null, 'User')
                $env:Path = "$env:Path;$dir"
            }
        } finally {
            $userKey.Close()
        }
    } catch {
        Write-Caution "could not add $dir to your user PATH ($($_.Exception.Message)); add it in Settings, System, About, Advanced system settings, Environment Variables"
    }

    Write-Step "installed cube $version ($channel) in ${dir}: $($names -join ' ')"
    $tagPage = $url.Substring(0, $url.LastIndexOf('/')) -replace '/download/[^/]+$', "/tag/$tag"
    Write-Step "the licence (LICENSE) and the third-party notices (THIRD-PARTY-NOTICES.md) are in the release archive: $tagPage"
}
