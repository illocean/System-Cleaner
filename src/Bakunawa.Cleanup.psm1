. (Join-Path $PSScriptRoot 'Bakunawa.Discovery.ps1')

# Bakunawa.Cleanup.psm1 â€” Cleanup task execution

# Write-Log is provided by Bakunawa.UI.psm1 (imported after this module with -Scope Global)
# so the global Write-Log will be the themed version from UI.psm1.

# NOTE FOR REVIEWERS: Measure-AndClear is the SINGLE error-collection boundary for deletion work.
# Its internal try/catch appends every terminating failure to $script:Errors - callers must NOT
# wrap Measure-AndClear calls in additional try/catch (that would double-collect).

# Private helper: one consistent sink for per-path cleanup errors (collect-errors-and-continue).
function Register-CleanupError {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path,
        [AllowEmptyString()][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $script:Errors) { $script:Errors = @() }
    $script:Errors += @{
        Path     = $Path
        Category = $(if ($Category) { $Category } else { 'Uncategorized' })
        Error    = $Message
    }
    if (Get-Command Write-ScanLogText -ErrorAction Ignore) { Write-ScanLogText ("CLEANUP ERROR | {0} | {1} | {2}" -f $Category, $Path, $Message) }
}

# Private helper: consolidated deletion logic respecting quarantine setting and preview mode.
# This function consolidates the branching logic for all three deletion paths to reduce code duplication
# and ensure consistent handling of quarantine mode and preview-mode safety.
# Returns validated bytes for preview or successful processing; failures throw.
function Remove-ItemSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$Reason = 'Cleanup',
        [ValidateSet('Tier1','Tier2','Tier3')][string]$Tier = 'Tier1',
        [string]$DetectorName = 'Cleanup',
        [switch]$Preview
    )
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\') -or
        $resolved -in @((Get-EnvPath 'USERPROFILE'),(Get-EnvPath 'LOCALAPPDATA'),(Get-EnvPath 'APPDATA'),(Get-EnvPath 'SystemRoot'),(Get-EnvPath 'ProgramData'),(Get-EnvPath 'ProgramFiles'),(Get-EnvPath 'ProgramFiles(x86)'))) {
        throw "Refusing to remove a drive or system/profile root: $resolved"
    }
    $excluded = @(Get-CoreExcludedPaths)
    if (Get-Command Get-QuarantineRoot -ErrorAction Ignore) { $excluded += Get-QuarantineRoot }
    $measurement = [Bakunawa.Scanner]::Inspect($resolved, [string[]]@($excluded | Where-Object { $_ }))
    if ($Preview -or $script:IsPreview) { return [long]$measurement.Bytes }
    if ($Tier -eq 'Tier3') { throw "Report-only candidate: $resolved" }
    if ($script:UseQuarantine) {
        $manifest = Move-ItemToQuarantine -Path $resolved -Reason $Reason -Tier $Tier -DetectorName $DetectorName
        if (-not $manifest) { throw "Quarantine failed: $resolved" }
        $script:QuarantinedBytes += $measurement.Bytes
    } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $resolved) { throw "Target remains after removal: $resolved" }
    }
    return [long]$measurement.Bytes
}

# Recursively expands {placeholder} tokens in a path by enumerating matching
# filesystem entries. Handles paths like <dir>/{profile}/Cache, where
# {profile} maps to Default/Profile 1/Profile 2/etc.
# Returns an array of fully-resolved absolute paths (never returns wildcard).
function Expand-WildcardPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$DirectoriesOnly
    )
    if ($Path -notmatch '^C:[\\/]') { return @() }
    $patternPath = $Path -replace '\{sub:([^}]+)\}', '$1' -replace '\{profile\}', '*'
    if ($patternPath -match '\{[^}]+\}') { throw "Unknown cleanup path placeholder: $Path" }
    if ($patternPath -notmatch '[*?]') {
        if ([Bakunawa.Scanner]::IsAllowedPath($patternPath)) { [IO.Path]::GetFullPath($patternPath) }
        return
    }
    # Expand one segment at a time so wildcards cannot traverse junctions first.
    $paths = @('C:\')
    foreach ($segment in ($patternPath.Substring(3) -split '[\\/]' | Where-Object { $_ })) {
        $paths = @(foreach ($parent in $paths) {
            if ($segment -match '[*?]') {
                $pattern = $segment.Replace('[', '`[').Replace(']', '`]')
                Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like $pattern -and [Bakunawa.Scanner]::IsAllowedPath($_.FullName) -and (-not $DirectoriesOnly -or $_.PSIsContainer) } |
                    ForEach-Object { $_.FullName }
            } else {
                $candidate = Join-Path $parent $segment
                if ([Bakunawa.Scanner]::IsAllowedPath($candidate) -and (Test-Path -LiteralPath $candidate)) { $candidate }
            }
        })
    }
    $paths
}

# Read-only accessor for collected cleanup errors (post-run reporting / diagnostics).
# Emits elements directly - callers normalize with @(); do NOT comma-wrap (double-wrap bug).
function Get-CleanupErrorLog {
    [CmdletBinding()]
    param()
    if ($script:Errors) { return @($script:Errors) }
}

