# Bakunawa.Cleanup.psm1 — Cleanup task execution

function Write-CommandLog {
    param([string]$Verb, [string]$Target)
    if ($Verb) { Update-UiTicker -CurrentOperation $Verb }
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Get-CleanupTasks {
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $tasks = [System.Collections.Generic.List[System.Object]]::new()
    $null = $tasks.Add([PSCustomObject]@{ Name = 'System Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'App Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Dev Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Game Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Cloud Sync'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Creative Apps'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Productivity'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'DevOps Tools'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'GPU/Shell Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Recycle Bin'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Log Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Empty/Stale Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Unused Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Orphan Scan'; Parallel = $false })
    if ($Mode -eq 'Aggressive') {
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Prefetch'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'DISM'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Event Logs + Font Cache'; Parallel = $false })
    }
    return @($tasks)
}

function Measure-AndClear {
    param([string]$Path, [switch]$EnsureDirectory, [string]$Category = 'General')
    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Container)) { return $false }
    if (-not (Test-SafeCleanupTarget -Path $resolved)) { return $false }

    $sizeBefore = Get-DirectorySize $resolved
    $verb = if($script:IsPreview){'PREVIEW'}else{'CLEAR'}
    Write-CommandLog $verb $resolved

    if (-not $script:IsPreview) {
        Get-ChildItem -LiteralPath $resolved -Force -EA SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue -ErrorVariable rmErr
            if ($rmErr) { $script:Errors += [PSCustomObject]@{ Path = $_.FullName; Exception = $rmErr[0].Exception.Message; Category = 'Remove-Item'; Timestamp = Get-Date } }
        }
        if ($EnsureDirectory -and -not (Test-Path -LiteralPath $resolved)) { New-Item -ItemType Directory -Path $resolved -Force | Out-Null }
        $sizeAfter = Get-DirectorySize $resolved
        $freed = [Math]::Max(0, $sizeBefore - $sizeAfter)
    } else { $freed = $sizeBefore }

    $script:BytesFreed += $freed
    if (-not $script:CategorySizes.ContainsKey($Category)) { $script:CategorySizes[$Category] = [long]0 }
    $script:CategorySizes[$Category] += $freed
    return $true
}

function Remove-FilesByPattern {
    param([string]$Directory, [string[]]$Patterns, [string]$Category='General')
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }
    $count = 0
    foreach ($pat in $Patterns) {
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        try {
            $di = [System.IO.DirectoryInfo]::new($Directory)
            foreach ($f in $di.EnumerateFiles($pat, [System.IO.SearchOption]::AllDirectories)) { $files.Add($f) }
        } catch {
            $files = Get-ChildItem -LiteralPath $Directory -Filter $pat -File -Force -Recurse -EA SilentlyContinue
        }
        foreach ($f in $files) {
            $full = $f.FullName
            if (Test-IsExcludedPath $full) { continue }
            $sz = $f.Length
            Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $full
            if (-not $script:IsPreview) {
                Remove-Item -LiteralPath $full -Force -EA SilentlyContinue
                if (-not (Test-Path -LiteralPath $full)) {
                    $script:BytesFreed += $sz
                    if(-not $script:CategorySizes.ContainsKey($Category)){$script:CategorySizes[$Category]=[long]0}
                    $script:CategorySizes[$Category] += $sz
                }
            } else {
                $script:BytesFreed += $sz
                if(-not $script:CategorySizes.ContainsKey($Category)){$script:CategorySizes[$Category]=[long]0}
                $script:CategorySizes[$Category] += $sz
            }
            $count++
        }
    }
    $count
}

# ========================================================================
# GENERIC JSON-DRIVEN CACHE CLEANUP
# ========================================================================

function Clear-AppCacheFromDefinition {
    param(
        [Parameter(Mandatory)]$AppDef,
        [string]$Category = 'App Caches',
        [string[]]$WarnOnlyNames = @()
    )
    $n = 0
    $appName = $AppDef.name
    $processName = $AppDef.process
    $locations = $AppDef.locations
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }

    if ($processName -and (Test-AnyProcessRunning -RunningProcesses $running -Names @($processName))) {
        Register-SkippedItem -Reason "close $appName before clearing its cache" -Target $appName
        return 0
    }

    if ($WarnOnlyNames -contains $appName) {
        $totalSize = [long]0
        foreach ($loc in $locations) {
            $resolved = Resolve-EnvTemplate -EnvVar $loc.env -SubPath $loc.path
            if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Container)) {
                $totalSize += Get-DirectorySize $resolved
            }
        }
        if ($totalSize -gt 0) {
            Write-Log "${appName}: $(Format-FileSize $totalSize) - SKIPPED (manual reinstall required)" 'WARN'
        }
        return 0
    }

    foreach ($loc in $locations) {
        $pathTemplate = $loc.path

        if ($pathTemplate -match '\{sub:(\w+)\}') {
            $subName = $Matches[1]
            $baseResolved = Resolve-EnvTemplate -EnvVar $loc.env
            if ($baseResolved -and (Test-Path -LiteralPath $baseResolved -PathType Container)) {
                $hit = $false
                Get-ChildItem $baseResolved -Directory -Recurse -Force -EA SilentlyContinue | Where-Object {
                    $_.Name -ieq $subName
                } | ForEach-Object {
                    if (Measure-AndClear $_.FullName -EnsureDirectory -Category $Category) { $hit = $true }
                }
                if ($hit) { $n++ }
            }
        } elseif ($pathTemplate -match '\{product\}') {
            $baseResolved = Resolve-EnvTemplate -EnvVar $loc.env
            if ($baseResolved -and (Test-Path -LiteralPath $baseResolved -PathType Container)) {
                $hit = $false
                Get-ChildItem $baseResolved -Directory -Force -EA SilentlyContinue | ForEach-Object {
                    foreach ($sub in @('log','tmp','caches')) {
                        $t = Join-Path $_.FullName $sub
                        if (Test-Path $t) { if (Measure-AndClear $t -EnsureDirectory -Category $Category) { $hit = $true } }
                    }
                }
                if ($hit) { $n++ }
            }
        } else {
            $resolved = Resolve-EnvTemplate -EnvVar $loc.env -SubPath $pathTemplate
            if ($resolved -and (Measure-AndClear $resolved -EnsureDirectory -Category $Category)) {
                $n++
            }
        }
    }

    if ($n -gt 0) { Write-Log "Cleaned: $appName" 'OK' }
    return $n
}

