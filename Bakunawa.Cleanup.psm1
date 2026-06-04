# Bakunawa.Cleanup.psm1 — Cleanup task execution

function Write-CommandLog {
    param([string]$Verb,[string]$Target)
    $ts = Get-Date -Format 'HH:mm:ss'
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Host "[$ts] [CMD] $Verb" -ForegroundColor DarkGray; return }
    Write-Host "[$ts] [CMD] $Verb $Target" -ForegroundColor DarkGray
}

function Get-CleanupTasks {
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $tasks = [System.Collections.Generic.List[System.Object]]::new()
    $null = $tasks.Add([PSCustomObject]@{ Name = 'System Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Browser Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'App Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Dev Caches'; Parallel = $true })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'GPU/Shell Caches'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Recycle Bin'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Log Files'; Parallel = $false })
    $null = $tasks.Add([PSCustomObject]@{ Name = 'Empty/Stale Folders'; Parallel = $false })
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
    if (-not $resolved -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-SafeCleanupTarget -Path $resolved)) { return $false }
    $sizeBefore = Get-DirectorySize $resolved
    $verb = if($script:IsPreview){'PREVIEW'}else{'CLEAR'}
    Write-CommandLog $verb $resolved
    if (-not $script:IsPreview) {
        try {
            Get-ChildItem -LiteralPath $resolved -Force -EA SilentlyContinue | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue -ErrorVariable rmErr
                if ($rmErr) { $script:Errors += [PSCustomObject]@{ Path = $_.FullName; Exception = $rmErr[0].Exception.Message; Category = 'Remove-Item'; Timestamp = Get-Date } }
            }
        } catch {
            $script:Errors += [PSCustomObject]@{ Path = $resolved; Exception = $_.Exception.Message; Category = 'Measure-AndClear'; Timestamp = Get-Date }
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

function Clear-SystemCaches {
    $cat = 'System Caches'; $n = 0
    foreach ($t in @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader
    )) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
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
    param([string]$UserDataRoot, [string]$Label)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) { 'Chrome' { @('chrome') } 'Edge' { @('msedge') } 'Brave' { @('brave') } 'Opera' { @('opera') } 'Vivaldi'{ @('vivaldi') } default { @() } }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }
    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache','ShaderCache','GrShaderCache')
    foreach ($d in $cacheDirs) {
        $p = Join-Path $UserDataRoot $d
        if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-FirefoxCaches {
    param([string]$ProfileRoot)
    $cat = 'Browser Caches'; $n = 0
    if (-not (Test-Path -LiteralPath $ProfileRoot -PathType Container)) { return 0 }
    $cacheDirs = @('cache2','storage','thumbnails','startupCache','webapps','webextensions','loop')
    foreach ($d in $cacheDirs) {
        $p = Join-Path $ProfileRoot $d
        if ($p -and (Measure-AndClear $p -EnsureDirectory -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-AppCaches {
    $applist = Get-AllAppDefinitions
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
            
            # Handle Firefox profiles which have random profile names
            if ($expandedPath -like '*\{\*\}') {
                $patternPath = $expandedPath -replace '\{[^}]+\}','*'
                $matches = Get-ChildItem -Path (Split-Path $patternPath) -Filter (Split-Path -Leaf $patternPath) -Directory -ErrorAction SilentlyContinue
                foreach ($match in $matches) {
                    $resolvedPath = Join-Path $match.FullName (Split-Path -Leaf $expandedPath)
                    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                        $appsubcat = "$($app.Name) - $($app.Category)"
                        if (Measure-AndClear $resolvedPath -Category $appsubcat) { $total++ }
                    }
                }
            } else {
                if (Test-Path -LiteralPath $expandedPath -PathType Container) {
                    $appsubcat = "$($app.Name) - $($app.Category)"
                    if (Measure-AndClear $expandedPath -Category $appsubcat) { $total++ }
                }
            }
        } catch {
            # Silently continue on path expansion errors
        }
    }
    return $total
}

function Clear-DevCaches {
    $devDirs = @(
        (Join-EnvPath 'LOCALAPPDATA' 'npm' '_logs'),
        (Join-EnvPath 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'dotnet' 'Sdk'),
        (Join-EnvPath 'LOCALAPPDATA' 'NuGet' 'v3' 'http-cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Yarn' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'LOCALAPPDATA' 'pip' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'dotnet' 'NuGet' 'v2' 'http-cache'),
        (Join-EnvPath 'APPDATA' 'Code' 'Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp' 'npm-*'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp' 'yarn-*'),
        (Join-EnvPath 'LOCALAPPDATA' 'Android' 'Sdk')
    )
    $cat = 'Dev Caches'; $n = 0
    foreach ($d in $devDirs) { 
        if ($d -and (Measure-AndClear $d -Category $cat)) { $n++ } 
    }
    return $n
}

function Clear-GpuAndShellCaches {
    $gpuShell = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'GitHub' 'Desktop'),
        (Join-EnvPath 'LOCALAPPDATA' 'IconCache.db'),
        (Join-EnvPath 'LOCALAPPDATA' 'IconCacheToDelete.db'),
        (Join-EnvPath 'LOCALAPPDATA' 'IconCacheToDelete.db-*'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'Recent' 'AutomaticDestinations'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'Recent' 'CustomDestinations')
    )
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($g in $gpuShell) {
        if ($g -and (Measure-AndClear $g -Category $cat)) { $n++ }
    }
    return $n
}

function Clear-RecycleBinSafe {
    if (-not $script:SysLoc.RecycleBin) { return 0 }
    $cat = 'Recycle Bin'
    if (Measure-AndClear $script:SysLoc.RecycleBin -Category $cat) { return 1 } else { return 0 }
}

function Clear-SystemLogFiles {
    $logs = @(
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs' '*.evtx'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs' '*Archive*'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs' '*Debug*'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'winevt' 'Logs' '*Operational*'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'LogFiles' 'W3SVC1'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'LogFiles' 'FTPSVC1'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'LogFiles' 'SMTPSVC1'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'LogFiles' 'NNTPSVC1'),
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'LogFiles' 'IISLOG' '*'),
        (Join-EnvPath 'SYSTEMROOT' 'Temp' '*.log'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp' '*.log')
    )
    $cat = 'Log Files'; $n = 0
    foreach ($l in $logs) {
        if (Test-Path -LiteralPath $l -PathType Leaf) {
            $size = (Get-Item -LiteralPath $l -EA SilentlyContinue).Length
            if ($size -gt 0) {
                Write-CommandLog $(if($script:IsPreview){'PREVIEW del'}else{'DEL'}) $l
                if (-not $script:IsPreview) {
                    Clear-Content -Path $l -Force -EA SilentlyContinue
                    if ((Get-Item -LiteralPath $l -EA SilentlyContinue).Length -eq 0) {
                        $script:BytesFreed += $size
                        if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
                        $script:CategorySizes[$cat] += $size
                    }
                } else {
                    $script:BytesFreed += $size
                    if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
                    $script:CategorySizes[$cat] += $size
                }
                $n++
            }
        } elseif (Test-Path -LiteralPath $l -PathType Container) {
            if (Measure-AndClear $l -Category $cat) { $n++ }
        }
    }
    return $n
}

function Remove-EmptyDirectories {
    param([string]$RootPath)
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return 0 }
    $removed = 0
    try {
        # Get all directories, sort by depth (deepest first)
        $dirs = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object -Property @{Expression = {($_.FullName -split '[\\/]').Count}; Descending = $true}
        
        foreach ($dir in $dirs) {
            $fullPath = $dir.FullName
            if (Test-IsExcludedPath $fullPath) { continue }
            
            # Check if directory is empty (no files or subdirs)
            $childItems = Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction SilentlyContinue
            if (-not $childItems) {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW rmdir'}else{'RMDIR'})) $fullPath
                if (-not $script:IsPreview) {
                    try {
                        Remove-Item -LiteralPath $fullPath -Force -EA SilentlyContinue
                        if (-not (Test-Path -LiteralPath $fullPath)) { $removed++ }
                    } catch {
                        # Directory not empty or access denied - skip
                    }
                } else {
                    $removed++
                }
            }
        }
    } catch {
        # Ignore errors in directory enumeration
    }
    return $removed
}

function Remove-StaleJunkFolders {
    $stalePatterns = @(
        '*_tmp*',
        '*_temp*',
        '*.tmp',
        '*.temp',
        '~$*',
        '*.~*',
        '*~',
        '*.old',
        '*.bak',
        '*_backup*',
        '*_old*'
    )
    $tempDirs = @(
        (Get-EnvPath 'TEMP'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp
    )
    $cat = 'Temp Files'; $removed = 0
    
    foreach ($tempDir in $tempDirs) {
        if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) { continue }
        
        foreach ($pattern in $stalePatterns) {
            try {
                $items = Get-ChildItem -LiteralPath $tempDir -Filter $pattern -File -Force -ErrorAction SilentlyContinue
                foreach ($item in $items) {
                    $fullPath = $item.FullName
                    if (Test-IsExcludedPath $fullPath) { continue }
                    
                    Write-CommandLog ($(if($script:IsPreview){'PREVIEW del'}else{'DEL'})) $fullPath
                    if (-not $script:IsPreview) {
                        Remove-Item -LiteralPath $fullPath -Force -EA SilentlyContinue
                        if (-not (Test-Path -LiteralPath $fullPath)) {
                            $size = $item.Length
                            $script:BytesFreed += $size
                            if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                            $script:CategorySizes[$cat] += $size
                        }
                    } else {
                        $size = $item.Length
                        $script:BytesFreed += $size
                        if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                        $script:CategorySizes[$cat] += $size
                    }
                    $removed++
                }
            } catch {
                # Continue on errors
            }
        }
    }
    return $removed
}

function Find-OrphanFolders {
    $userRoots = @(
        (Join-EnvPath 'USERPROFILE' 'Documents'),
        (Join-EnvPath 'USERPROFILE' 'Downloads'),
        (Join-EnvPath 'USERPROFILE' 'Desktop'),
        (Join-EnvPath 'USERPROFILE' 'Pictures'),
        (Join-EnvPath 'USERPROFILE' 'Videos'),
        (Join-EnvPath 'USERPROFILE' 'Music'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        (Get-EnvPath 'TEMP')
    )
    
    $knownGoodApps = @()
    $applist = Get-AllAppDefinitions
    foreach ($app in $applist) {
        if ($app.Path) {
            $expanded = $app.Path -replace '\{username\}',$env:USERNAME
            $expanded = $expanded -replace '\{appdata\}', $env:APPDATA
            $expanded = $expanded -replace '\{localappdata\}', $env:LOCALAPPDATA
            $expanded = $expanded -replace '\{programdata\}', $env:PROGRAMDATA
            $expanded = $expanded -replace '\{commonprogramfiles\}', $env:COMMONPROGRAMFILES
            $expanded = $expanded -replace '\{systemdrive\}', $env:SYSTEMDRIVE
            $expanded = $expanded -replace '\{windows\}', $env:WINDIR
            
            if (-not $expanded -like '*\{\*\}') {
                if (Test-Path -LiteralPath $expanded -PathType Container) {
                    $knownGoodApps += $expanded.ToLower()
                }
            }
        }
    }
    
    $knownGoodApps += @(
        $env:USERPROFILE.ToLower(),
        $env:APPDATA.ToLower(),
        $env:LOCALAPPDATA.ToLower(),
        (Get-EnvPath 'TEMP').ToLower(),
        $env:PROGRAMDATA.ToLower(),
        $env:ProgramFiles.ToLower(),
        $env:ProgramFiles.Replace('ProgramFiles','ProgramFiles(x86)').ToLower(),
        $env:WINDIR.ToLower()
    )
    
    $orphans = @()
    foreach ($root in $userRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        
        try {
            $dirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
            foreach ($dir in $dirs) {
                $fullPath = $dir.FullName.ToLower()
                
                # Skip if in excluded paths
                if (Test-IsExcludedPath $dir.FullName) { continue }
                
                # Skip if it's a known good path
                $isKnownGood = $false
                foreach ($known in $knownGoodApps) {
                    if ($fullPath.StartsWith($known)) {
                        $isKnownGood = $true
                        break
                    }
                }
                if ($isKnownGood) { continue }
                
                # Check if directory is old enough to be considered orphan
                try {
                    $creationTime = $dir.CreationTime
                    $ageDays = (Get-Date) - $creationTime
                    if ($ageDays.Days -gt 30) {  # Older than 30 days
                        # Calculate size
                        $size = 0
                        try {
                            $files = Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -Force -ErrorAction SilentlyContinue
                            foreach ($file in $files) {
                                $size += $file.Length
                            }
                        } catch {
                            # Continue with size 0 on error
                        }
                        
                        if ($size -gt 1MB) {  # Only consider if > 1MB
                            $orphanScore = [Math]::Min(100, ($ageDays.Days / 365 * 50) + ($size / 1GB * 30))
                            $orphans += [PSCustomObject]@{
                                Path = $dir.FullName
                                Size = $size
                                AgeDays = $ageDays.Days
                                Score = [int]$orphanScore
                            }
                        }
                    }
                } catch {
                    # Continue on errors
                }
            }
        } catch {
            # Continue on errors
        }
    }
    
    # Sort by score descending
    $orphans = $orphans | Sort-Object -Property Score -Descending
    
    # Store in script scope for reporting
    if (-not $script:OrphanFolders) { $script:OrphanFolders = @() }
    $script:OrphanFolders = $orphans
    
    return $orphans.Count
}

function Clear-Prefetch {
    if (-not $script:SysLoc.Prefetch) { return 0 }
    $cat = 'Prefetch'; $n = 0
    if (Measure-AndClear $script:SysLoc.Prefetch -Category $cat) { $n++ }
    return $n
}

function Clear-EventLogs {
    $cat = 'Event Logs'; $n = 0
    try {
        $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.IsEnabled -eq $true }
        foreach ($log in $logs) {
            if ($log.LogName -notin @('System','Application','Security')) {  # Skip critical logs
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW clear'}else{'CLEAR'})) $log.LogName
                if (-not $script:IsPreview) {
                    try {
                        wevtutil cl $log.LogName
                        $n++
                    } catch {
                        # Continue on error
                    }
                } else {
                    $n++
                }
            }
        }
    } catch {
        # Continue on error
    }
    return $n
}

function Invoke-ComponentCleanup {
    $cat = 'Component Store'; $n = 0
    $compPath = (Join-EnvPath 'SYSTEMROOT' 'System32' 'DriverStore' 'FileRepository')
    if (Test-Path -LiteralPath $compPath -PathType Container) {
        if (Measure-AndClear $compPath -Category $cat) { $n++ }
    }
    return $n
}

function Clear-FontCache {
    $fontPaths = @(
        (Join-EnvPath 'SYSTEMROOT' 'System32' 'FNTCACHE.DAT'),
        (Join-EnvPath 'LOCALAPPDATA' 'FontCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'FontCache-DWrite'),
        (Join-EnvPath 'LOCALAPPDATA' 'FontCache-DWrite-*') 
    )
    $cat = 'Font Cache'; $n = 0
    foreach ($f in $fontPaths) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $size = (Get-Item -LiteralPath $f -EA SilentlyContinue).Length
            if ($size -gt 0) {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW del'}else{'DEL'})) $f
                if (-not $script:IsPreview) {
                    Clear-Content -Path $f -Force -EA SilentlyContinue
                    if ((Get-Item -LiteralPath $f -EA SilentlyContinue).Length -eq 0) {
                        $script:BytesFreed += $size
                        if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                        $script:CategorySizes[$cat] += $size
                    }
                } else {
                    $script:BytesFreed += $size
                    if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                    $script:CategorySizes[$cat] += $size
                }
                $n++
            }
        } elseif (Test-Path -LiteralPath $f -PathType Container) {
            if (Measure-AndClear $f -Category $cat) { $n++ }
        }
    }
    return $n
}