function Measure-AndClear {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Path, [switch]$EnsureDirectory, [AllowEmptyString()][string]$Category)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Path)) {
        Register-SkippedItem -Reason 'C: only; linked, offline or inaccessible paths are skipped' -Target $Path
        $script:TaskSkipped++
        return $false
    }
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($script:ProcessedCacheRoots -and $script:ProcessedCacheRoots.Contains($Path)) { return $false }
    foreach ($busy in $script:BusyCachePaths) {
        if ([Bakunawa.Scanner]::Within($Path, $busy) -or [Bakunawa.Scanner]::Within($busy, $Path)) {
            Register-SkippedItem -Reason 'Close the owning app to clean this cache' -Target $Path
            $script:TaskSkipped++
            return $false
        }
    }
    if (Test-IsExcludedPath $Path) {
        Register-SkippedItem -Reason 'Path is excluded from cleanup' -Target $Path
        $script:TaskSkipped++
        return $false
    }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            if ($EnsureDirectory -and -not $script:IsPreview) {
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
                return $true
            }
            return $false
        }
        Write-ReviewLine ("{0}: {1}" -f $(if ($script:IsPreview) { 'Measuring' } else { 'Processing' }), $Path) -ForegroundColor Gray
        # Preserve the cache root and process siblings independently when one is locked.
        $size = 0L; $processed = 0
        foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            try {
                $size += Remove-ItemSafely -Path $item.FullName -Reason $(if ($Category) { $Category } else { 'Cache cleanup' }) -Preview:$script:IsPreview
                $processed++
            } catch { Register-CleanupError -Path $item.FullName -Category $Category -Message $_.Exception.Message }
        }
        if ($processed -eq 0) { return $false }
        if ($null -eq $script:ProcessedCacheRoots) { $script:ProcessedCacheRoots = New-TrackedSet }
        [void]$script:ProcessedCacheRoots.Add($Path)
        $script:BytesFreed += $size
        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
        if ($Category) { $script:CategorySizes[$Category] += $size }
        $script:TaskCleared++; $script:TaskBytes += $size
        Write-CommandLog $(if ($script:IsPreview) { 'PREVIEW' } else { 'PROCESSED' }) "$Path ($(Format-FileSize $size))"
        return $true
    } catch {
        Register-CleanupError -Path $Path -Category $Category -Message $_.Exception.Message
        return $false
    }
}

function Get-CleanupTasks {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $tasks = [System.Collections.Generic.List[System.Object]]::new()
    $null = $tasks.Add([PSCustomObject]@{ Name = 'System Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'App Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Dev Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Game Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Automation Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Package Manager Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Cloud Sync'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Creative Apps'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Productivity'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'DevOps Tools'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'GPU/Shell Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Recycle Bin'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Thumbnail Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Log Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Empty/Stale Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Orphan Scan'; Parallel = $false })
    if ($Mode -eq 'Aggressive') {
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Prefetch'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'DISM'; Parallel = $false })
        $null = $tasks.Add([PSCustomObject]@{ Name = 'Event Logs + Font Cache'; Parallel = $false })
    }
    $null = $tasks.Add([PSCustomObject]@{ Name = 'User Hidden Folders'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Scoop Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Rust Cargo Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Go Module Cache'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Bun Cache'; Parallel = $false })
    return @($tasks)
}