function Clear-AppsFromCategory {
    param(
        [Parameter(Mandatory)][string]$CategoryName,
        [string]$JsonCategory,
        [string]$CategoryLabel = 'App Caches',
        [string[]]$WarnOnlyNames = @()
    )
    $defs = Get-AppDefinitions -Category $JsonCategory
    $total = 0
    foreach ($app in $defs) {
        $total += Clear-AppCacheFromDefinition -AppDef $app -Category $CategoryLabel -WarnOnlyNames $WarnOnlyNames
    }
    return $total
}

# ========================================================================
# STEP 1: SYSTEM CACHES
# ========================================================================

function Clear-SystemCaches {
    $cat = 'System Caches'; $n = 0
    foreach ($t in @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader
    )) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }

    # Stop update services, clean SoftwareDistribution, restart
    $restart = @()
    try {
        foreach ($svc in 'wuauserv','bits','dosvc') {
            $s = Get-Service $svc -EA SilentlyContinue
            if ($s -and $s.Status -ne 'Stopped') {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW stop'}else{'STOP'})) $svc
                if (-not $script:IsPreview) { Stop-Service $svc -Force -EA SilentlyContinue; $restart += $svc }
            }
        }
        if ($script:SysLoc.SoftDistDL -and (Measure-AndClear $script:SysLoc.SoftDistDL -EnsureDirectory -Category $cat)) { $n++ }
        if ($script:SysLoc.DeliveryOpt -and (Measure-AndClear $script:SysLoc.DeliveryOpt -EnsureDirectory -Category $cat)) { $n++ }
    } finally {
        foreach ($svc in $restart) { Write-CommandLog 'START' $svc; Start-Service $svc -EA SilentlyContinue }
    }
    $n
}

# ========================================================================
# STEP 2: BROWSER CACHES — iterates ALL profiles
# ========================================================================