function Invoke-CleanupRun {
    param(
        [ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard',
        [switch]$WhatIf
    )
    
    # Reset script tracking variables if not already set
    if (-not $script:BytesFreed) { $script:BytesFreed = 0 }
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
    if (-not $script:Errors) { $script:Errors = @() }
    if (-not $script:SkippedItems) { $script:SkippedItems = @() }
    if (-not $script:IsPreview) { $script:IsPreview = $WhatIf.IsPresent }
    
    # Get tasks based on mode
    $tasks = Get-CleanupTasks -Mode $Mode
    
    Write-Host "Starting cleanup in $Mode mode..."
    
    # Process tasks
    foreach ($task in $tasks) {
        $taskName = $task.Name
        $isParallel = $task.Parallel
        
        Write-Host "Processing: $taskName"
        
        switch ($taskName) {
            'System Caches' { Clear-SystemCaches }
            'Browser Caches' { 
                # Get browser paths from config (would normally come from app definitions)
                $browserPaths = @()
                $applist = Get-AllAppDefinitions
                foreach ($app in $applist) {
                    if ($app.Category -like '*Browser*') {
                        $browserPaths += @{ UserDataRoot = $app.Path; Label = $app.Name }
                    }
                }
                
                if ($browserPaths.Count -eq 0) {
                    # Fallback defaults
                    $browserPaths = @(
                        @{ UserDataRoot = (Join-EnvPath 'LOCALAPPDATA' 'Google' 'Chrome' 'User Data'); Label = 'Chrome' },
                        @{ UserDataRoot = (Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Edge' 'User Data'); Label = 'Edge' },
                        @{ UserDataRoot = (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware' 'Brave-Browser' 'User Data'); Label = 'Brave' },
                        @{ UserDataRoot = (Join-EnvPath 'APPDATA' 'Opera Software' 'Opera Stable'); Label = 'Opera' },
                        @{ UserDataRoot = (Join-EnvPath 'LOCALAPPDATA' 'Vivaldi' 'User Data'); Label = 'Vivaldi' }
                    )
                }
                
                if ($isParallel) {
                    # Parallel execution would use background jobs or runspaces
                    # For simplicity, we'll run sequentially but note parallel capability
                    foreach ($browser in $browserPaths) {
                        Clear-ChromiumCaches -UserDataRoot $browser.UserDataRoot -Label $browser.Label
                    }
                } else {
                    foreach ($browser in $browserPaths) {
                        Clear-ChromiumCaches -UserDataRoot $browser.UserDataRoot -Label $browser.Label
                    }
                }
                
                # Firefox
                $ffProfile = (Join-EnvPath 'APPDATA' 'Mozilla' 'Firefox' 'Profiles')
                if (Test-Path -LiteralPath $ffProfile -PathType Container) {
                    $profiles = Get-ChildItem -LiteralPath $ffProfile -Directory -Filter '*.default*' -ErrorAction SilentlyContinue
                    foreach ($profile in $profiles) {
                        Clear-FirefoxCaches -ProfileRoot $profile.FullName
                    }
                }
            }
            'App Caches' { Clear-AppCaches }
            'Dev Caches' { Clear-DevCaches }
            'GPU/Shell Caches' { Clear-GpuAndShellCaches }
            'Recycle Bin' { Clear-RecycleBinSafe }
            'Log Files' { Clear-SystemLogFiles }
            'Empty/Stale Folders' { 
                $tempDirs = @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)
                foreach ($tempDir in $tempDirs) {
                    Remove-EmptyDirectories -RootPath $tempDir
                }
                Remove-StaleJunkFolders
            }
            'Orphan Scan' { Find-OrphanFolders }
            'Prefetch' { Clear-Prefetch }
            'DISM' { 
                # DISM cleanup would be done via external command
                Write-CommandLog 'DISM cleanup skipped (would run externally)'
            }
            'Event Logs + Font Cache' { 
                Clear-EventLogs
                Clear-FontCache
            }
        }
    }
    
    # Return results
    return [PSCustomObject]@{
        Mode = $Mode
        BytesFreed = [long]$script:BytesFreed
        CategorySizes = $script:CategorySizes
        Errors = $script:Errors
        SkippedItems = $script:SkippedItems
        OrphanFounds = if($script:OrphanFolders) { $script:OrphanFolders.Count } else { 0 }
    }
}

# Export functions
Export-ModuleMember -Function Get-CleanupTasks, Measure-AndClear, Remove-FilesByPattern, Clear-SystemCaches, Clear-ChromiumCaches, Clear-FirefoxCaches, Clear-AppCaches, Clear-DevCaches, Clear-GpuAndShellCaches, Clear-RecycleBinSafe, Clear-SystemLogFiles, Remove-EmptyDirectories, Remove-StaleJunkFolders, Find-OrphanFolders, Invoke-ComponentCleanup, Clear-EventLogs, Clear-Prefetch, Clear-FontCache, Invoke-CleanupRun