function Get-CleanupPotential {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard', [string]$TaskName)
    $results = [System.Collections.Generic.List[System.Object]]::new()
    $tasks = Get-CleanupTasks -Mode $Mode
    if ($TaskName) { $tasks = @($tasks | Where-Object { $_.Name -eq $TaskName }) }
    foreach ($task in $tasks) {
        $taskName = $task.Name
        $status = 'ok'
        $bytes = 0L
        $count = 0
        switch ($taskName) {
            'System Caches' {
                foreach ($t in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)) {
                    if ($t -and (Test-Path -LiteralPath $t -PathType Container)) {
                        $bytes += Get-DirectorySize $t
                        $count++
                    }
                }
            }
            'Browser Caches' {
                # Source from app definitions so Brave/Opera/Vivaldi/etc. are
                # fully covered (the prior hardcoded list missed them).
                $applist = Get-AllAppDefinitions -Category 'Browser Caches'
                foreach ($app in $applist) {
                    if (-not $app.Path) { continue }
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                    $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                    $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                    $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                    $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'App Caches' {
                $applist = Get-AllAppDefinitions -Category 'App Caches'
                foreach ($app in $applist) {
                    if (-not $app.Name) { continue }
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                    $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                    $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                    $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                    $expandedPath = $expandedPath -replace '{commonprogramfiles}', $env:COMMONPROGRAMFILES
                    $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                    $expandedPath = $expandedPath -replace '{windows}', $env:WINDIR
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Dev Caches' {
                foreach ($d in @(
                    (Join-EnvPath 'LOCALAPPDATA' 'npm' '_logs'),
                    (Join-EnvPath 'LOCALAPPDATA' 'pip' 'Cache'),
                    (Join-EnvPath 'LOCALAPPDATA' 'Yarn' 'Cache')
                )) {
                    if ($d -and (Test-Path -LiteralPath $d -PathType Container)) {
                        $bytes += Get-DirectorySize $d
                        $count++
                    }
                }
                # Process devtools-extended app definitions
                $extendedDefs = Get-AppDefinitions -Category 'devtools-extended' | Where-Object { $_.Category -eq 'Dev Caches' }
                foreach ($app in $extendedDefs) {
                    if (-not $app.Name) { continue }
                    try {
                        $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                        $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                        $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                        $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                        $expandedPath = $expandedPath -replace '{commonprogramfiles}', $env:COMMONPROGRAMFILES
                        $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                        $expandedPath = $expandedPath -replace '{windows}', $env:WINDIR
                        foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                            if (Test-Path -LiteralPath $resolved -PathType Container) {
                                $bytes += Get-DirectorySize $resolved
                                $count++
                            }
                        }
                    } catch {
                        Register-CleanupError -Path $expandedPath -Category 'Potential Scan' -Message $_.Exception.Message
                    }
                }
            }
            'User Hidden Folders' {
                foreach ($h in @((Join-EnvPath 'USERPROFILE' '.local'), (Join-EnvPath 'USERPROFILE' '.cache'), (Join-EnvPath 'LOCALAPPDATA' '.cache'))) {
                    if ($h -and (Test-Path -LiteralPath $h -PathType Container)) {
                        $bytes += Get-DirectorySize $h
                        $count++
                    }
                }
            }
            'Scoop Cache' {
                $scoopDir = (Join-EnvPath 'USERPROFILE' 'scoop' 'cache')
                if ($scoopDir -and (Test-Path -LiteralPath $scoopDir -PathType Container)) {
                    $bytes += Get-DirectorySize $scoopDir
                    $count++
                }
                $scoopApps = (Join-EnvPath 'USERPROFILE' 'scoop' 'apps')
                if ($scoopApps -and (Test-Path -LiteralPath $scoopApps -PathType Container)) {
                    $bytes += Get-DirectorySize $scoopApps
                    $count++
                }
            }
            'Rust Cargo Cache' {
                $cargoDir = (Join-EnvPath 'USERPROFILE' '.cargo')
                if ($cargoDir -and (Test-Path -LiteralPath $cargoDir -PathType Container)) {
                    $bytes += Get-DirectorySize $cargoDir
                    $count++
                }
            }
            'Go Module Cache' {
                $goDir = (Join-EnvPath 'USERPROFILE' 'go' 'pkg' 'mod')
                if ($goDir -and (Test-Path -LiteralPath $goDir -PathType Container)) {
                    $bytes += Get-DirectorySize $goDir
                    $count++
                }
                $goSumDir = (Join-EnvPath 'USERPROFILE' 'go' 'pkg' 'sumdb')
                if ($goSumDir -and (Test-Path -LiteralPath $goSumDir -PathType Container)) {
                    $bytes += Get-DirectorySize $goSumDir
                    $count++
                }
            }
            'Bun Cache' {
                $bunDir1 = (Join-EnvPath 'USERPROFILE' '.bun' 'install' 'cache')
                $bunDir2 = (Join-EnvPath 'LOCALAPPDATA' 'bun' 'install' 'cache')
                foreach ($bd in @($bunDir1, $bunDir2)) {
                    if ($bd -and (Test-Path -LiteralPath $bd -PathType Container)) {
                        $bytes += Get-DirectorySize $bd
                        $count++
                    }
                }
            }
            'Game Caches' {
                foreach ($gc in @(
                    (Join-EnvPath 'LOCALAPPDATA' 'Roblox' 'cache'),
                    "$(Join-EnvPath 'PROGRAMFILES' 'Steam')\steamapps\shadercache",
                    (Join-EnvPath 'PROGRAMDATA' 'Epic\UnrealEngineLauncher\Saved\Cache'),
                    (Join-EnvPath 'PROGRAMDATA' 'Battle.net\Cache')
                )) {
                    if ($gc -and (Test-Path -LiteralPath $gc -PathType Container)) {
                        $bytes += Get-DirectorySize $gc
                        $count++
                    }
                }
            }
            'Browser Automation Caches' {
                foreach ($bac in @(
                    (Join-EnvPath 'LOCALAPPDATA' 'ms-playwright'),
                    (Join-EnvPath 'USERPROFILE' '.cache\ms-playwright'),
                    (Join-EnvPath 'USERPROFILE' '.puppeteer'),
                    (Join-EnvPath 'LOCALAPPDATA' 'puppeteer'),
                    (Join-EnvPath 'LOCALAPPDATA' 'SeleniumHQ'),
                    (Join-EnvPath 'USERPROFILE' '.selenium')
                )) {
                    if ($bac -and (Test-Path -LiteralPath $bac -PathType Container)) {
                        $bytes += Get-DirectorySize $bac
                        $count++
                    }
                }
            }
            'Package Manager Caches' {
                foreach ($pmc in @(
                    (Join-EnvPath 'APPDATA' 'npm-cache'),
                    (Join-EnvPath 'LOCALAPPDATA' 'pip\Cache'),
                    (Join-EnvPath 'USERPROFILE' 'AppData\Local\pip\Cache'),
                    (Join-EnvPath 'USERPROFILE' '.cache\huggingface'),
                    (Join-EnvPath 'LOCALAPPDATA' 'huggingface\cache')
                )) {
                    if ($pmc -and (Test-Path -LiteralPath $pmc -PathType Container)) {
                        $bytes += Get-DirectorySize $pmc
                        $count++
                    }
                }
            }
            'GPU/Shell Caches' {
                foreach ($g in @((Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'DXCache'))) {
                    if ($g -and (Test-Path -LiteralPath $g -PathType Container)) {
                        $bytes += Get-DirectorySize $g
                        $count++
                    }
                }
            }
            'Log Files' {
                $logRoots = @((Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs'))
                foreach ($l in $logRoots) {
                    if ($l -and (Test-Path -LiteralPath $l -PathType Container)) {
                        $bytes += Get-DirectorySize $l
                        $count++
                    }
                }
            }
            'Thumbnail Cache' {
                $thumbDir = (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer')
                if ($thumbDir -and (Test-Path -LiteralPath $thumbDir -PathType Container)) {
                    $bytes += Get-DirectorySize $thumbDir
                    $count++
                }
            }
            'Empty/Stale Folders' {
                # Measure empty directories in approved stale-cleanup roots
                $staleRoots = @(
                    (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
                    (Join-EnvPath 'APPDATA' 'Microsoft' 'Windows' 'Recent')
                )
                foreach ($root in $staleRoots) {
                    if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
                        try {
                            $emptyDirs = @([Bakunawa.Scanner]::Walk($root, [string[]]@(Get-CoreExcludedPaths)) |
                                Where-Object { $_.Kind -eq 'EmptyDirectory' -and $_.Complete })
                            foreach ($dir in $emptyDirs) {
                                $bytes += 0  # Empty dirs are 0 bytes, but count them
                                $count++
                            }
                        } catch {
                            # Silently continue on access errors
                        }
                    }
                }
            }
            'Orphan Scan' {
                # Call Phase 3's rewritten Find-OrphanFolders to get real orphan findings (Tier1+2/3)
                try {
                    $orphanFindings = Find-OrphanFolders
                    if ($orphanFindings) {
                        foreach ($orphan in $orphanFindings) {
                            $bytes += $orphan.Size
                            $count++
                        }
                    }
                } catch {
                    Register-CleanupError -Path 'Orphan Scan' -Category 'Orphan Scan' -Message $_.Exception.Message
                    $bytes = 0
                    $count = 0
                }
            }
            'Cloud Sync' {
                $applist = Get-AllAppDefinitions -Category 'Cloud Sync'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Creative Apps' {
                $applist = Get-AllAppDefinitions -Category 'Creative Apps'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Productivity' {
                $applist = Get-AllAppDefinitions -Category 'Productivity'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'DevOps Tools' {
                $applist = Get-AllAppDefinitions -Category 'DevOps Tools'
                foreach ($app in $applist) {
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                    foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                        if (Test-Path -LiteralPath $resolved -PathType Container) {
                            $bytes += Get-DirectorySize $resolved
                            $count++
                        }
                    }
                }
            }
            'Recycle Bin' {
                $bytes = Get-DirectorySize -Path 'C:\$Recycle.Bin'
            }
        }
        [void]$results.Add([PSCustomObject]@{
            Task = $taskName
            Target = $taskName
            EstimatedBytes = $bytes
            FileCount = $count
            Status = $status
        })
    }
    return @($results | Sort-Object EstimatedBytes -Descending)
}
function Remove-FilesByPattern {
    [CmdletBinding()]
    param([ValidateNotNullOrEmpty()][string]$Directory, [ValidateNotNullOrEmpty()][string[]]$Patterns, [string]$Category = 'General')
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Directory))
    $count = 0
    while ($pending.Count) {
        $current = $pending.Pop()
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-IsExcludedPath $current)) { continue }
            foreach ($child in (Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if ($child.PSIsContainer) { $pending.Push($child.FullName); continue }
                $matches = $false
                foreach ($pattern in $Patterns) { if ($child.Name -like $pattern) { $matches = $true; break } }
                if (-not $matches) { continue }
                try {
                    $size = Remove-ItemSafely -Path $child.FullName -Reason $Category -Preview:$script:IsPreview
                    $script:BytesFreed += $size; $script:TaskBytes += $size; $script:TaskCleared++
                    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                    $script:CategorySizes[$Category] += $size
                    $count++
                } catch { Register-CleanupError -Path $child.FullName -Category $Category -Message $_.Exception.Message }
            }
        } catch { Register-CleanupError -Path $current -Category $Category -Message $_.Exception.Message }
    }
    return $count
}