function Clear-ChromiumCaches {
    param([string]$UserDataRoot, [string]$Label)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) {
        'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') }
        'Opera' { @('opera') } 'Vivaldi'{ @('vivaldi') } default { @() }
    }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }
    # Iterate ALL profiles under User Data
    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache','ShaderCache','GrShaderCache','GraphiteDawnCache','DawnWebGPUCache','Local Storage')
    foreach ($prof in (Get-ChildItem $UserDataRoot -Directory -Force -EA SilentlyContinue)) {
        $hit = $false
        foreach ($cd in $cacheDirs) {
            $t = Join-Path $prof.FullName $cd
            if (Test-Path -LiteralPath $t) { [void](Measure-AndClear $t -EnsureDirectory -Category $cat); $hit=$true }
        }
        foreach ($extra in @(
            (Join-Path $prof.FullName 'Service Worker\CacheStorage'),
            (Join-Path $prof.FullName 'Service Worker\ScriptCache'),
            (Join-Path $prof.FullName 'Crashpad'),
            (Join-Path $prof.FullName 'blob_storage')
        )) {
            if (Test-Path -LiteralPath $extra) { [void](Measure-AndClear $extra -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { Write-Log "Cleaned $Label profile: $($prof.Name)" 'OK'; $n++ }
    }
    $n
}

function Clear-FirefoxCaches {
    $cat = 'Browser Caches'; $n = 0
    $root = Join-EnvPath 'LOCALAPPDATA' 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    if (Test-AnyProcessRunning -RunningProcesses $running -Names @('firefox')) {
        Register-SkippedItem -Reason 'close Firefox for a deeper cache cleanup' -Target 'Firefox'
        return 0
    }
    foreach ($p in (Get-ChildItem $root -Directory -Force -EA SilentlyContinue)) {
        $hit = $false
        foreach ($t in @('cache2','startupCache','thumbnails','shader-cache','OfflineCache')) {
            $fp = Join-Path $p.FullName $t
            if (Test-Path -LiteralPath $fp) { [void](Measure-AndClear $fp -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { Write-Log "Cleaned Firefox profile: $($p.Name)" 'OK'; $n++ }
    }
    $n
}

# ========================================================================
# STEP 3: APP CACHES — JSON-driven with process detection
# ========================================================================

function Clear-AppCaches {
    $cat = 'App Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'messaging' -CategoryLabel $cat
    $n += Clear-AppsFromCategory -JsonCategory 'apps' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 4: DEVELOPER TOOL CACHES — JSON-driven
# ========================================================================

function Clear-DevCaches {
    $cat = 'Dev Tool Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'devtools' -CategoryLabel $cat -WarnOnlyNames @('Go-mod-cache')
    $n
}

# ========================================================================
# STEP 5: GAME CACHES
# ========================================================================

function Clear-GameCaches {
    $cat = 'Game Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'games' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 6: CLOUD SYNC CACHES
# ========================================================================

function Clear-CloudSyncCaches {
    $cat = 'Cloud Sync Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'cloud' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 7: CREATIVE APP CACHES
# ========================================================================

function Clear-CreativeAppCaches {
    $cat = 'Creative App Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'creative' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 8: PRODUCTIVITY CACHES
# ========================================================================

function Clear-ProductivityCaches {
    $cat = 'Productivity Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'productivity' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 9: DEVOPS TOOL CACHES
# ========================================================================

function Clear-DevOpsCaches {
    $cat = 'DevOps Tool Caches'; $n = 0
    $n += Clear-AppsFromCategory -JsonCategory 'devops' -CategoryLabel $cat
    $n
}

# ========================================================================
# STEP 10: GPU & SHELL CACHES — with proper explorer.exe management
# ========================================================================

function Clear-GpuAndShellCaches {
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($t in @(
        (Join-EnvPath 'LOCALAPPDATA' 'D3DSCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\GLCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD\DxCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Intel\ShaderCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'CEF\Cache')
    )) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }

    # Thumbnail & icon caches — stop explorer, clear, restart
    $exRoot = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $exRoot) {
        $files = Get-ChildItem $exRoot -File -Force -EA SilentlyContinue | Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }
        if ($files) {
            $wasRunning = $false
            try {
                if (-not $script:IsPreview) {
                    $wasRunning = @(Get-Process explorer -EA SilentlyContinue).Count -gt 0
                    if ($wasRunning) { Write-CommandLog 'STOP' 'explorer.exe'; Stop-Process -Name explorer -Force -EA SilentlyContinue; Start-Sleep -Milliseconds 500 }
                }
                foreach ($f in $files) {
                    $sz = $f.Length
                    Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $f.FullName
                    if (-not $script:IsPreview) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue; $script:BytesFreed += $sz }
                    if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                    $script:CategorySizes[$cat] += $sz
                }
            } finally {
                if (-not $script:IsPreview -and $wasRunning) { Write-CommandLog 'START' 'explorer.exe'; Start-Process explorer.exe }
            }
            $n++
        }
    }
    $n
}

# ========================================================================
# STEP 11: RECYCLE BIN
# ========================================================================

function Clear-RecycleBinSafe {
    Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Recycle Bin'
    if (-not $script:IsPreview) { Clear-RecycleBin -Force -EA SilentlyContinue }
    return 1
}

# ========================================================================
# STEP 12: LOG FILES
# ========================================================================

function Clear-SystemLogFiles {
    $cat = 'Log Files'; $n = 0
    $logRoots = @(
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA'),
        $(if ($script:SysLoc) { $script:SysLoc.ProgramData })
    )
    $logFiles = Get-DisposableLogCandidates -Roots $logRoots -OlderThanDays 14 |
        Sort-Object LastWriteTime |
        Select-Object -First 400
    foreach ($file in $logFiles) {
        $sz = $file.Length
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'})) $file.FullName
        if (-not $script:IsPreview) {
            Remove-Item -LiteralPath $file.FullName -Force -EA SilentlyContinue
            if (-not (Test-Path -LiteralPath $file.FullName)) {
                $script:BytesFreed += $sz
                if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                $script:CategorySizes[$cat] += $sz
            }
        } else {
            $script:BytesFreed += $sz
            if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
            $script:CategorySizes[$cat] += $sz
        }
        $n++
    }
    $n
}

# ========================================================================
# STEP 13: EMPTY & STALE FOLDER CLEANUP
# ========================================================================

function Remove-EmptyDirectories {
    param([string[]]$Roots)
    $removed = 0
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            Get-ChildItem $root -Directory -Recurse -Force -EA SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object {
                if (Test-IsExcludedPath $_.FullName) { return }
                $has = Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue | Select-Object -First 1
                if (-not $has) {
                    Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-empty'}else{'RM-EMPTY'})) $_.FullName
                    if (-not $script:IsPreview) { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue }
                    $removed++
                }
            }
        } catch {}
    }
    return $removed
}

function Remove-StaleJunkFolders {
    param([string[]]$Roots)
    $removed = 0
    foreach ($directory in (Get-StaleDisposableDirectories -Roots $Roots -OlderThanDays 45 | Sort-Object FullName -Descending)) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-stale'}else{'RM-STALE'})) $directory.FullName
        if (-not $script:IsPreview) { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -EA SilentlyContinue }
        $removed++
    }
    return $removed
}

# ========================================================================
# STEP 10: UNUSED FILES & FOLDERS — scans entire C: drive
# ========================================================================

function Test-SafeToDelete {
    param([string]$FilePath, [string]$RootDir)
    $lower = $FilePath.ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName($FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

    # Never delete from Windows system directories
    $systemDirs = @(
        '\windows\system32', '\windows\syswow64', '\windows\winsxs',
        '\windows\servicing', '\windows\installer', '\windows\boot',
        '\program files\windows defender', '\program files\windows nt',
        '\program files\internet explorer', '\program files\windows mail',
        '\program files\windows photo viewer', '\program files\windows portable devices',
        '\program files\windows sidebar', '\program files\common files\microsoft shared',
        '\program files (x86)\common files\microsoft shared',
        '$recycle.bin', '\system volume information', '\recovery'
    )
    foreach ($sd in $systemDirs) {
        if ($lower.Contains($sd)) { return $false }
    }

    # Never delete critical file types
    $safeExts = @('.sys', '.drv', '.cat', '.msi', '.msp', '.mst', '.inf', '.inx', '.cod')
    if ($ext -in $safeExts) { return $false }

    # Never delete .exe or .dll in Program Files (installed programs)
    if ($ext -in @('.exe', '.dll', '.ocx') -and $lower.Contains('\program files')) { return $false }

    # Never delete files in Windows\Installer (patch cache)
    if ($lower.Contains('\windows\installer')) { return $false }

    # Never delete files in WinSxS (side-by-side assembly store)
    if ($lower.Contains('\winsxs')) { return $false }

    # Skip very small files (<1MB) unless they're known cache types
    $item = Get-Item -LiteralPath $FilePath -Force -EA SilentlyContinue
    if ($item -and $item.Length -lt 1MB) { return $false }

    # Skip files modified in last 7 days (might be active)
    if ($item -and $item.LastWriteTime -gt (Get-Date).AddDays(-7)) { return $false }

    return $true
}

function Find-UnusedFiles {
    [CmdletBinding()]
    param([switch]$InteractiveDelete, [int]$UnusedDays = 90)

    if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }

    $unusedCutoff = (Get-Date).AddDays(-$UnusedDays)
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $results = [System.Collections.Generic.List[System.Object]]::new()

    Write-Log "Scanning entire C: drive for unused files (not accessed in $UnusedDays+ days, >10MB)..." 'INFO'
    Write-Host ''
    Write-Host 'Scanning C: drive for unused files...' -ForegroundColor Cyan

    # AppData: scan each app subdirectory 5 levels deep
    $appdataRoots = @(
        @{ Path = (Get-EnvPath 'LOCALAPPDATA'); Label = '%LOCALAPPDATA%' },
        @{ Path = (Get-EnvPath 'APPDATA'); Label = '%APPDATA%' },
        @{ Path = $env:PROGRAMDATA; Label = '%PROGRAMDATA%' },
        @{ Path = (Get-EnvPath 'TEMP'); Label = '%TEMP%' }
    )
    foreach ($rootInfo in $appdataRoots) {
        $root = $rootInfo.Path
        $label = $rootInfo.Label
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Write-Log "Scanning $label..." 'INFO'
        Write-Host "  Scanning $label..." -ForegroundColor DarkGray
        try {
            $appDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
            $scanned = 0
            foreach ($appDir in $appDirs) {
                $appPath = Resolve-FullPath $appDir.FullName
                if (-not $appPath) { continue }
                $scanned++
                try {
                    $files = @(Get-ChildItem -LiteralPath $appPath -File -Force -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastAccessTime -lt $unusedCutoff -and $_.Length -gt 10MB } |
                        Select-Object -First 20)
                    foreach ($f in $files) {
                        $fullPath = Resolve-FullPath $f.FullName
                        if (-not $fullPath) { continue }
                        if (Test-IsExcludedPath $fullPath) { continue }
                        if (-not (Test-SafeToDelete -FilePath $fullPath -RootDir $root)) { continue }
                        $unusedDays = [int]((Get-Date) - $f.LastAccessTime).TotalDays
                        $sizeStr = Format-FileSize $f.Length
                        $risk = if ($unusedDays -ge 180) { 'High' } elseif ($unusedDays -ge 90) { 'Medium' } else { 'Low' }
                        $color = if ($unusedDays -ge 180) { 'Red' } elseif ($unusedDays -ge 90) { 'Yellow' } else { 'Green' }
                        Write-Log "UNUSED? $risk ($sizeStr, ${unusedDays}d stale) -> $fullPath" 'WARN'
                        Write-Host "    [$risk] $sizeStr  ${unusedDays}d  $fullPath" -ForegroundColor $color
                        $results.Add([PSCustomObject]@{
                            Path = $fullPath; Size = $f.Length; AgeDays = $unusedDays
                            Score = [Math]::Min(70, 20 + [int]($unusedDays / 10))
                            RiskLevel = $risk; Color = $color; Type = 'Unused'
                        })
                    }
                } catch {}
            }
            Write-Log "  $label : scanned $scanned directories" 'INFO'
        } catch {}
    }

    # Program Files: scan 3 levels deep
    foreach ($pfInfo in @(
        @{ Path = (Join-Path $systemDrive 'Program Files'); Label = 'Program Files' },
        @{ Path = (Join-Path $systemDrive 'Program Files (x86)'); Label = 'Program Files (x86)' }
    )) {
        $pf = $pfInfo.Path
        $label = $pfInfo.Label
        if (-not (Test-Path -LiteralPath $pf -PathType Container)) { continue }
        Write-Log "Scanning $label..." 'INFO'
        Write-Host "  Scanning $label..." -ForegroundColor DarkGray
        try {
            $files = @(Get-ChildItem -LiteralPath $pf -File -Force -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.LastAccessTime -lt $unusedCutoff -and $_.Length -gt 10MB } |
                Select-Object -First 30)
            foreach ($f in $files) {
                $fullPath = Resolve-FullPath $f.FullName
                if (-not $fullPath) { continue }
                if (Test-IsExcludedPath $fullPath) { continue }
                if (-not (Test-SafeToDelete -FilePath $fullPath -RootDir $pf)) { continue }
                $unusedDays = [int]((Get-Date) - $f.LastAccessTime).TotalDays
                $sizeStr = Format-FileSize $f.Length
                $risk = if ($unusedDays -ge 180) { 'High' } elseif ($unusedDays -ge 90) { 'Medium' } else { 'Low' }
                $color = if ($unusedDays -ge 180) { 'Red' } elseif ($unusedDays -ge 90) { 'Yellow' } else { 'Green' }
                Write-Log "UNUSED? $risk ($sizeStr, ${unusedDays}d stale) -> $fullPath" 'WARN'
                Write-Host "    [$risk] $sizeStr  ${unusedDays}d  $fullPath" -ForegroundColor $color
                $results.Add([PSCustomObject]@{
                    Path = $fullPath; Size = $f.Length; AgeDays = $unusedDays
                    Score = [Math]::Min(70, 20 + [int]($unusedDays / 10))
                    RiskLevel = $risk; Color = $color; Type = 'Unused'
                })
            }
            Write-Log "  $label : $($files.Count) unused files found" 'INFO'
        } catch {}
    }

    $sorted = @($results | Sort-Object Score -Descending)

    if ($sorted.Count -eq 0) {
        Write-Log 'No unused files found.' 'OK'
        Write-Host '  No unused files found.' -ForegroundColor Green
        return 0
    }

    $totalSize = ($sorted | Measure-Object -Property Size -Sum).Sum
    Write-Log "Found $($sorted.Count) unused files ($(Format-FileSize $totalSize) total):" 'WARN'
    Write-Host ''
    Write-Host "Found $($sorted.Count) unused files ($(Format-FileSize $totalSize) total):" -ForegroundColor Yellow
    foreach ($o in $sorted) {
        $sizeStr = Format-FileSize $o.Size
        Write-Log "UNUSED $($o.RiskLevel) ($sizeStr, $($o.AgeDays)d stale) -> $($o.Path)" 'WARN'
        Write-Host ("  [{0,-6}] {1,-5}d {2,10}  {3}" -f $o.RiskLevel, $o.AgeDays, $sizeStr, $o.Path) -ForegroundColor $o.Color
    }

    if ($InteractiveDelete -and $sorted.Count -gt 0) {
        Write-Host ''
        Write-Host 'Review unused files — "y" = delete, "n" = skip, "a" = delete all high-risk' -ForegroundColor Yellow
        Write-Host ''
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $o = $sorted[$i]
            $sizeStr = Format-FileSize $o.Size
            Write-Host ("[{0,2}] ({1,-6}) {2,-5}d {3,10}  {4}" -f ($i+1), $o.RiskLevel, $o.AgeDays, $sizeStr, $o.Path) -ForegroundColor $o.Color -NoNewline
            $resp = (Read-Host '  Delete? [y/N/a]').Trim().ToLowerInvariant()
            if ($resp -eq 'y') {
                Write-CommandLog 'REMOVE' $o.Path
                if (-not $script:IsPreview) {
                    Remove-Item -LiteralPath $o.Path -Force -EA SilentlyContinue
                    if (-not (Test-Path -LiteralPath $o.Path)) {
                        if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
                        $script:BytesFreed += $o.Size
                        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                        if(-not $script:CategorySizes.ContainsKey('Unused')){$script:CategorySizes['Unused']=[long]0}
                        $script:CategorySizes['Unused'] += $o.Size
                        Write-Log "Deleted: $($o.Path)" 'OK'
                    }
                }
            } elseif ($resp -eq 'a') {
                for ($j = $i; $j -lt $sorted.Count; $j++) {
                    if ($sorted[$j].RiskLevel -eq 'High') {
                        $hj = $sorted[$j]
                        Write-CommandLog 'REMOVE' $hj.Path
                        if (-not $script:IsPreview) {
                            Remove-Item -LiteralPath $hj.Path -Force -EA SilentlyContinue
                            if (-not (Test-Path -LiteralPath $hj.Path)) {
                                if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
                                $script:BytesFreed += $hj.Size
                                if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                                if(-not $script:CategorySizes.ContainsKey('Unused')){$script:CategorySizes['Unused']=[long]0}
                                $script:CategorySizes['Unused'] += $hj.Size
                            }
                        }
                    }
                }
                Write-Log 'Deleted all high-risk unused files.' 'OK'
                break
            }
        }
        if ($script:BytesFreed -gt 0) {
            Write-Log "Deletion complete. Freed $(Format-FileSize $script:BytesFreed)." 'OK'
        } else {
            Write-Log 'No files deleted.' 'INFO'
        }
    }

    return $sorted.Count
}

# ========================================================================
# STEP 11: ORPHAN SCAN — with interactive delete
# ========================================================================

function Find-OrphanFolders {
    [CmdletBinding()]
    param([switch]$InteractiveDelete, [int]$UnusedDays = 90)

    if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }

    $userRoots = @(
        (Join-EnvPath 'USERPROFILE' 'Documents'),
        (Join-EnvPath 'USERPROFILE' 'Downloads'),
        (Join-EnvPath 'USERPROFILE' 'Desktop'),
        (Join-EnvPath 'USERPROFILE' 'Pictures'),
        (Join-EnvPath 'USERPROFILE' 'Videos'),
        (Join-EnvPath 'USERPROFILE' 'Music'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        (Get-EnvPath 'TEMP'),
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA')
    )

    # Build known-good paths from app definitions + system paths
    $knownGoodApps = New-TrackedSet
    $applist = Get-AllAppDefinitions
    foreach ($app in $applist) {
        if ($app.locations) {
            foreach ($loc in $app.locations) {
                $resolved = Resolve-EnvTemplate -EnvVar $loc.env -SubPath $loc.path
                if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Container)) {
                    [void]$knownGoodApps.Add($resolved.ToLowerInvariant())
                }
            }
        }
    }
    # System-level safe paths
    foreach ($sp in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, (Get-EnvPath 'TEMP'), $env:PROGRAMDATA, $env:ProgramFiles, $env:WINDIR)) {
        if ($sp) { [void]$knownGoodApps.Add($sp.ToLowerInvariant()) }
    }

    # Hardcoded safe folder names (system + well-known apps)
    $safeNames = New-TrackedSet
    @(
        'Microsoft','Google','Mozilla','Windows','Common Files','Reference Assemblies',
        'dotnet','MSBuild','WindowsPowerShell','Packages','assembly','Programs','cache',
        'ConnectedDevicesPlatform','IdentityNexusIntegration','IsolatedStorage','ProductData',
        'Publishers','speech','Temp','node','npm','pip','Sentry','ServiceHub',
        'Package Cache','NuGet','aws','gcloud','uv','pnpm-cache','npm-cache','pnpm-state',
        'PlaceholderTileLogoFolder','Comms','firebase-heartbeat','cloud-code',
        'google-vscode-extension','github-copilot','vscode-sqltools','prisma-nodejs',
        'checkpoint-nodejs','ms-playwright','ms-playwright-go',
        '.IdentityService','.certifi',
        'GitHub','Slack','Teams','Discord','Spotify','Telegram Desktop',
        'Notion','Figma','Zoom','Viber','Adobe','obs-studio','qBittorrent',
        'draw.io','Stremio','Docker','Canva','Postman','Insomnia',
        '1Password','Bitwarden','Signal','Sublime Text','GitHubDesktop',
        'OpenVPN','Tailscale','Cloudflare','GitExtensions','Sourcetree',
        'MongoDBCompass','Tableau','PyCharm','IntelliJ','Rider','WebStorm',
        'Goland','CLion','DataGrip','RubyMine','AppCode','PhpStorm'
    ) | ForEach-Object { [void]$safeNames.Add($_) }

    $orphans = [System.Collections.Generic.List[System.Object]]::new()
    $installedNames = @($applist | Where-Object { $_.name } | ForEach-Object { $_.name.ToLowerInvariant() })
    $runningNames = @()
    if ($script:RunningProcesses) { $runningNames = @($script:RunningProcesses) }

    Write-Log "Scanning $($userRoots.Count) roots for orphan folders..." 'INFO'
    Write-Host ''
    Write-Host 'Scanning for orphan folders...' -ForegroundColor Cyan

    foreach ($root in $userRoots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $label = $root
        Write-Log "Scanning $label..." 'INFO'
        Write-Host "  Scanning $label..." -ForegroundColor DarkGray
        try {
            $dirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
            Write-Log "  $($root): $($dirs.Count) directories" 'INFO'
            foreach ($dir in $dirs) {
                $fullPath = Resolve-FullPath $dir.FullName
                if (-not $fullPath) { continue }
                if (Test-IsExcludedPath $fullPath) { continue }

                # Skip known-good paths
                $isKnown = $false
                foreach ($known in $knownGoodApps) {
                    if ($fullPath.ToLowerInvariant().StartsWith($known)) { $isKnown = $true; break }
                }
                if ($isKnown) { continue }

                # Skip safe folder names
                if ($safeNames.Contains($dir.Name)) { continue }

                # Check age and size
                try {
                    $ageDays = [int]((Get-Date) - $dir.CreationTime).TotalDays
                    if ($ageDays -le 30) { continue }
                    $size = Get-DirectorySize $fullPath
                    if ($size -le 1MB) { continue }

                    # Use the proper risk scoring from Core
                    $risk = Get-OrphanRiskScore -Name $dir.Name -SizeBytes $size -DaysStale $ageDays -PathSuffix $root -InstalledNames $installedNames -RunningNames $runningNames
                    Write-Log "ORPHAN? $($risk.RiskLevel) $($dir.Name) ($(Format-FileSize $size), ${ageDays}d stale) -> $fullPath" 'WARN'
                    Write-Host ("  [{0,-6}] {1,-5}d {2,10}  {3}" -f $risk.RiskLevel, $ageDays, (Format-FileSize $size), $fullPath) -ForegroundColor $risk.Color
                    $orphans.Add([PSCustomObject]@{
                        Path = $fullPath
                        Size = $size
                        AgeDays = $ageDays
                        Score = $risk.Score
                        RiskLevel = $risk.RiskLevel
                        Color = $risk.Color
                        Type = 'Orphan'
                    })
                } catch {}
            }
        } catch {}
    }

    # Sort by score descending
    $sorted = @($orphans | Sort-Object Score -Descending)

    # Store in script scope
    $script:OrphanFolders = $sorted
    $script:LastOrphanRisks = [PSCustomObject]@{
        Count = $sorted.Count
        HighCount = @($sorted | Where-Object { $_.RiskLevel -eq 'High' }).Count
        MedCount = @($sorted | Where-Object { $_.RiskLevel -eq 'Medium' }).Count
        LowCount = @($sorted | Where-Object { $_.RiskLevel -eq 'Low' }).Count
    }

    # Display results
    if ($sorted.Count -eq 0) {
        Write-Log 'No orphan folders found.' 'OK'
        Write-Host '  No orphan folders found.' -ForegroundColor Green
        return 0
    }

    $highC = @($sorted | Where-Object { $_.RiskLevel -eq 'High' }).Count
    $medC = @($sorted | Where-Object { $_.RiskLevel -eq 'Medium' }).Count
    $lowC = @($sorted | Where-Object { $_.RiskLevel -eq 'Low' }).Count
    Write-Log "Found $($sorted.Count) orphan folders ($highC high, $medC medium, $lowC low risk)" 'WARN'
    Write-Log 'These folders belong to apps that appear uninstalled and untouched 30+ days.' 'INFO'
    Write-Host ''
    Write-Host "Found $($sorted.Count) orphan folders ($highC high, $medC medium, $lowC low risk):" -ForegroundColor Yellow
    foreach ($o in $sorted) {
        $sizeStr = Format-FileSize $o.Size
        Write-Log "ORPHAN $($o.RiskLevel) $($o.Path) ($sizeStr, $($o.AgeDays)d stale)" 'WARN'
        Write-Host ("  [{0,-6}] {1,-5}d {2,10}  {3}" -f $o.RiskLevel, $o.AgeDays, $sizeStr, $o.Path) -ForegroundColor $o.Color
    }

    # Interactive delete mode
    if ($InteractiveDelete -and $sorted.Count -gt 0) {
        Write-Host ''
        Write-Host 'Interactive orphan review — "y" = delete, "n" = skip, "a" = delete all high-risk' -ForegroundColor Yellow
        Write-Host ''
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $o = $sorted[$i]
            $sizeStr = Format-FileSize $o.Size
            Write-Host ("[{0,2}] ({1,-6}) {2,-5}d {3,10}  {4}" -f ($i+1), $o.RiskLevel, $o.AgeDays, $sizeStr, $o.Path) -ForegroundColor $o.Color -NoNewline
            $resp = (Read-Host '  Delete? [y/N/a]').Trim().ToLowerInvariant()
            if ($resp -eq 'y') {
                Write-CommandLog 'REMOVE' $o.Path
                if (-not $script:IsPreview) {
                    Remove-Item -LiteralPath $o.Path -Recurse -Force -EA SilentlyContinue
                    if (-not (Test-Path -LiteralPath $o.Path)) {
                        if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
                        $script:BytesFreed += $o.Size
                        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                        if(-not $script:CategorySizes.ContainsKey('Orphans')){$script:CategorySizes['Orphans']=[long]0}
                        $script:CategorySizes['Orphans'] += $o.Size
                        Write-Log "Deleted: $($o.Path)" 'OK'
                    }
                }
            } elseif ($resp -eq 'a') {
                for ($j = $i; $j -lt $sorted.Count; $j++) {
                    if ($sorted[$j].RiskLevel -eq 'High') {
                        $hj = $sorted[$j]
                        Write-CommandLog 'REMOVE' $hj.Path
                        if (-not $script:IsPreview) {
                            Remove-Item -LiteralPath $hj.Path -Recurse -Force -EA SilentlyContinue
                            if (-not (Test-Path -LiteralPath $hj.Path)) {
                                if (-not $script:BytesFreed) { $script:BytesFreed = [long]0 }
                                $script:BytesFreed += $hj.Size
                                if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                                if(-not $script:CategorySizes.ContainsKey('Orphans')){$script:CategorySizes['Orphans']=[long]0}
                                $script:CategorySizes['Orphans'] += $hj.Size
                            }
                        }
                    }
                }
                Write-Log 'Deleted all high-risk items.' 'OK'
                break
            }
        }
        if ($script:BytesFreed -gt 0) {
            Write-Log "Deletion complete. Freed $(Format-FileSize $script:BytesFreed)." 'OK'
        } else {
            Write-Log 'No items deleted.' 'INFO'
        }
    }

    return $sorted.Count
}

