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
    param(
        [AllowEmptyString()][string]$Path,
        [switch]$EnsureDirectory,
        [AllowEmptyString()][string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # CHOKE POINT: All deletions must pass exclusion check first
    if (Test-IsExcludedPath $Path) {
        Write-Log "SKIP (excluded) $Path" 'WARN'
        Register-SkippedItem -Reason 'Path is excluded from cleanup' -Target $Path
        if ($null -ne $script:TaskSkipped) { $script:TaskSkipped++ }
        return $false
    }

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            if ($EnsureDirectory) {
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
                # Creating the requested directory IS the work; empty dir = success.
                return $true
            } else {
                return $false
            }
        }
        
        $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Measure-Object
        if ($items.Count -gt 0) {
            if (-not $script:IsPreview) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -eq $false }
            $size = if ($files) { ($files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum } else { 0 }
            if ($null -eq $size) { $size = 0 }
            $script:BytesFreed += [long]$size
            if ($Category) {
                if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
                $script:CategorySizes[$Category] = [long]$size
            }
            Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" "$Path ($([math]::Round($size/1MB, 2)) MB)"
            if ($null -ne $script:TaskCleared) { $script:TaskCleared++ }
            if ($null -ne $script:TaskBytes)  { $script:TaskBytes += [long]$size }
            return $true
        }
        return $false
    } catch {
        # Single collection point: record even without a Category (fallback label).
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
    param([ValidateSet('Standard','Aggressive')][string]$Mode = 'Standard')
    $results = [System.Collections.Generic.List[System.Object]]::new()
    $tasks = Get-CleanupTasks -Mode $Mode
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
                $browserRoots = @(
                    (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data\Default\Cache'),
                    (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data\Default\Cache'),
                    (Join-EnvPath 'APPDATA' 'Mozilla\Firefox\Profiles')
                )
                foreach ($br in $browserRoots) {
                    if ($br -and (Test-Path -LiteralPath $br -PathType Container)) {
                        $bytes += Get-DirectorySize $br
                        $count++
                    }
                }
            }
            'App Caches' {
                $applist = Get-AllAppDefinitions
                foreach ($app in $applist) {
                    if (-not $app.Name) { continue }
                    $expandedPath = $app.Path -replace '{username}',$env:USERNAME
                    $expandedPath = $expandedPath -replace '{appdata}', $env:APPDATA
                    $expandedPath = $expandedPath -replace '{localappdata}', $env:LOCALAPPDATA
                    $expandedPath = $expandedPath -replace '{programdata}', $env:PROGRAMDATA
                    $expandedPath = $expandedPath -replace '{commonprogramfiles}', $env:COMMONPROGRAMFILES
                    $expandedPath = $expandedPath -replace '{systemdrive}', $env:SYSTEMDRIVE
                    $expandedPath = $expandedPath -replace '{windows}', $env:WINDIR
                    if ($expandedPath -like '*{*}*') { continue }
                    if (-not $expandedPath) { continue }
                    if (Test-Path -LiteralPath $expandedPath -PathType Container) {
                        $bytes += Get-DirectorySize $expandedPath
                        $count++
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
                # NEW: Process devtools-extended app definitions
                $extendedDefs = Get-AppDefinitions -Category 'devtools-extended'
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
                        if ($expandedPath -like '*{*}*') {
                            $patternPath = $expandedPath -replace '{[^}]+}','*'
                            $matches = Get-ChildItem -Path (Split-Path $patternPath) -Filter (Split-Path -Leaf $patternPath) -Directory -ErrorAction SilentlyContinue
                            foreach ($match in $matches) {
                                $resolvedPath = Join-Path $match.FullName (Split-Path -Leaf $expandedPath)
                                if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                                    $bytes += Get-DirectorySize $resolvedPath
                                    $count++
                                }
                            }
                          } else {
                              if (Test-Path -LiteralPath $expandedPath -PathType Container) {
                                  $bytes += Get-DirectorySize $expandedPath
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
                    (Join-EnvPath 'LOCALAPPDATA' 'Roblox' 'Versions'),
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
            'Empty/Stale Folders' {
                foreach ($t in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'), $script:SysLoc.WindowsTemp)) {
                    if ($t -and (Test-Path -LiteralPath $t -PathType Container)) {
                        $bytes += Get-DirectorySize $t
                        $count++
                    }
                }
            }
            'Orphan Scan' {
                # Only scan safe orphan locations (temp, cache)
                foreach ($r in @(
                    (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
                    (Get-EnvPath 'TEMP'),
                    (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\INetCache')
                )) {
                    if ($r -and (Test-Path -LiteralPath $r -PathType Container)) {
                        $bytes += Get-DirectorySize $r
                        $count++
                    }
                }
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
    param([ValidateNotNullOrEmpty()][string]$Directory, [ValidateNotNullOrEmpty()][string[]]$Patterns, [string]$Category='General')
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
    [CmdletBinding()]
    param()
    $cat = 'System Caches'; $n = 0
    # Resolve then dedupe: %TEMP% and %LOCALAPPDATA%\Temp are usually the same directory
    $targets = @(
        (Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp, (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive, $script:SysLoc.WerQueue, $script:SysLoc.NetDownloader
    ) | Where-Object { $_ } | ForEach-Object { Resolve-FullPath $_ } | Select-Object -Unique
    foreach ($t in $targets) { if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ } }
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
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ProfileRoot)
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
    [CmdletBinding()]
    param()
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

    # NEW: Process devtools-extended app definitions for .local, .cache, scoop, cargo, android, go, bun
    $extendedDefs = Get-AppDefinitions -Category 'devtools-extended'
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

            # Handle wildcard profiles (Firefox-style {guid})
            if ($expandedPath -like '*{*}*') {
                $patternPath = $expandedPath -replace '{[^}]+}','*'
                $matches = Get-ChildItem -Path (Split-Path $patternPath) -Filter (Split-Path -Leaf $patternPath) -Directory -ErrorAction SilentlyContinue
                foreach ($match in $matches) {
                    $resolvedPath = Join-Path $match.FullName (Split-Path -Leaf $expandedPath)
                    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
                        if (Measure-AndClear $resolvedPath -Category "$cat - $($app.Name)") { $n++ }
                    }
                }
              } else {
                  if (Test-Path -LiteralPath $expandedPath -PathType Container) {
                      if (Measure-AndClear $expandedPath -Category "$cat - $($app.Name)") { $n++ }
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
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD'),
        (Join-EnvPath 'APPDATA' 'ShellExView'),
        (Join-EnvPath 'LOCALAPPDATA' 'IconCache.db')
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
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        }
          Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" "Recycle Bin"
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
    if ([string]::IsNullOrWhiteSpace($RootPath)) { return }
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return }
    try {
        $dirs = Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -ErrorAction SilentlyContinue | Sort-Object -Property FullName -Descending
        foreach ($dir in $dirs) {
            $items = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
            if ($items.Count -eq 0) {
                if (-not $script:IsPreview) {
                    Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                }
                Write-CommandLog "REMOVE $(if($script:IsPreview){'PREVIEW'}else{''})" $dir.FullName
                  if ($null -ne $script:TaskCleared) { $script:TaskCleared++ }
              }
          }
      } catch {
          Register-CleanupError -Path $RootPath -Category 'Empty/Stale Folders' -Message $_.Exception.Message
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
    param()
    Write-CommandLog 'SCAN' 'Orphan Folders'
    
    # Check if we have cached orphans (from previous scan)
    if ($script:OrphanCache -and $script:OrphanCacheTime) {
        $cacheAge = (New-TimeSpan -Start $script:OrphanCacheTime -End (Get-Date)).TotalSeconds
        if ($cacheAge -lt 300) {  # 5 minute cache
            Write-Verbose "Using cached orphan results (age: $([int]$cacheAge)s)"
            return $script:OrphanCache
        }
    }
    
    $orphans = @()
    
    # Safe orphan locations - these are truly garbage, safe to delete
    $safeOrphanPatterns = @(
        @{
            Path = Join-EnvPath 'LOCALAPPDATA' 'Temp'
            Pattern = '*'
            Description = 'Local Temp Files'
            MinAge = 7  # Days old
            SafeDelete = $true
        },
        @{
            Path = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
            Pattern = '*'
            Description = 'System Temp Files'
            MinAge = 7
            SafeDelete = $true
        },
        @{
            Path = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\INetCache'
            Pattern = '*'
            Description = 'Internet Explorer Cache'
            MinAge = 0
            SafeDelete = $true
        },
        @{
            Path = Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data\Default\Cache'
            Pattern = '*'
            Description = 'Chrome Cache'
            MinAge = 0
            SafeDelete = $true
        },
        @{
            Path = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data\Default\Cache'
            Pattern = '*'
            Description = 'Edge Cache'
            MinAge = 0
            SafeDelete = $true
        },
        @{
            Path = Join-EnvPath 'APPDATA' 'Microsoft\Windows\Recent'
            Pattern = '*.lnk'
            Description = 'Broken Shortcuts'
            MinAge = 0
            SafeDelete = $true
        }
    )
    
    # Critical system paths to NEVER touch
    $criticalPaths = @(
        "$env:SystemRoot",
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        (Join-EnvPath 'APPDATA' 'Microsoft'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows')
    )
    
    # Get list of currently running processes to avoid deleting active files
    $runningProcesses = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName
    
    foreach ($pattern in $safeOrphanPatterns) {
        $scanPath = $pattern.Path
        if (-not $scanPath -or -not (Test-Path $scanPath -PathType Container)) { continue }
        
        # Safety check: never scan critical paths
        $isCritical = $false
        foreach ($critical in $criticalPaths) {
            if ($scanPath -like "$critical*") {
                $isCritical = $true
                break
            }
        }
        if ($isCritical) { continue }
        
        try {
            Get-ChildItem -LiteralPath $scanPath -Filter $pattern.Pattern -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $item = $_
                
                # Skip if currently in use by running process
                $inUse = $false
                foreach ($proc in $runningProcesses) {
                    if ($item.Name -match [regex]::Escape($proc)) {
                        $inUse = $true
                        break
                    }
                }
                if ($inUse) { return }
                
                $size = if ($item.PSIsContainer) { Get-DirectorySize $item.FullName } else { $item.Length }
                $daysSinceModified = ((Get-Date) - $item.LastWriteTime).TotalDays
                
                # Only include if old enough and not currently in use
                if ($daysSinceModified -ge $pattern.MinAge -and $size -gt 0) {
                    $orphans += [PSCustomObject]@{
                        Path = $item.FullName
                        Name = $item.Name
                        Size = $size
                        DaysSinceModified = [int]$daysSinceModified
                        Category = $pattern.Description
                        Tier = 'Tier1'  # Safe to delete
                        RiskLevel = 'Safe'
                        SafeDelete = $pattern.SafeDelete
                    }
                }
            }
          } catch {
              Register-CleanupError -Path $scanPath -Category 'Orphan Scan' -Message $_.Exception.Message
              Write-Verbose "Error scanning $scanPath : $_"
          }
    }
    
    # Cache the results
    $script:OrphanCache = $orphans
    $script:OrphanCacheTime = Get-Date
    
    return $orphans
}

function Clear-CachedOrphans {
    [CmdletBinding()]
    param([switch]$Preview)
    
    if (-not $script:OrphanCache -or $script:OrphanCache.Count -eq 0) {
        Write-CommandLog 'INFO' 'No cached orphans to clean'
        return 0
    }
    
    $totalSize = 0L
    $deletedCount = 0
    
    foreach ($orphan in $script:OrphanCache) {
        # Safety: only delete if marked as safe
        if (-not $orphan.SafeDelete) { continue }
        
        # Skip if path doesn't exist anymore
        if (-not (Test-Path -LiteralPath $orphan.Path)) { continue }
        
        try {
            if (-not $Preview) {
                Remove-Item -LiteralPath $orphan.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
            $totalSize += $orphan.Size
            $deletedCount++
            Write-CommandLog "CLEAR $(if($Preview){'PREVIEW'}else{''})" $orphan.Path
            if ($null -ne $script:TaskCleared) { $script:TaskCleared++ }
          } catch {
              Register-CleanupError -Path $orphan.Path -Category 'Orphan Scan' -Message $_.Exception.Message
              Write-Verbose "Failed to delete orphan $($orphan.Path): $_"
          }
    }
    
    $script:BytesFreed += $totalSize
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
    $script:CategorySizes['Orphan Files'] = $totalSize
    
    # Clear cache after deletion
    $script:OrphanCache = $null
    $script:OrphanCacheTime = $null
    
    return $deletedCount
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
    try {
        if (-not $script:IsPreview) {
            Get-EventLog -List | ForEach-Object {
                Clear-EventLog -LogName $_.Log -ErrorAction SilentlyContinue
            }
        }
          Write-CommandLog "CLEAR $(if($script:IsPreview){'PREVIEW'}else{''})" 'Event Logs'
          return $true
      } catch {
          Register-CleanupError -Path 'Event Logs' -Category 'Log Files' -Message $_.Exception.Message
          return $false
      }
}

function Clear-FontCache {
    [CmdletBinding()]
    param()
    $fontCache = Join-EnvPath 'LOCALAPPDATA' 'Microsoft' 'Windows' 'FontCache'
    $cat = 'Font Cache'
    return (Measure-AndClear $fontCache -Category $cat)
}

function Invoke-CleanupRun {
    [CmdletBinding()]
    param(
        [ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard',
        [switch]$WhatIf,
        [AllowNull()][hashtable]$Config
    )
    
    # Reset script tracking variables if not already set
    if (-not $script:BytesFreed) { $script:BytesFreed = 0 }
    if (-not $script:CategorySizes) { $script:CategorySizes = @{} }
    if (-not $script:Errors) { $script:Errors = @() }
    if (-not $script:SkippedItems) { $script:SkippedItems = @() }
    if (-not $script:IsPreview) { $script:IsPreview = ($WhatIf.IsPresent -or ($Mode -eq 'Preview')) }
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

    $modeNote = switch ($Mode) {
        'Preview'    { 'nothing will be deleted' }
        'Aggressive' { 'deep clean - files will be deleted' }
        default      { 'files will be deleted' }
    }
    Write-Host ''
    Write-Host ("Bakunawa - {0}: {1} tasks - {2}" -f $Mode, $tasks.Count, $modeNote) -ForegroundColor White

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
        
        switch ($taskName) {
            'System Caches' { $null = Clear-SystemCaches }
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
                        $null = Clear-ChromiumCaches -UserDataRoot $browser.UserDataRoot -Label $browser.Label
                    }
                } else {
                    foreach ($browser in $browserPaths) {
                        $null = Clear-ChromiumCaches -UserDataRoot $browser.UserDataRoot -Label $browser.Label
                    }
                }
                
                # Firefox
                $ffProfile = (Join-EnvPath 'APPDATA' 'Mozilla' 'Firefox' 'Profiles')
                if (Test-Path -LiteralPath $ffProfile -PathType Container) {
                    $profiles = Get-ChildItem -LiteralPath $ffProfile -Directory -Filter '*.default*' -ErrorAction SilentlyContinue
                    foreach ($profile in $profiles) {
                        $null = Clear-FirefoxCaches -ProfileRoot $profile.FullName
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
                # DISM cleanup would be done via external command
                Write-CommandLog 'DISM cleanup skipped (would run externally)'
            }
             'Event Logs + Font Cache' { 
                 $null = Clear-EventLogs
                 $null = Clear-FontCache
             }
             'Cloud Sync' {
                 # OneDrive, Google Drive, Dropbox temp files
                 $applist = Get-AllAppDefinitions
                 foreach ($app in $applist) {
                     if ($app.Category -like '*Cloud*' -or $app.Name -like '*OneDrive*' -or $app.Name -like '*Drive*' -or $app.Name -like '*Dropbox*') {
                         if ($app.Path) {
                             $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                             if ((Test-Path -LiteralPath $expandedPath -PathType Container)) {
                                 Measure-AndClear $expandedPath -Category 'Cloud Sync' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Creative Apps' {
                 # Adobe, Affinity, Blender, etc. caches
                 $applist = Get-AllAppDefinitions
                 foreach ($app in $applist) {
                     if ($app.Category -like '*Creative*' -or $app.Category -like '*Design*' -or $app.Category -like '*Media*') {
                         if ($app.Path) {
                             $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                             if ((Test-Path -LiteralPath $expandedPath -PathType Container)) {
                                 Measure-AndClear $expandedPath -Category 'Creative Apps' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'Productivity' {
                 # Office, Slack, Teams, etc. caches
                 $applist = Get-AllAppDefinitions
                 foreach ($app in $applist) {
                     if ($app.Category -like '*Office*' -or $app.Category -like '*Productivity*' -or $app.Category -like '*Communication*') {
                         if ($app.Path) {
                             $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                             if ((Test-Path -LiteralPath $expandedPath -PathType Container)) {
                                 Measure-AndClear $expandedPath -Category 'Productivity' -EA SilentlyContinue | Out-Null
                             }
                         }
                     }
                 }
             }
             'DevOps Tools' {
                 # Docker, Kubernetes, Terraform, etc. caches
                 $applist = Get-AllAppDefinitions
                 foreach ($app in $applist) {
                     if ($app.Category -like '*DevOps*' -or $app.Category -like '*Docker*' -or $app.Category -like '*Kubernetes*') {
                         if ($app.Path) {
                             $expandedPath = $app.Path -replace '{username}',$env:USERNAME -replace '{appdata}', $env:APPDATA -replace '{localappdata}', $env:LOCALAPPDATA
                             if ((Test-Path -LiteralPath $expandedPath -PathType Container)) {
                                 Measure-AndClear $expandedPath -Category 'DevOps Tools' -EA SilentlyContinue | Out-Null
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

        # Compose informative per-task summary
        $script:RunCleared += $script:TaskCleared
        $parts = @()
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
        BytesFreed = [long]$script:BytesFreed
        PathsCleared = [int]$script:RunCleared
        CategorySizes = $script:CategorySizes
        Errors = $script:Errors
        SkippedItems = $script:SkippedItems
        OrphanFounds = if($script:OrphanFolders) { $script:OrphanFolders.Count } else { 0 }
        DurationSec = [math]::Round($runStopwatch.Elapsed.TotalSeconds, 1)
    }
}

function Clear-GameCaches {
    [CmdletBinding()]
    param()
    Write-CommandLog 'SCAN' 'Game Platform Caches'
    $cat = 'Game Caches'; $n = 0
    
    # Roblox Studio cache
    $robloxStudio = Join-EnvPath 'LOCALAPPDATA' 'Roblox' 'Versions'
    if ($robloxStudio -and (Test-Path -LiteralPath $robloxStudio -PathType Container)) {
        if (Measure-AndClear $robloxStudio -Category $cat) { $n++ }
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
    'Clear-CachedOrphans',
    'Clear-Prefetch',
    'Clear-EventLogs',
    'Clear-FontCache',
    'Get-CleanupErrorLog',
    'Invoke-CleanupRun'
)