function Clear-SystemCaches {
    [CmdletBinding()]
    param()
    $cat = 'System Caches'; $n = 0
    # Resolve then dedupe: %TEMP% and %LOCALAPPDATA%\Temp are usually the same directory
    $targets = @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader,
        (Join-Path (Get-EnvPath 'SystemDrive') 'temp'),
        (Join-Path (Get-EnvPath 'SystemDrive') 'tmp')
    ) | Where-Object { $_ } | ForEach-Object { Resolve-FullPath $_ } | Select-Object -Unique
    foreach ($t in $targets) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($script:SysLoc.WindowsRoot)) { return $n }
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

function Clear-ChromiumCaches {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$UserDataRoot, [AllowEmptyString()][string]$Label)
    $cat = 'Browser Caches'; $n = 0

    # If no UserDataRoot provided, scan default Chromium locations
    if ([string]::IsNullOrWhiteSpace($UserDataRoot)) {
        $chromiumPaths = @(
            (Join-EnvPath 'LOCALAPPDATA' 'Google' 'Chrome' 'User Data'),
            (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Edge' 'User Data'),
            (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware' 'Brave-Browser' 'User Data'),
            (Join-EnvPath 'APPDATA' 'Opera Software' 'Opera Stable'),
            (Join-EnvPath 'LOCALAPPDATA' 'Vivaldi' 'User Data')
        )
        foreach ($path in $chromiumPaths) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                $result = Clear-ChromiumCaches -UserDataRoot $path -Label (Split-Path -Leaf $path)
                $n += $result
            }
        }
        return $n
    }

    if (-not [Bakunawa.Scanner]::IsAllowedPath($UserDataRoot) -or -not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) { 'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') } 'Opera' { @('opera') } 'Vivaldi'{ @('vivaldi') } default { @() } }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }

    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache','ShaderCache','GrShaderCache','GraphiteDawnCache','DawnWebGPUCache','Crashpad')

    # Iterate every profile subdirectory (Default, Profile 1, ...) so per-profile
    # caches are actually reached. Fall back to root-level cache dirs only when
    # the root has no profile subdirectories at all (very old profiles).
    $profileDirs = @(Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -like 'Guest Profile' })
    $targets = if ($profileDirs.Count -gt 0) {
        $profileDirs
    } else {
        @([pscustomobject]@{ FullName = $UserDataRoot })
    }

    foreach ($prof in $targets) {
        foreach ($d in $cacheDirs) {
            $p = Join-Path $prof.FullName $d
            if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
        }
    }
    return $n
}

function Clear-FirefoxCaches {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ProfileRoot)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $ProfileRoot -PathType Container)) { return 0 }
    $cacheDirs = @('cache2','thumbnails','startupCache','shader-cache')
    foreach ($d in $cacheDirs) {
        $p = Join-Path $ProfileRoot $d
        if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-AppCaches {
    [CmdletBinding()]
    param()
    $applist = Get-AllAppDefinitions -Category 'App Caches'
    $cat = 'App Caches'; $total = 0

    foreach ($app in $applist) {
        # Skip if any required fields are missing
        if (-not $app.Name) { continue }

        # Expand wildcards in path
        try {
            $expandedPath = $app.Path -replace '\{username\}',$env:USERNAME
            $expandedPath = $expandedPath -replace '\{appdata\}', $env:APPDATA
            $expandedPath = $expandedPath -replace '\{localappdata\}', $env:LOCALAPPDATA
            $expandedPath = $expandedPath -replace '\{programdata\}', $env:PROGRAMDATA
            $expandedPath = $expandedPath -replace '\{commonprogramfiles\}', $env:COMMONPROGRAMFILES
            $expandedPath = $expandedPath -replace '\{systemdrive\}', $env:SYSTEMDRIVE
            $expandedPath = $expandedPath -replace '\{windows\}', $env:WINDIR

            $appsubcat = "$($app.Name) - $($app.Category)"
            foreach ($resolvedPath in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                    if (Measure-AndClear $resolvedPath -Category $appsubcat) { $total++ }
                }
            }
        } catch {
            Register-CleanupError -Path $expandedPath -Category $appsubcat -Message $_.Exception.Message
        }
    }
    return $total
}