# ========================================================================
# AGGRESSIVE MODE EXTRAS
# ========================================================================

function Clear-Prefetch {
    if (-not $script:SysLoc.Prefetch) { return 0 }
    $cat = 'Prefetch'; $n = 0
    if (Measure-AndClear $script:SysLoc.Prefetch -Category $cat) { $n++ }
    Write-Log "Prefetch cleared ($n directory)." 'OK'
    return $n
}

function Clear-EventLogs {
    $cat = 'Event Logs'; $n = 0
    try {
        $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.IsEnabled -eq $true }
        foreach ($log in $logs) {
            if ($log.LogName -notin @('System','Application','Security')) {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW clear-log'}else{'CLEAR-LOG'})) $log.LogName
                if (-not $script:IsPreview) {
                    try { wevtutil cl $log.LogName 2>$null; $n++ } catch {}
                } else { $n++ }
            }
        }
    } catch {}
    return $n
}

function Clear-FontCache {
    $cat = 'Font Cache'; $n = 0
    # Stop FontCache service, clear, restart
    $fcService = Get-Service FontCache -EA SilentlyContinue
    $wasRunning = $false
    try {
        if ($fcService -and $fcService.Status -ne 'Stopped') {
            Write-CommandLog ($(if($script:IsPreview){'PREVIEW stop'}else{'STOP'})) 'FontCache'
            if (-not $script:IsPreview) { Stop-Service FontCache -Force -EA SilentlyContinue; $wasRunning = $true; Start-Sleep -Milliseconds 1000 }
        }
        # Clear FontCache directory — some files may remain locked, that's expected
        $fcPath = Join-EnvPath 'SYSTEMROOT' 'ServiceProfiles\LocalService\AppData\Local\FontCache'
        if ($fcPath -and (Test-Path -LiteralPath $fcPath -PathType Container)) {
            $sizeBefore = Get-DirectorySize $fcPath
            Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) $fcPath
            if (-not $script:IsPreview) {
                Get-ChildItem -LiteralPath $fcPath -Force -EA SilentlyContinue | ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue 2>$null
                }
            }
            $sizeAfter = Get-DirectorySize $fcPath
            $freed = [Math]::Max(0, $sizeBefore - $sizeAfter)
            $script:BytesFreed += $freed
            if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
            $script:CategorySizes[$cat] += $freed
            if ($freed -gt 0) { $n++ }
        }
        # Also clear the system font cache file
        $fnPath = Join-EnvPath 'SYSTEMROOT' 'System32\FNTCACHE.DAT'
        if ($fnPath -and (Test-Path -LiteralPath $fnPath -PathType Leaf)) {
            $sz = (Get-Item -LiteralPath $fnPath -EA SilentlyContinue).Length
            if ($sz -gt 0) {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW del'}else{'DEL'})) $fnPath
                if (-not $script:IsPreview) { Remove-Item -LiteralPath $fnPath -Force -EA SilentlyContinue 2>$null }
                $script:BytesFreed += $sz
                if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                $script:CategorySizes[$cat] += $sz
                $n++
            }
        }
    } finally {
        if ($wasRunning -and -not $script:IsPreview) { Write-CommandLog 'START' 'FontCache'; Start-Service FontCache -EA SilentlyContinue }
    }
    return $n
}

