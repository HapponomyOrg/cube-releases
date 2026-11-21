# The Cube uninstaller for Windows (sub-spec c01/016; KB note 13, P14).
#
#   irm https://happonomyorg.github.io/cube-releases/uninstall.ps1 | iex
#
# Windows PowerShell 5.1 and PowerShell 7. It removes what install.ps1 and
# `cube setup` put on this machine for your account, and nothing else, in
# this order:
#
#   1. in each knowledge base it is pointed at -- the git repository it runs
#      in, the folders in CUBE_UNINSTALL_KBS, and every repository found
#      under the folders in CUBE_UNINSTALL_FIND -- the hooks `cube setup`
#      turned on: core.hooksPath when it is .cube/hooks, and then merge.ff
#      when it is false. (cube setup refuses on Windows in the alpha, so
#      normally there is none.) The KB's own files (.cube/ and
#      .claude/skills/cube/, committed by `cube adopt`) stay;
#   2. the global git settings `cube setup` writes: cube.path, cube.gitPath,
#      cube.ghPath, cube.python3Path and cube.allowUserOwned;
#   3. the programs (sub-spec c01/032): the directory junction current in
#      the install folder when it names a folder in versions\ (the switch
#      install.ps1 makes; it is removed as a link, never by entering the
#      folder it names; a current that names anything else stays), every
#      version folder in versions\, the binaries of an install in the
#      install folder itself (a 0.1.0 install: cube.exe, cube-index.exe and
#      cube-graph.exe; each of The Cube's programs, cube and its tools
#      cube-index, cube-graph, cube-audit, cube-archive, cube-ghost and
#      cube-ledger, only when it reports its own name and a version; another
#      program of the same name stays) and the .old.exe copies its updates
#      left, what an interrupted install left (.cube-new.* and .cube-old.* in
#      the folder and in versions\, .cube-install.* beside it), and the
#      folder itself when nothing else is in it;
#   4. the install folder's entries in your user PATH, ...\cube\current and
#      the install folder itself, which a 0.1.0 install added
#      (HKCU\Environment, value Path, kept an expandable string, so the other
#      entries' %VARIABLES% survive);
#   5. the hook cache, %LOCALAPPDATA%\Happonomy\cube\cache.
#
# It never enters a junction or a symbolic link: a link is removed itself or
# left as it is.
#
# Environment:
#   CUBE_INSTALL_DIR          the install folder (default: %LOCALAPPDATA%\Programs\cube)
#   CUBE_UNINSTALL_KBS        more knowledge bases to unhook, separated by ;
#   CUBE_UNINSTALL_FIND       folders to search for hooked knowledge bases, separated by ;
#   CUBE_UNINSTALL_DRY_RUN=1  print every step and change nothing
#
# ASCII only: Windows PowerShell 5.1 reads a script without a BOM as ANSI.
# Everything runs inside one script block, so nothing is left defined in
# your session and a download cut short does not parse.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $dryRun = ($env:CUBE_UNINSTALL_DRY_RUN -eq '1')
    $state = @{ Done = 0; Unhooked = 0; CubePathSet = $false; Seen = @{} }

    function Write-Step([string]$message) {
        Write-Host "uninstall.ps1: $message"
    }

    function Write-Caution([string]$message) {
        Write-Host "uninstall.ps1: warning: $message" -ForegroundColor Yellow
    }

    function Stop-Uninstall([string]$message) {
        throw "uninstall.ps1: error: $message"
    }

    # Prints a step and returns $true when it is to be done ($false in a dry
    # run, which only prints what it would do).
    function Test-Step([string]$description) {
        $state.Done += 1
        if ($dryRun) {
            Write-Step "would $description"
            return $false
        }
        Write-Step $description
        return $true
    }

    function Split-List([string]$value) {
        if (-not $value) { return @() }
        return @($value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    function Invoke-Git([string[]]$arguments) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $gitPath @arguments 2> $null
            return @{ Code = $LASTEXITCODE; Output = ((@($output) -join "`n").Trim()) }
        } finally {
            $ErrorActionPreference = $saved
        }
    }

    # Undoes cube setup in the git repository that holds $folder. A quiet
    # call (a repository it found or runs in) says nothing about one that is
    # not hooked.
    function Remove-KbHook([string]$folder, [bool]$quiet) {
        $top = Invoke-Git @('-C', $folder, 'rev-parse', '--show-toplevel')
        if ($top.Code -ne 0 -or -not $top.Output) {
            if (-not $quiet) { Write-Caution "$folder is not in a git repository: nothing to unhook there" }
            return
        }
        $root = $top.Output
        if ($state.Seen.ContainsKey($root)) { return }
        $state.Seen[$root] = $true
        $hooks = (Invoke-Git @('-C', $root, 'config', '--local', '--get', 'core.hooksPath')).Output
        if ($hooks -ne '.cube/hooks') {
            if (-not $quiet) {
                $shown = if ($hooks) { $hooks } else { 'not set' }
                Write-Step "$root is not hooked by cube setup (core.hooksPath: $shown); left as it is"
            }
            return
        }
        if (Test-Step "unhook ${root}: unset core.hooksPath (.cube/hooks)") {
            if ((Invoke-Git @('-C', $root, 'config', '--local', '--unset-all', 'core.hooksPath')).Code -ne 0) {
                Stop-Uninstall "could not unset core.hooksPath in $root"
            }
        }
        $ff = (Invoke-Git @('-C', $root, 'config', '--local', '--get', 'merge.ff')).Output
        if ($ff -eq 'false') {
            if (Test-Step "unhook ${root}: unset merge.ff (false, as cube setup sets it)") {
                if ((Invoke-Git @('-C', $root, 'config', '--local', '--unset-all', 'merge.ff')).Code -ne 0) {
                    Stop-Uninstall "could not unset merge.ff in $root"
                }
            }
        }
        $state.Unhooked += 1
        $kept = @()
        if (Test-Path -LiteralPath (Join-Path $root '.cube') -PathType Container) { $kept += '.cube/' }
        if (Test-Path -LiteralPath (Join-Path $root '.claude\skills\cube') -PathType Container) { $kept += '.claude/skills/cube/' }
        if ($kept.Count -gt 0) {
            Write-Step "$root keeps $($kept -join ' and '): the knowledge base's own committed files; remove them with a commit if you no longer want them"
        }
    }

    # Removes a file, a link, or a folder with everything in it. A junction
    # or a symbolic link is removed itself, never what it names:
    # [IO.Directory]::Delete without recursion removes the link only, and the
    # walk never enters a link, so no file outside the folder is touched.
    function Remove-CubeTree([string]$path) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not $item) { return }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.PSIsContainer) {
                [IO.Directory]::Delete($item.FullName, $false)
            } else {
                [IO.File]::Delete($item.FullName)
            }
        } elseif ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
                Remove-CubeTree $child.FullName
            }
            [IO.Directory]::Delete($item.FullName, $false)
        } else {
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }

    function Remove-Leftover([string]$path, [string]$why) {
        if (Test-Step "remove $path ($why)") {
            try {
                Remove-CubeTree $path
            } catch {
                Stop-Uninstall "could not remove $path ($($_.Exception.Message)); close every cube window and run the uninstaller again"
            }
        }
    }

    function Test-Link($item) {
        return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    }

    function Test-CubeLeftoverName([string]$name) {
        return ($name -clike '.cube-new.*' -or $name -clike '.cube-old.*')
    }

    if ($env:OS -ne 'Windows_NT') {
        Stop-Uninstall 'uninstall.ps1 is for Windows; on Linux and macOS run: curl -fsSL https://happonomyorg.github.io/cube-releases/uninstall.sh | sh'
    }
    if (-not $env:LOCALAPPDATA) {
        Stop-Uninstall 'LOCALAPPDATA is not set'
    }
    if ($dryRun) {
        Write-Step 'dry run: nothing is changed'
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $gitPath = if ($git) { $git.Source } else { $null }

    # 1. The knowledge bases cube setup hooked.
    if ($gitPath) {
        Remove-KbHook (Get-Location).ProviderPath $true
        foreach ($kb in Split-List $env:CUBE_UNINSTALL_KBS) {
            Remove-KbHook $kb $false
        }
        foreach ($folder in Split-List $env:CUBE_UNINSTALL_FIND) {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                Write-Caution "$folder is not a folder: not searched"
                continue
            }
            Write-Step "searching $folder for knowledge bases cube setup hooked"
            $found = @(Get-ChildItem -LiteralPath $folder -Directory -Recurse -Force -Filter '.cube' -ErrorAction SilentlyContinue)
            foreach ($dotCube in $found) {
                Remove-KbHook $dotCube.Parent.FullName $true
            }
        }
    } elseif ($env:CUBE_UNINSTALL_KBS -or $env:CUBE_UNINSTALL_FIND) {
        Write-Caution 'git is not on PATH, so no knowledge base can be unhooked'
    }

    # 2. The global git settings cube setup wrote.
    if ($gitPath) {
        foreach ($key in 'cube.path', 'cube.gitPath', 'cube.ghPath', 'cube.python3Path', 'cube.allowUserOwned') {
            $found = Invoke-Git @('config', '--global', '--get-all', $key)
            if ($found.Code -eq 0) {
                if ($key -eq 'cube.path') { $state.CubePathSet = $true }
                $shown = $found.Output -replace "`n", ' '
                if (Test-Step "remove $key from your global git config ($shown)") {
                    if ((Invoke-Git @('config', '--global', '--unset-all', $key)).Code -ne 0) {
                        Stop-Uninstall "could not remove $key from your global git config"
                    }
                }
            }
        }
        if (-not $dryRun -and (Invoke-Git @('config', '--global', '--get-regexp', '^cube\.')).Code -ne 0) {
            $null = Invoke-Git @('config', '--global', '--remove-section', 'cube')
        }
    }

    # 3. The binaries, the copies an update left and what an interrupted
    # install left.
    $dir = Join-Path $env:LOCALAPPDATA 'Programs\cube'
    if ($env:CUBE_INSTALL_DIR) { $dir = $env:CUBE_INSTALL_DIR }
    if ($dir -notmatch '^[A-Za-z]:[\\/]' -and $dir -notmatch '^\\\\[^\\]') {
        Stop-Uninstall "CUBE_INSTALL_DIR must be a full path such as C:\Tools\cube, not '$dir'"
    }
    $dir = $dir.TrimEnd('\', '/')
    $versionsDir = Join-Path $dir 'versions'
    $current = Join-Path $dir 'current'
    $versionName = '^[0-9A-Za-z+-][0-9A-Za-z.+-]*$'
    if (Test-Path -LiteralPath $dir -PathType Container) {
        # The switch first: the junction current, removed as a link when it
        # names a version folder.
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($currentItem -and (Test-Link $currentItem)) {
            $named = ([string]@($currentItem.Target)[0]) -replace '^(\\\\\?\\|\\\?\?\\)', ''
            if ($named -and (Split-Path -Parent $named).TrimEnd('\') -ieq $versionsDir -and (Split-Path -Leaf $named) -cmatch $versionName) {
                Remove-Leftover $current "the junction that makes $named current"
            } else {
                $shown = if ($named) { $named } else { 'a target it cannot read' }
                Write-Caution "$current is a link to $shown, not into The Cube's versions folder $versionsDir; it may be another program's, so it stays"
            }
        } elseif ($currentItem) {
            Write-Caution "$current is not a junction, which the installer never makes; it stays"
        }
        # A 0.1.0 install: the binaries in the install folder itself, looked
        # for under the name of each of The Cube's programs (sub-spec c01/018
        # phase 6).
        foreach ($name in 'cube', 'cube-index', 'cube-graph', 'cube-audit', 'cube-archive', 'cube-ghost', 'cube-ledger') {
            $exe = Join-Path $dir "$name.exe"
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                $reported = ''
                $saved = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $reported = (& $exe --version 2> $null | Out-String).Trim()
                } catch {
                    $reported = ''
                } finally {
                    $ErrorActionPreference = $saved
                }
                if ($reported -cmatch ('^' + [regex]::Escape($name) + ' [0-9]')) {
                    Remove-Leftover $exe $reported
                } else {
                    $shown = if ($reported) { $reported } else { 'nothing' }
                    Write-Caution "$exe does not report '$name <version>' (it reports: $shown); it may be another program, so it stays"
                }
            }
            $old = Join-Path $dir "$name.old.exe"
            if (Test-Path -LiteralPath $old -PathType Leaf) {
                Remove-Leftover $old 'left by an update'
            }
        }
        # What an interrupted install left: new and old junctions, and a
        # running 0.1.0 program renamed aside.
        foreach ($leftover in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { Test-CubeLeftoverName $_.Name })) {
            Remove-Leftover $leftover.FullName 'left by an interrupted install'
        }
        # Every version folder, and what an interrupted install left there.
        $versionsItem = Get-Item -LiteralPath $versionsDir -Force -ErrorAction SilentlyContinue
        if ($versionsItem -and (Test-Link $versionsItem)) {
            Write-Caution "$versionsDir is a link, which the installer never makes; it stays, and so does what it names"
        } elseif ($versionsItem -and $versionsItem.PSIsContainer) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $versionsDir -Force)) {
                if (Test-CubeLeftoverName $entry.Name) {
                    Remove-Leftover $entry.FullName 'left by an interrupted install'
                } elseif (Test-Link $entry) {
                    Write-Caution "$($entry.FullName) is a link, which the installer never makes; it stays"
                } elseif ($entry.PSIsContainer -and $entry.Name -cmatch $versionName) {
                    Remove-Leftover $entry.FullName "cube $($entry.Name)"
                }
            }
            if (-not $dryRun) {
                if (@(Get-ChildItem -LiteralPath $versionsDir -Force).Count -eq 0) {
                    [IO.Directory]::Delete($versionsDir, $false)
                } else {
                    Write-Step "$versionsDir still holds other files, so the folder stays"
                }
            }
        }
        $rest = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
        if ($dryRun) {
            Write-Step "would remove the folder $dir when nothing else is left in it"
        } elseif ($rest.Count -eq 0) {
            Remove-Leftover $dir 'now empty'
        } else {
            Write-Step "$dir still holds other files, so the folder stays"
        }
    }
    $parent = Split-Path -Parent $dir
    if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
        foreach ($stage in @(Get-ChildItem -LiteralPath $parent -Filter '.cube-install.*' -Directory -Force -ErrorAction SilentlyContinue)) {
            Remove-Leftover $stage.FullName 'left by an interrupted install'
        }
    }

    # 4. The install folder's entries in the user PATH: ...\current, and the
    # install folder itself, which a 0.1.0 install added. HKCU\Environment's
    # Path is read without expanding %VARIABLES% and written back as an
    # expandable string, as install.ps1 writes it.
    try {
        $userKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $rawPath = [string]$userKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($rawPath -split ';' | Where-Object { $_ })
            $keep = @()
            $gone = @()
            foreach ($entry in $entries) {
                $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                if ($expanded -ieq $current -or $expanded -ieq $dir) { $gone += $entry } else { $keep += $entry }
            }
            if ($gone.Count -gt 0) {
                if (Test-Step "remove $($gone -join ' and ') from your user PATH (HKCU\Environment, value Path)") {
                    $userKey.SetValue('Path', ($keep -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                    # Setting and clearing a user variable tells running
                    # programs (Explorer, new terminals) that it changed.
                    [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', '1', 'User')
                    [Environment]::SetEnvironmentVariable('CUBE_INSTALL_PATH_REFRESH', $null, 'User')
                }
            }
        } finally {
            $userKey.Close()
        }
    } catch {
        Write-Caution "could not remove $current from your user PATH ($($_.Exception.Message)); remove it in Settings, System, About, Advanced system settings, Environment Variables"
    }

    # 5. The hook cache, then its parent folders when they are empty.
    $happonomy = Join-Path $env:LOCALAPPDATA 'Happonomy'
    $cubeData = Join-Path $happonomy 'cube'
    $cache = Join-Path $cubeData 'cache'
    if (Test-Path -LiteralPath $cache -PathType Container) {
        Remove-Leftover $cache 'the hook cache'
    }
    if (-not $dryRun) {
        foreach ($folder in $cubeData, $happonomy) {
            if ((Test-Path -LiteralPath $folder -PathType Container) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) {
                Remove-Item -LiteralPath $folder -Force
            }
        }
    }

    # What is left to you.
    if ($state.CubePathSet) {
        if ($state.Unhooked -eq 0) {
            Write-Caution 'cube setup ran on this account (cube.path was set), but no knowledge base was unhooked: one still hooked stops every commit. In each knowledge base where you ran cube setup, run: git config --unset core.hooksPath; git config --unset merge.ff (or set CUBE_UNINSTALL_FIND to a folder and run this uninstaller again)'
        } else {
            Write-Step 'if you ran cube setup in other knowledge bases too, unhook each: git config --unset core.hooksPath; git config --unset merge.ff'
        }
    }
    if ($state.Done -eq 0) {
        Write-Step 'nothing of The Cube was found for this account'
    } elseif ($dryRun) {
        Write-Step "dry run done: $($state.Done) step(s) would run; run it again without CUBE_UNINSTALL_DRY_RUN to do them"
    } else {
        Write-Step "The Cube is removed ($($state.Done) step(s)); open a new terminal for the PATH change"
    }
}