function Clear-DevCaches {
    [CmdletBinding()]
    param()
    $devDirs = @(
        (Join-EnvPath 'LOCALAPPDATA' 'npm' '_logs'),
        (Join-EnvPath 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NuGet' 'v3' 'http-cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Yarn' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'dotnet' 'NuGet' 'v2' 'http-cache'),
        (Join-EnvPath 'APPDATA' 'Code' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp' 'npm-*'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp' 'yarn-*'),
        (Join-EnvPath 'USERPROFILE' '.android' 'cache')
    )
    $cat = 'Dev Caches'; $n = 0
    foreach ($d in $devDirs) {
        foreach ($path in @(Expand-WildcardPath -Path $d -DirectoriesOnly)) {
            if (Measure-AndClear $path -Category $cat) { $n++ }
        }
    }

    # Process devtools-extended app definitions for .local, .cache, scoop, cargo, android, go, bun
    $extendedDefs = Get-AppDefinitions -Category 'devtools-extended' | Where-Object { $_.Category -eq 'Dev Caches' }
    foreach ($app in $extendedDefs) {
        if (-not $app.Name) { continue }
        try {
            $expandedPath = $app.Path -replace '{username}',$env:USERNAME
            $expandedPath = $expandedPath -replace '{appdata}',$env:APPDATA
            $expandedPath = $expandedPath -replace '{localappdata}',$env:LOCALAPPDATA
            $expandedPath = $expandedPath -replace '{programdata}',$env:PROGRAMDATA
            $expandedPath = $expandedPath -replace '{commonprogramfiles}',$env:COMMONPROGRAMFILES
            $expandedPath = $expandedPath -replace '{systemdrive}',$env:SYSTEMDRIVE
            $expandedPath = $expandedPath -replace '{windows}',$env:WINDIR

            foreach ($resolvedPath in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                    if (Measure-AndClear $resolvedPath -Category "$cat - $($app.Name)") { $n++ }
                }
            }
        } catch {
            Register-CleanupError -Path $expandedPath -Category $cat -Message $_.Exception.Message
        }
    }
    return $n
}