function Invoke-ComponentCleanup {
    $cat = 'Component Store'; $n = 0
    Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'RUN'})) 'DISM /online /Cleanup-Image /StartComponentCleanup'
    if (-not $script:IsPreview) {
        try {
            $p = Start-Process -FilePath 'dism.exe' -ArgumentList '/online','/Cleanup-Image','/StartComponentCleanup','/Quiet','/NoRestart' -NoNewWindow -Wait -PassThru -EA SilentlyContinue
            if ($p.ExitCode -eq 0) {
                Write-Log 'DISM component cleanup completed successfully.' 'OK'
                $n++
            } else {
                Write-Log "DISM exited with code $($p.ExitCode). Some components may remain." 'WARN'
            }
        } catch {
            Write-Log "DISM failed: $_" 'ERR'
        }
    } else {
        $n++
    }
    return $n
}

# ========================================================================
# PARALLEL EXECUTION ENGINE
# ========================================================================

function Invoke-ParallelCleanup {
    param(
        [System.Collections.Generic.List[System.Object]]$Tasks,
        [hashtable]$StepCounts
    )
    $maxRunspaces = 4
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxRunspaces)
    $runspacePool.Open()

    $jobs = [System.Collections.Generic.List[System.Object]]::new()
    $taskMap = @{
        'Browser Caches' = {
            $count = 0
            $chrome = Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data'
            if ($chrome) { $count += Clear-ChromiumCaches -UserDataRoot $chrome -Label 'Chrome' }
            $edge = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data'
            if ($edge) { $count += Clear-ChromiumCaches -UserDataRoot $edge -Label 'Edge' }
            $brave = Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data'
            if ($brave) { $count += Clear-ChromiumCaches -UserDataRoot $brave -Label 'Brave' }
            $opera = Join-EnvPath 'APPDATA' 'Opera Software\Opera Stable'
            if ($opera) { $count += Clear-ChromiumCaches -UserDataRoot $opera -Label 'Opera' }
            $vivaldi = Join-EnvPath 'LOCALAPPDATA' 'Vivaldi\User Data'
            if ($vivaldi) { $count += Clear-ChromiumCaches -UserDataRoot $vivaldi -Label 'Vivaldi' }
            $count += Clear-FirefoxCaches
            return $count
        }
        'App Caches' = { return Clear-AppCaches }
        'Dev Caches' = { return Clear-DevCaches }
        'Game Caches' = { return Clear-GameCaches }
        'Cloud Sync' = { return Clear-CloudSyncCaches }
        'Creative Apps' = { return Clear-CreativeAppCaches }
        'Productivity' = { return Clear-ProductivityCaches }
        'DevOps Tools' = { return Clear-DevOpsCaches }
    }

    foreach ($task in $Tasks) {
        if (-not $task.Parallel) { continue }
        $taskName = $task.Name
        if (-not $taskMap.ContainsKey($taskName)) { continue }

        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($taskMap[$taskName])
        $jobs.Add([PSCustomObject]@{
            TaskName = $taskName
            PowerShell = $ps
            Handle = $ps.BeginInvoke()
        })
    }

    foreach ($job in $jobs) {
        try {
            $result = $job.PowerShell.EndInvoke($job.Handle)
            $count = if ($result -and $result.Count -gt 0) { $result[-1] } else { 0 }
            $StepCounts[$job.TaskName] = $count
        } catch {
            Write-Log "Parallel task $($job.TaskName) failed: $_" 'ERR'
            $StepCounts[$job.TaskName] = 0
        }
        $job.PowerShell.Dispose()
    }

    $runspacePool.Close()
    $runspacePool.Dispose()
}