function Clear-GpuAndShellCaches {
    [CmdletBinding()]
    param()
    $locations = @(
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA' 'DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA' 'GLCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD' 'DxCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD' 'VkCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'D3DSCache')
    )
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($loc in $locations) {
        if ($loc -and (Measure-AndClear $loc -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-RecycleBinSafe {
    [CmdletBinding()]
    param()
    try {
        $recycleBin = 0
        if (-not $script:IsPreview) {
            Clear-RecycleBin -DriveLetter C -Force -ErrorAction Stop
        }
          Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" 'Recycle Bin on C:'
          return $true
      } catch {
          Register-CleanupError -Path 'Recycle Bin' -Category 'Recycle Bin' -Message $_.Exception.Message
          return $false
      }
}

function Clear-SystemLogFiles {
    [CmdletBinding()]
    param()
    $logDirs = @(
        "$env:SystemRoot\Logs",
        "$env:SystemRoot\System32\winevt\Logs",
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'WebCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'IECompatCache')
    )
    $cat = 'Log Files'; $n = 0
    foreach ($logDir in $logDirs) {
        if ($logDir -and (Measure-AndClear $logDir -EnsureDirectory -Category $cat)) { $n++ }
    }
    return $n
}

function Remove-EmptyDirectories {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$RootPath)
    if (-not [Bakunawa.Scanner]::IsAllowedPath($RootPath) -or -not (Test-Path -LiteralPath $RootPath -PathType Container)) { return }
    $resolved = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    foreach ($entry in [Bakunawa.Scanner]::Walk($resolved, [string[]]@(Get-CoreExcludedPaths))) {
        if ($entry.Kind -eq 'Error') { Register-CleanupError -Path $entry.Path -Category 'Empty folders' -Message $entry.Message }
        if ($entry.Kind -ne 'EmptyDirectory' -or $entry.Path -eq $resolved -or -not $entry.Complete) { continue }
        try {
            $null = Remove-ItemSafely -Path $entry.Path -Reason 'Empty temp folder' -Preview:$script:IsPreview
            $script:TaskCleared++
        } catch { Register-CleanupError -Path $entry.Path -Category 'Empty folders' -Message $_.Exception.Message }
    }
}

function Remove-StaleJunkFolders {
    [CmdletBinding()]
    param()
    $staleLocations = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        (Join-EnvPath 'APPDATA' 'Microsoft' 'Windows' 'Recent')
    )
    foreach ($loc in $staleLocations) {
        Remove-EmptyDirectories -RootPath $loc
    }
}

function Find-OrphanFolders {
    [CmdletBinding()]
    param([string[]]$Roots, [ValidateRange(1,3650)][int]$OlderThanDays = 30, [switch]$Refresh)
    Invoke-OrphanDiscovery @PSBoundParameters
}

function Clear-CachedOrphans {
    [CmdletBinding()]
    param([switch]$Preview)
    $isDryRun = $Preview -or $script:IsPreview
    $totalSize = 0L; $count = 0
    foreach ($orphan in @($script:OrphanCache)) {
        if (-not $orphan -or -not $orphan.SafeDelete) { continue }
        try {
            $current = [Bakunawa.Scanner]::Inspect($orphan.Path, [string[]]@(Get-ScanExclusions))
            if ($current.Bytes -ne $orphan.Size -or $current.LatestWriteUtc -ne $orphan.LatestWriteUtc -or $current.Files -ne $orphan.FileCount) {
                throw 'Target changed since scan; rescan required.'
            }
            $totalSize += Remove-ItemSafely -Path $orphan.Path -Reason $orphan.Category -Tier $orphan.Tier -DetectorName 'Find-OrphanFolders' -Preview:$isDryRun
            $count++
        } catch { Register-CleanupError -Path $orphan.Path -Category 'Orphan Scan' -Message $_.Exception.Message }
    }
    $script:BytesFreed += $totalSize; $script:TaskBytes += $totalSize; $script:TaskCleared += $count
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
    $script:CategorySizes['Orphan Files'] = $totalSize
    if (-not $isDryRun) { $script:OrphanCacheTime = $null }
    return $count
}

function Clear-Prefetch {
    [CmdletBinding()]
    param()
    $prefetchDir = "$env:SystemRoot\Prefetch"
    $cat = 'Prefetch'; $n = 0
    if ($prefetchDir -and (Measure-AndClear $prefetchDir -Category $cat)) { $n++ }
    return $n
}

function Clear-EventLogs {
    [CmdletBinding()]
    param()
    # Event log storage can be redirected. Preserve diagnostics rather than clear another drive.
    Register-SkippedItem -Reason 'Event logs are retained; storage may be redirected outside C:' -Target 'Event Logs'
    return $false
}

function Clear-FontCache {
    [CmdletBinding()]
    param()
    $fontCache = Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'FontCache'
    $cat = 'Font Cache'
    return (Measure-AndClear $fontCache -Category $cat)
}

function Clear-ThumbnailCache {
    [CmdletBinding()]
    param()
    $thumbDir = (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer')
    $cat = 'Thumbnail Cache'; $n = 0
    if (-not [Bakunawa.Scanner]::IsAllowedPath($thumbDir) -or -not (Test-Path -LiteralPath $thumbDir -PathType Container)) { return 0 }
    # Only target the thumbnail DB files; leave other Explorer state (IconCache.db is also here)
    $files = Get-ChildItem -LiteralPath $thumbDir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -ieq 'IconCache.db' }

    # Thumbnail cache files (thumbcache_*.db, IconCache.db) are small, safe, and isolated.
    # Route through quarantine for safety; per-file quarantine adds negligible overhead.
    foreach ($f in $files) {
        if (Test-IsExcludedPath $f.FullName) { continue }
        $sz = $f.Length
        try {
        Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" "$($f.FullName) ($([math]::Round($sz/1MB,2)) MB)"
        $deletedSize = Remove-ItemSafely -Path $f.FullName -Reason $cat -Tier 'Tier1' `
            -DetectorName 'Clear-ThumbnailCache' -Preview:$script:IsPreview
        $script:BytesFreed += [long]$deletedSize
        if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
        if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
        $script:CategorySizes[$cat] += [long]$deletedSize
        $script:TaskCleared++; $script:TaskBytes += [long]$deletedSize
        $n++
        } catch { Register-CleanupError -Path $f.FullName -Category $cat -Message $_.Exception.Message }
    }
    return $n
}

function Invoke-CleanupRun {
    [CmdletBinding()]
    param(
        [ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard',
        [switch]$WhatIf,
        [AllowNull()][hashtable]$Config
    )
    
    $script:BytesFreed = 0L
    $script:QuarantinedBytes = 0L
    $script:CategorySizes = @{}
    $script:Errors = @()
    $script:SkippedItems = @()
    $script:IsPreview = ($WhatIf.IsPresent -or ($Mode -eq 'Preview'))
    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    
    # Load config if not provided
    if (-not $Config) {
        try {
            if (Get-Command Get-UserConfig -ErrorAction SilentlyContinue) {
                $Config = Get-UserConfig -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Debug "Failed to load user config, using defaults: $($_.Exception.Message)"
        }
    }

    Initialize-CleanupState -Config $Config
    $Config = $script:CleanupConfig
    $script:IsPreview = ($script:IsPreview -or [bool]$Config.cleanupMode.dryRun)
    
    # Get tasks based on mode
    $tasks = Get-CleanupTasks -Mode $effectiveMode
    
    # Filter tasks based on config if available
    if ($Config -and $Config.taskCategories) {
        $tasks = @($tasks | Where-Object { 
            $task = $_
            $enabled = $Config.taskCategories[$task.Name].enabled
            if ($null -eq $enabled) { $true } else { $enabled }
        })
    }
    
    $script:TotalSteps = $tasks.Count
    $script:StepIndex = 0
    Reset-CleanupProgress

    $modeNote = if ($script:IsPreview) { 'nothing will be deleted' } else { switch ($Mode) {
        'Preview'    { 'nothing will be deleted' }
        'Aggressive' { 'deep clean - files will be deleted' }
        default      { 'files will be deleted' }
    } }
    Write-Host ''
    Write-ReviewLine ("Bakunawa - {0}: {1} tasks - {2}" -f $Mode, $tasks.Count, $modeNote)

    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:RunCleared = 0

    # Process tasks
    foreach ($task in $tasks) {
        $taskName = $task.Name
        $isParallel = $task.Parallel

        Start-Step -Name $taskName -Total $tasks.Count

        # Per-task statistics (rendered by Finish-Step below)
        $script:TaskCleared = 0
        $script:TaskSkipped = 0
        $script:TaskBytes   = [long]0
        
        $errorsBefore = @($script:Errors).Count
        try {
        switch ($taskName) {
            'System Caches' { $null = Clear-SystemCaches }
            'Browser Caches' {
                # Definitions already point to exact cache directories, including profile tokens.
                foreach ($app in (Get-AllAppDefinitions -Category 'Browser Caches')) {
                    if (-not $app.Path) { continue }
                    if (Test-AnyProcessRunning -RunningProcesses $script:RunningProcesses -Names @($app.Process)) {
                        Register-SkippedItem -Reason 'Close the browser to clean its cache' -Target $app.Name
                        continue
                    }
                    foreach ($path in @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly)) {
                        $null = Measure-AndClear -Path $path -Category 'Browser Caches'
                    }
                }
            }
             'App Caches' { $null = Clear-AppCaches }
             'Dev Caches' { $null = Clear-DevCaches }
             'Game Caches' { $null = Clear-GameCaches }
             'Browser Automation Caches' { $null = Clear-BrowserAutomationCaches }
             'Package Manager Caches' { $null = Clear-PackageManagerCaches }
             'GPU/Shell Caches' { $null = Clear-GpuAndShellCaches }
            'Recycle Bin' { $null = Clear-RecycleBinSafe }
            'Thumbnail Cache' { $null = Clear-ThumbnailCache }
            'Log Files' { $null = Clear-SystemLogFiles }
            'Empty/Stale Folders' { 
                $tempDirs = @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)
                foreach ($tempDir in $tempDirs) {
                    $null = Remove-EmptyDirectories -RootPath $tempDir
                }
                $null = Remove-StaleJunkFolders
            }
            'Orphan Scan' { 
                $null = Find-OrphanFolders  # Scans and caches orphans
                $null = Clear-CachedOrphans # Deletes cached orphans (respects preview mode)
            }
            'Prefetch' { $null = Clear-Prefetch }
            'DISM' { 
                if (-not [Bakunawa.Scanner]::IsAllowedPath((Get-EnvPath 'SystemRoot'))) {
                    Register-SkippedItem -Reason 'Windows servicing is restricted to C:' -Target 'DISM'
                    break
                }
                if ($script:IsPreview) {
                    Write-CommandLog 'PREVIEW' 'DISM /Online /Cleanup-Image /StartComponentCleanup'
                } else {
                    $dism = Join-Path (Get-EnvPath 'SystemRoot') 'System32\dism.exe'
                    try {
                        & $dism /Online /Cleanup-Image /StartComponentCleanup | ForEach-Object { Write-CommandLog 'DISM' $_ }
                        if ($LASTEXITCODE -notin @(0,3010)) { throw "DISM exited with code $LASTEXITCODE" }
                        if ($LASTEXITCODE -eq 3010) { Write-CommandLog 'INFO' 'Restart Windows to finish component cleanup.' }
                    } catch { Register-CleanupError -Path $dism -Category 'DISM' -Message $_.Exception.Message }
                }
            }
             'Event Logs + Font Cache' { 
                 $null = Clear-EventLogs
                 $null = Clear-FontCache
             }
             'Cloud Sync' {
                 # OneDrive, Google Drive, Dropbox temp files
                 $applist = Get-AllAppDefinitions -Category 'Cloud Sync'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if (Test-Path -LiteralPath $resolved -PathType Container) {
                                 Measure-AndClear $resolved -Category 'Cloud Sync' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Creative Apps' {
                 # Adobe, Affinity, Blender, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'Creative Apps'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if (Test-Path -LiteralPath $resolved -PathType Container) {
                                 Measure-AndClear $resolved -Category 'Creative Apps' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Productivity' {
                 # Office, Slack, Teams, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'Productivity'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if (Test-Path -LiteralPath $resolved -PathType Container) {
                                 Measure-AndClear $resolved -Category 'Productivity' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'DevOps Tools' {
                 # Docker, Kubernetes, Terraform, etc. caches
                 $applist = Get-AllAppDefinitions -Category 'DevOps Tools'
                 foreach ($app in $applist) {
                     if ($app.Path) {
                         $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                         foreach ($resolved in @(Expand-WildcardPath -Path $expandedPath -DirectoriesOnly)) {
                             if (Test-Path -LiteralPath $resolved -PathType Container) {
                                 Measure-AndClear $resolved -Category 'DevOps Tools' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'User Hidden Folders' {
                 # Hidden system files and caches
                 $hiddenFolders = @(
                     (Join-EnvPath 'USERPROFILE' '.cache'),
                     (Join-EnvPath 'USERPROFILE' '.config\cache'),
                     (Join-EnvPath 'LOCALAPPDATA' 'VirtualStore')
                 )
                 foreach ($hf in $hiddenFolders) {
                     if ($hf -and (Test-Path -LiteralPath $hf -PathType Container)) {
                         Measure-AndClear $hf -Category 'User Hidden' -EA SilentlyContinue | Out-Null
                     }
                 }
             }
             'Scoop Cache' {
                 $scoopCache = Join-EnvPath 'USERPROFILE' 'scoop\cache'
                 if ($scoopCache -and (Test-Path -LiteralPath $scoopCache -PathType Container)) {
                     Measure-AndClear $scoopCache -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Rust Cargo Cache' {
                 $cargoTarget = Join-EnvPath 'USERPROFILE' '.cargo\registry\cache'
                 if ($cargoTarget -and (Test-Path -LiteralPath $cargoTarget -PathType Container)) {
                     Measure-AndClear $cargoTarget -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Go Module Cache' {
                 $goModCache = Join-EnvPath 'USERPROFILE' 'go\pkg\mod\cache'
                 if ($goModCache -and (Test-Path -LiteralPath $goModCache -PathType Container)) {
                     Measure-AndClear $goModCache -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                 }
             }
             'Bun Cache' {
                 $bunCache = @(
                     (Join-EnvPath 'USERPROFILE' '.bun\install\cache'),
                     (Join-EnvPath 'LOCALAPPDATA' 'bun\install\cache')
                 )
                 foreach ($bc in $bunCache) {
                     if ($bc -and (Test-Path -LiteralPath $bc -PathType Container)) {
                         Measure-AndClear $bc -Category 'Package Managers' -EA SilentlyContinue | Out-Null
                     }
                 }
             }
        }

        } catch {
            Register-CleanupError -Path $taskName -Category $taskName -Message $_.Exception.Message
        }

        # Compose informative per-task summary
        $script:RunCleared += $script:TaskCleared
        $parts = @()
        $taskErrors = @($script:Errors).Count - $errorsBefore
        if ($taskErrors -gt 0) { $parts += ("$taskErrors error(s)") }
        if ($script:TaskCleared -gt 0) { $parts += ('{0} path{1}' -f $script:TaskCleared, $(if ($script:TaskCleared -eq 1) { '' } else { 's' })) }
        if ($script:TaskBytes -gt 0)   { $parts += (Format-FileSize $script:TaskBytes) }
        if ($script:TaskSkipped -gt 0) { $parts += ('{0} skipped' -f $script:TaskSkipped) }
        $summary = if ($parts.Count -gt 0) { $parts -join '  |  ' } else { 'nothing found' }
        Finish-Step -Summary $summary
    }

    $runStopwatch.Stop()

    # Return results
    return [PSCustomObject]@{
        Mode = $Mode
        BytesFreed = $(if ($script:IsPreview) { [long]$script:BytesFreed } else { [long][math]::Max(0, $script:BytesFreed - $script:QuarantinedBytes) })
        QuarantinedBytes = [long]$script:QuarantinedBytes
        IsPreview = [bool]$script:IsPreview
        PathsCleared = [int]$script:RunCleared
        CategorySizes = $script:CategorySizes
        Errors = $script:Errors
        SkippedItems = @(Get-CoreSkippedItems)
        OrphanFounds = @($script:OrphanCache | Where-Object { $_ }).Count
        ScanReport = $script:LastScanReport
        DurationSec = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 1)
    }
}

function Clear-GameCaches {
    [CmdletBinding()]
    param()
    Write-CommandLog 'SCAN' 'Game Platform Caches'
    $cat = 'Game Caches'; $n = 0
    
    # Version directories contain installed executables; only their client cache is disposable.
    foreach ($cache in @(Expand-WildcardPath -Path (Join-EnvPath 'LOCALAPPDATA' 'Roblox/Versions/*/ClientCache') -DirectoriesOnly)) {
        if (Measure-AndClear $cache -Category $cat) { $n++ }
    }
    
    # Steam shader cache (structure: steamapps\shadercache\)
    $steamRoot = Join-EnvPath 'PROGRAMFILES' 'Steam'
    if ($steamRoot -and (Test-Path -LiteralPath $steamRoot -PathType Container)) {
        $shaderCache = Join-Path $steamRoot 'steamapps\shadercache'
        if (Test-Path -LiteralPath $shaderCache -PathType Container) {
            if (Measure-AndClear $shaderCache -Category $cat) { $n++ }
        }
    }
    
    # Epic Games Launcher cache
    $epicCache = Join-EnvPath 'PROGRAMDATA' 'Epic\UnrealEngineLauncher\Saved\Cache'
    if ($epicCache -and (Test-Path -LiteralPath $epicCache -PathType Container)) {
        if (Measure-AndClear $epicCache -Category $cat) { $n++ }
    }
    
    # Battle.net cache
    $battleNetCache = Join-EnvPath 'PROGRAMDATA' 'Battle.net\Cache'
    if ($battleNetCache -and (Test-Path -LiteralPath $battleNetCache -PathType Container)) {
        if (Measure-AndClear $battleNetCache -Category $cat) { $n++ }
    }
    
    # Roblox Player cache (user-level)
    $robloxPlayer = Join-EnvPath 'LOCALAPPDATA' 'Roblox\cache'
    if ($robloxPlayer -and (Test-Path -LiteralPath $robloxPlayer -PathType Container)) {
        if (Measure-AndClear $robloxPlayer -Category $cat) { $n++ }
    }
    
    return $n
}

function Clear-BrowserAutomationCaches {
    [CmdletBinding()]
    param()
    Write-CommandLog 'SCAN' 'Browser Automation Tool Caches'
    $cat = 'Dev Tools'; $n = 0
    
    # Playwright cache (downloads browsers & dependencies)
    $playwrightCache = @(
        (Join-EnvPath 'LOCALAPPDATA' 'ms-playwright'),
        (Join-EnvPath 'USERPROFILE' '.cache\ms-playwright')
    )
    foreach ($pc in $playwrightCache) {
        if ($pc -and (Test-Path -LiteralPath $pc -PathType Container)) {
            if (Measure-AndClear $pc -Category $cat) { $n++ }
        }
    }
    
    # Puppeteer cache (downloads Chromium)
    $puppeteerCache = @(
        (Join-EnvPath 'USERPROFILE' '.puppeteer'),
        (Join-EnvPath 'LOCALAPPDATA' 'puppeteer')
    )
    foreach ($pc in $puppeteerCache) {
        if ($pc -and (Test-Path -LiteralPath $pc -PathType Container)) {
            if (Measure-AndClear $pc -Category $cat) { $n++ }
        }
    }
    
    # Selenium cache
    $seleniumCache = @(
        (Join-EnvPath 'LOCALAPPDATA' 'SeleniumHQ'),
        (Join-EnvPath 'USERPROFILE' '.selenium')
    )
    foreach ($sc in $seleniumCache) {
        if ($sc -and (Test-Path -LiteralPath $sc -PathType Container)) {
            if (Measure-AndClear $sc -Category $cat) { $n++ }
        }
    }
    
    return $n
}

function Clear-PackageManagerCaches {
    [CmdletBinding()]
    param()
    Write-CommandLog 'SCAN' 'Package Manager Caches'
    $cat = 'Dev Caches'; $n = 0
    
    # npm cache
    $npmCache = Join-EnvPath 'APPDATA' 'npm-cache'
    if ($npmCache -and (Test-Path -LiteralPath $npmCache -PathType Container)) {
        if (Measure-AndClear $npmCache -Category $cat) { $n++ }
    }
    
    # pip cache (Python)
    $pipCache = @(
        (Join-EnvPath 'LOCALAPPDATA' 'pip\Cache'),
        (Join-EnvPath 'USERPROFILE' 'AppData\Local\pip\Cache')
    )
    foreach ($pc in $pipCache) {
        if ($pc -and (Test-Path -LiteralPath $pc -PathType Container)) {
            if (Measure-AndClear $pc -Category $cat) { $n++ }
        }
    }
    
    # Hugging Face cache (ML models)
    $hfCache = @(
        (Join-EnvPath 'USERPROFILE' '.cache\huggingface'),
        (Join-EnvPath 'LOCALAPPDATA' 'huggingface\cache')
    )
    foreach ($hc in $hfCache) {
        if ($hc -and (Test-Path -LiteralPath $hc -PathType Container)) {
            if (Measure-AndClear $hc -Category $cat) { $n++ }
        }
    }
    
    return $n
}

Export-ModuleMember -Function @(
    'Measure-AndClear',
    'Get-CleanupTasks',
    'Get-CleanupPotential',
    'Remove-FilesByPattern',
    'Expand-WildcardPath',
    'Clear-SystemCaches',
    'Clear-ChromiumCaches',
    'Clear-FirefoxCaches',
    'Clear-AppCaches',
    'Clear-DevCaches',
    'Clear-GpuAndShellCaches',
    'Clear-GameCaches',
    'Clear-BrowserAutomationCaches',
    'Clear-PackageManagerCaches',
    'Clear-RecycleBinSafe',
    'Clear-SystemLogFiles',
    'Remove-EmptyDirectories',
    'Remove-StaleJunkFolders',
    'Find-OrphanFolders',
    'Get-ScanDriveRoots',
    'Get-OrphanScanReport',
    'Clear-ReviewedOrphans',
    'Initialize-CleanupState',
    'Clear-CachedOrphans',
    'Clear-Prefetch',
    'Clear-EventLogs',
    'Clear-FontCache',
    'Get-CleanupErrorLog',
    'Invoke-CleanupRun'
)