# ========================================================================
# ORCHESTRATOR
# ========================================================================

function Invoke-CleanupRun {
    param(
        [ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard',
        [switch]$WhatIf
    )

    # Reset tracking variables
    $script:BytesFreed = 0
    $script:CategorySizes = @{}
    $script:Errors = @()
    $script:SkippedItems = @()
    $script:OrphanFolders = @()
    $script:RunningProcesses = Get-RunningProcessNames
    $script:IsPreview = ($WhatIf.IsPresent -or ($Mode -eq 'Preview'))
    $script:IsAggressive = ($Mode -eq 'Aggressive')
    $script:CurrentModeName = $Mode
    $script:StepIndex = 0

    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    $tasks = Get-CleanupTasks -Mode $effectiveMode
    $script:TotalSteps = $tasks.Count

    $startSpace = Get-FreeSpaceInfo
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Log "Mode: $Mode" 'INFO'
    Write-Log "Started: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" 'INFO'
    Write-Log "Initial free: $($startSpace.MB) MB ($($startSpace.GB) GB)" 'INFO'

    # Process tasks with step tracking
    $stepCounts = @{}
    $parallelTasks = [System.Collections.Generic.List[System.Object]]::new()
    $sequentialTasks = [System.Collections.Generic.List[System.Object]]::new()

    foreach ($task in $tasks) {
        if ($task.Parallel) { $parallelTasks.Add($task) } else { $sequentialTasks.Add($task) }
    }

    # Run parallel tasks together
    if ($parallelTasks.Count -gt 0) {
        Start-Step "Cache Cleanup (${($parallelTasks.Count)} categories)"
        Invoke-ParallelCleanup -Tasks $parallelTasks -StepCounts $stepCounts
        $parallelSummary = ($parallelTasks | ForEach-Object { "$($_.Name): $($stepCounts[$_.Name])" }) -join ', '
        Finish-Step $parallelSummary
    }

    # Run sequential tasks
    foreach ($task in $sequentialTasks) {
        $taskName = $task.Name
        Start-Step $taskName

        switch ($taskName) {
            'System Caches' { $s1 = Clear-SystemCaches; $stepCounts['System caches'] = $s1; Finish-Step "System caches: $s1 items" }
            'GPU/Shell Caches' { $s5 = Clear-GpuAndShellCaches; $stepCounts['GPU/Shell'] = $s5; Finish-Step "GPU/Shell: $s5 items" }
            'Recycle Bin' { Clear-RecycleBinSafe; $stepCounts['Recycle Bin'] = 1; Finish-Step 'Recycle Bin cleared' }
            'Log Files' { $s7 = Clear-SystemLogFiles; $stepCounts['Log files'] = $s7; Finish-Step "Log files: $s7 items" }
            'Empty/Stale Folders' {
                $junkRoots = @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp, $script:SysLoc.SoftDistDL, $script:SysLoc.DeliveryOpt) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
                $emptyDirs = Remove-EmptyDirectories -Roots $junkRoots
                $staleDirs = Remove-StaleJunkFolders -Roots $junkRoots
                $stepCounts['Empty folders'] = $emptyDirs
                $stepCounts['Stale junk'] = $staleDirs
                Finish-Step "Empty: $emptyDirs, Stale: $staleDirs"
            }
            'Unused Files' { $sUnused = Find-UnusedFiles; $stepCounts['Unused files'] = $sUnused; Finish-Step "Unused files: $sUnused found" }
            'Orphan Scan' { $s9 = Find-OrphanFolders; $stepCounts['Orphans'] = $s9; Finish-Step "Orphans: $s9 found" }
            'Prefetch' { Clear-Prefetch; $stepCounts['Prefetch'] = 1; Finish-Step 'Prefetch cleared' }
            'DISM' { $dism = Invoke-ComponentCleanup; $stepCounts['DISM'] = $dism; Finish-Step "DISM: $dism operations" }
            'Event Logs + Font Cache' {
                $evt = Clear-EventLogs
                $fnt = Clear-FontCache
                $stepCounts['Event logs'] = $evt
                $stepCounts['Font cache'] = $fnt
                Finish-Step "Event logs: $evt, Font cache: $fnt"
            }
        }
    }

    $sw.Stop()
    $endSpace = Get-FreeSpaceInfo

    # Store last run summary
    $freedMB = $endSpace.MB - $startSpace.MB
    $freedGB = [math]::Round($freedMB / 1024, 2)
    $script:LastRunSummary = [PSCustomObject]@{
        Mode = $Mode
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TotalFreed = [Math]::Max(0, $script:BytesFreed)
        FreedMB = $freedMB
        FreedGB = $freedGB
    }

    # Show the summary (formatted panel — no raw object return)
    Show-RunSummary -Mode $Mode -Duration $sw.Elapsed.TotalSeconds -StartSpace $startSpace -EndSpace $endSpace -StepCounts $stepCounts
}

Export-ModuleMember -Function Write-CommandLog, Get-CleanupTasks, Measure-AndClear, Remove-FilesByPattern, Clear-AppCacheFromDefinition, Clear-AppsFromCategory, Clear-SystemCaches, Clear-ChromiumCaches, Clear-FirefoxCaches, Clear-AppCaches, Clear-DevCaches, Clear-GameCaches, Clear-CloudSyncCaches, Clear-CreativeAppCaches, Clear-ProductivityCaches, Clear-DevOpsCaches, Clear-GpuAndShellCaches, Clear-RecycleBinSafe, Clear-SystemLogFiles, Remove-EmptyDirectories, Remove-StaleJunkFolders, Find-UnusedFiles, Find-OrphanFolders, Invoke-ComponentCleanup, Clear-EventLogs, Clear-Prefetch, Clear-FontCache, Invoke-ParallelCleanup, Invoke-CleanupRun