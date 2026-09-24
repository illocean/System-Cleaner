# Loaded into the cleanup module so scan results and cleanup share one state owner.
function Get-ScanDriveRoots {
    [CmdletBinding()]
    param()
    'C:\'
}

function Initialize-CleanupState {
    [CmdletBinding()]
    param([hashtable]$Config, [string[]]$ScanRoot, [string[]]$ExtraExcludePath)
    if (-not $Config) { $Config = Get-UserConfig }
    $script:CleanupConfig = $Config
    if ($PSBoundParameters.ContainsKey('ScanRoot')) { $script:ScanRoots = $ScanRoot }
    if (-not $script:ScanRoots -and $Config.scanSettings.roots) { $script:ScanRoots = $Config.scanSettings.roots }
    if ($PSBoundParameters.ContainsKey('ExtraExcludePath')) { $script:ExtraExcludePaths = $ExtraExcludePath }
    $null = Initialize-CoreSafetyState -Config $Config -ExtraExcludePath $script:ExtraExcludePaths
    $script:SysLoc = Get-SystemLocations
    $script:RunningProcesses = Get-RunningProcessNames
    $script:ProcessedCacheRoots = New-TrackedSet
    $script:BusyCachePaths = [Collections.Generic.List[string]]::new()
    $script:KnownCachePaths = @{}
    $cacheNames = Get-DisposableDirectoryNames
    foreach ($app in @(Get-AllAppDefinitions)) {
        if ($app.Path) {
            $busy = $app.Process -and (Test-AnyProcessRunning -RunningProcesses $script:RunningProcesses -Names @($app.Process))
            $cacheName = [IO.Path]::GetFileName($app.Path.Replace('/', '\').TrimEnd('\'))
            if (-not $busy -and -not $cacheNames.Contains($cacheName)) { continue }
            try { $paths = @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly) }
            catch { Register-SkippedItem -Reason $_.Exception.Message -Target $app.Path; continue }
            foreach ($path in $paths) {
                $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
                if ($busy) { $script:BusyCachePaths.Add($full) }
                # Only explicitly named disposable caches qualify; installed tools and app data do not.
                if ($cacheNames.Contains([IO.Path]::GetFileName($full))) { $script:KnownCachePaths[$full] = $app }
            }
        }
    }
    $script:UseQuarantine = ($Config.behaviorSettings.quarantineBeforeDelete -ne $false)
    $script:OrphanCache = $null
    $script:OrphanCacheTime = $null
    $script:LastScanReport = $null
}

function Get-ScanExclusions {
    $paths = @(Get-CoreExcludedPaths)
    foreach ($name in @('SystemRoot','ProgramFiles','ProgramFiles(x86)')) {
        $path = Get-EnvPath $name
        if ($path) { $paths += $path }
    }
    # Never rediscover quarantine, synced offline data, or Windows-managed stores.
    if (Get-Command Get-QuarantineRoot -ErrorAction Ignore) { $paths += Get-QuarantineRoot }
    $paths += Join-Path (Get-EnvPath 'LOCALAPPDATA') 'Bakunawa'
    foreach ($root in @(Get-ScanDriveRoots)) {
        foreach ($name in @('$Recycle.Bin','System Volume Information','Windows','Windows.old','Recovery','MSOCache')) {
            $paths += Join-Path $root $name
        }
    }
    @($paths | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
}

function Test-BrokenLocalShortcut {
    param([string]$Path)
    try {
        if (-not $script:ShortcutShell) { $script:ShortcutShell = New-Object -ComObject WScript.Shell -ErrorAction Stop }
        $shortcut = $script:ShortcutShell.CreateShortcut($Path)
        try { $target = [Environment]::ExpandEnvironmentVariables($shortcut.TargetPath) }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        # Empty/advertised shortcuts and unavailable/network targets are inconclusive.
        if (-not [Bakunawa.Scanner]::IsAllowedPath($target) -or $target -match '%[^%]+%') { return $false }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))
        if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { return $false }
        try { $null = Get-Item -LiteralPath $target -Force -ErrorAction Stop; return $false }
        catch [System.Management.Automation.ItemNotFoundException] {
            # Only a readable parent establishes absence, not an access-denied error.
            $parent = Split-Path -Parent $target
            while ($parent -and -not (Test-Path -LiteralPath $parent)) { $parent = Split-Path -Parent $parent }
            if (-not $parent) { return $false }
            $null = Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop
            return $true
        }
    } catch { Write-Verbose "Shortcut could not be verified: $Path : $_" }
    return $false
}

function Get-ScanTempRoots {
    param([string[]]$Roots)
    $paths = @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'))
    # A directory named Temp on another drive is a review candidate, not proof of disposal intent.
    @($paths | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
}

function Invoke-OrphanDiscovery {
    [CmdletBinding()]
    param([string[]]$Roots, [ValidateRange(1,3650)][int]$OlderThanDays = 30, [switch]$Refresh)
    if (-not $script:CleanupConfig) { Initialize-CleanupState }
    if (-not $PSBoundParameters.ContainsKey('OlderThanDays') -and $script:CleanupConfig.scanSettings) {
        $OlderThanDays = [int]$script:CleanupConfig.scanSettings.minAgeDays
        if ($OlderThanDays -lt 1 -or $OlderThanDays -gt 3650) { throw 'Scan minimum age must be between 1 and 3650 days.' }
    }
    if (-not $Roots) { $Roots = $script:ScanRoots }
    if (-not $Roots) { $Roots = @(Get-ScanDriveRoots) }
    $exclusions = @(Get-ScanExclusions | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $normalized = @($Roots | ForEach-Object {
        if ($_ -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)') { throw "Scan roots must be absolute: $_" }
        if ($_ -notmatch '^C:[\\/]') { throw "Only local disk C: can be scanned: $_" }
        [IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
    } | Sort-Object Length)
    $rootsToScan = [Collections.Generic.List[string]]::new()
    foreach ($root in $normalized) {
        $covered = $false
        foreach ($existing in $rootsToScan) { if ([Bakunawa.Scanner]::Within($root.TrimEnd('\'), $existing)) { $covered = $true; break } }
        if (-not $covered) { $rootsToScan.Add($root) }
    }
    $cacheKey = (@($rootsToScan) -join '|') + ";$OlderThanDays;" + ($exclusions -join '|')
    if (-not $Refresh -and $script:OrphanCacheTime -and $script:OrphanCacheKey -eq $cacheKey -and
        ((Get-Date) - $script:OrphanCacheTime).TotalSeconds -lt 300) {
        Write-ReviewLine ("Using discovery results from {0}; no new filesystem walk." -f $script:OrphanCacheTime.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-ScanReportLog -Report $script:LastScanReport
        return $script:OrphanCache
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-ReportHeading 'DISCOVERY / READ ONLY'
    Write-ReportMetric 'Scope' 'Local disk C: only'
    Write-ReportMetric 'Roots selected' ([string]$rootsToScan.Count)
    Write-ReportMetric 'Minimum age' ("$OlderThanDays days")
    Write-ReviewLine 'Preparing application ownership checks, then walking each root. Total size is unknown.'
    Write-ReviewLine 'Progress candidates are provisional; nested findings are combined after scanning.' -ForegroundColor Gray
    foreach ($path in $exclusions) { Write-ScanLogText ("EXCLUSION | {0}" -f $path) }
    $findings = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    $coverage = [Collections.Generic.List[object]]::new()
    $tempRoots = @(Get-ScanTempRoots -Roots @($rootsToScan))
    $appRoots = @((Get-EnvPath 'LOCALAPPDATA'), (Get-EnvPath 'APPDATA'), (Get-EnvPath 'ProgramData')) | Where-Object { $_ }
    $installed = @(Get-InstalledApplicationNames -SkipCaching)
    $running = @(Get-RunningProcessNames)
    $ownerNames = @($installed) + @($running | ForEach-Object { $_ })
    $cacheNames = Get-DisposableDirectoryNames
    $cutoff = [DateTime]::UtcNow.AddDays(-$OlderThanDays)
    $lastProgress = 0L
    $rootIndex = 0
    try {
        foreach ($root in $rootsToScan) {
            $rootIndex++
            $driveWatch = [Diagnostics.Stopwatch]::StartNew()
            $directories = 0L; $errors = 0; $skipped = 0; $files = 0L
            $visited = 0L
            Write-CommandLog 'SCAN' $root
            Write-ScanProgress -Root $root -RootIndex $rootIndex -RootCount $rootsToScan.Count -Candidates $findings.Count -Seconds $watch.Elapsed.TotalSeconds -CurrentPath $root -Force
            foreach ($entry in [Bakunawa.Scanner]::Walk($root, [string[]]($exclusions + @($script:BusyCachePaths)), $true)) {
                if ($entry.Kind -eq 'Progress') { $visited = $entry.Files }
                if ($watch.ElapsedMilliseconds - $lastProgress -ge 200) {
                    Write-ScanProgress -Root $root -RootIndex $rootIndex -RootCount $rootsToScan.Count -Visited $visited -Directories $directories -Candidates $findings.Count -Errors $errors -Skipped $skipped -Seconds $watch.Elapsed.TotalSeconds -CurrentPath $entry.Path
                    $lastProgress = $watch.ElapsedMilliseconds
                }
                if ($entry.Kind -in @('Error','Skipped')) {
                    $issueReason = if ($entry.Path -in $script:BusyCachePaths) { 'Close the owning app and rescan to review this cache.' } else { $entry.Message }
                    $issues.Add([pscustomobject]@{ Path = $entry.Path; Reason = $issueReason; Kind = $entry.Kind })
                    Write-ScanLogText ("{0} | {1} | {2}" -f $entry.Kind, $entry.Path, $issueReason)
                    if ($entry.Kind -eq 'Error') { $errors++ } else { $skipped++ }
                    continue
                }
                if ($entry.Kind -eq 'Progress') { continue }
                if ($entry.Kind -ne 'File') { $directories++ }
                if ($entry.Path.TrimEnd('\') -eq $root.TrimEnd('\')) { $files = $entry.Files; continue }
                if (-not $entry.Complete) { continue }
                $knownApp = $script:KnownCachePaths[$entry.Path]
                if ($entry.LatestWriteUtc -gt $cutoff -and -not $knownApp) { continue }
                $name = [IO.Path]::GetFileName($entry.Path)
                $parent = [IO.Path]::GetDirectoryName($entry.Path)
                $inTemp = $false
                foreach ($temp in $tempRoots) { if ([Bakunawa.Scanner]::Within($entry.Path, $temp)) { $inTemp = $true; break } }
                $category = $null; $reason = $null; $safe = $false
                if ($knownApp -and $entry.Kind -ne 'File' -and $entry.Bytes -gt 0) {
                    $category = 'Known app cache'
                    $reason = "Matched $($knownApp.Name) cache in $($knownApp.SourceFile). Review before removal; the app may rebuild or download it again."
                } elseif ($entry.LatestWriteUtc -gt $cutoff) { continue
                } elseif ($entry.Kind -eq 'File') {
                    $ext = [IO.Path]::GetExtension($entry.Path).ToLowerInvariant()
                    if ($ext -eq '.lnk') {
                        if (Test-BrokenLocalShortcut $entry.Path) { $category = 'Broken shortcut'; $reason = 'Local target is missing on an available drive; review before removal.' }
                    } elseif ($ext -in @('.tmp','.temp','.dmp') -or ($ext -eq '.log' -and ($inTemp -or $parent -match '(?i)\\logs?(\\|$)'))) {
                        $category = if ($ext -eq '.log') { 'Stale log file' } else { 'Stale temporary file' }
                        $reason = "Unmodified for at least $OlderThanDays days; extension $ext."
                        $safe = $inTemp
                    }
                } elseif ($inTemp -and $entry.Path -notin $tempRoots) {
                    $category = 'Stale temp folder'; $safe = $true
                    $reason = "Known temp location; all readable contents unmodified for at least $OlderThanDays days."
                } elseif ($cacheNames.Contains($name)) {
                    $category = 'Stale cache folder'
                    $reason = "Cache-like name; all contents unmodified for at least $OlderThanDays days. Ownership is unverified."
                } elseif ($parent -in $appRoots -and $name -notin @('Microsoft','Packages','Programs','Windows','Temp','Application Data')) {
                    $normalizedName = ($name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                    $matched = $false
                    foreach ($owner in $ownerNames) {
                        $ownerKey = ([string]$owner -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                        if ($ownerKey -and ($ownerKey.Contains($normalizedName) -or $normalizedName.Contains($ownerKey))) { $matched = $true; break }
                    }
                    if (-not $matched) {
                        $category = 'Possible app leftover'
                        $reason = 'No matching installed-app or running-process name. Portable and Store apps may still own this folder.'
                    }
                } elseif ($entry.Kind -eq 'EmptyDirectory') {
                    $category = 'Stale empty folder'
                    $reason = "Empty and unmodified for at least $OlderThanDays days; apps may still require it."
                }
                if (-not $category) { continue }
                $findings.Add([pscustomobject]@{
                    Path = $entry.Path; Name = $name; Size = [long]$entry.Bytes; FileCount = $entry.Files
                    DaysSinceModified = [int]([DateTime]::UtcNow - $entry.LatestWriteUtc).TotalDays
                    LatestWriteUtc = $entry.LatestWriteUtc; Category = $category; Reason = $reason
                    Tier = $(if ($safe) { 'Tier1' } else { 'Tier2' }); RiskLevel = $(if ($safe) { 'Low' } else { 'Medium' })
                    RiskScore = $(if ($safe) { 0 } else { 50 }); SafeDelete = $safe
                    DetectorName = 'Find-OrphanFolders'; ScanRoot = $root; IsDirectory = ($entry.Kind -ne 'File')
                })
                Write-ScanLogText ("PROVISIONAL CANDIDATE | {0} | {1} bytes | {2} | {3}" -f $entry.Path, $entry.Bytes, $category, $reason)
            }
            $coverage.Add([pscustomobject]@{ Root = $root; Directories = $directories; Files = $files; Errors = $errors; Skipped = $skipped
                DurationSec = [math]::Round($driveWatch.Elapsed.TotalSeconds, 2); Status = $(if ($errors) { 'Partial' } elseif (-not $directories) { 'Unavailable or excluded' } else { 'Complete within exclusions' }) })
            Write-ReviewLine ("Root {0}/{1} finished | {2:N0} files | {3:N0} folders | {4:N0} errors | {5:N0} excluded / skipped | {6}" -f $rootIndex, $rootsToScan.Count, $files, $directories, $errors, $skipped, (Format-ReportDuration $driveWatch.Elapsed.TotalSeconds))
        }
    } finally {
        Write-Progress -Id 2 -Activity 'Bakunawa discovery' -Completed
        if ($script:ShortcutShell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($script:ShortcutShell); $script:ShortcutShell = $null }
    }
    # Keep non-overlapping outermost findings: a folder includes its children's bytes.
    Write-ReviewLine 'Finalizing report: combining nested candidates and totaling data...' -ForegroundColor Cyan
    $selected = New-TrackedSet
    $unique = [Collections.Generic.List[object]]::new()
    foreach ($finding in ($findings | Sort-Object { $_.Path.Length })) {
        $ancestor = $finding.Path; $covered = $false
        while ($ancestor) {
            if ($selected.Contains($ancestor)) { $covered = $true; break }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        if (-not $covered) { [void]$selected.Add($finding.Path); $unique.Add($finding) }
    }
    $script:OrphanCache = @($unique | Sort-Object Size -Descending)
    $script:OrphanCacheTime = Get-Date
    $script:OrphanCacheKey = $cacheKey
    $script:LastScanReport = @{ Findings = $script:OrphanCache; Coverage = @($coverage); Issues = @($issues); Exclusions = $exclusions
        DurationSec = [math]::Round($watch.Elapsed.TotalSeconds, 2) }
    Write-ScanReportLog -Report $script:LastScanReport
    return $script:OrphanCache
}

function Get-OrphanScanReport { $script:LastScanReport }

function Clear-ReviewedOrphans {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path, [switch]$Preview)
    $running = Get-RunningProcessNames
    foreach ($target in $Path) {
        $target = [IO.Path]::GetFullPath($target).TrimEnd('\')
        $finding = $script:OrphanCache | Where-Object { $_.Path -eq $target } | Select-Object -First 1
        if (-not $finding) { throw "Rescan before selecting this path: $target" }
        foreach ($app in @(Get-AllAppDefinitions)) {
            if (-not $app.Path -or -not $app.Process -or -not (Test-AnyProcessRunning -RunningProcesses $running -Names @($app.Process))) { continue }
            foreach ($cache in @(Expand-WildcardPath -Path $app.Path -DirectoriesOnly)) {
                if ([Bakunawa.Scanner]::Within($target, $cache) -or [Bakunawa.Scanner]::Within($cache, $target)) {
                    throw "Close $($app.Name) and rescan before removal: $target"
                }
            }
        }
        $current = [Bakunawa.Scanner]::Inspect($target, [string[]]@(Get-ScanExclusions))
        if ($current.Bytes -ne $finding.Size -or $current.LatestWriteUtc -ne $finding.LatestWriteUtc -or $current.Files -ne $finding.FileCount) {
            throw "Changed since scan; rescan before removal: $target"
        }
        if ($finding.Category -eq 'Broken shortcut' -and -not (Test-BrokenLocalShortcut $target)) { throw "Shortcut target is no longer confirmed missing: $target" }
        # Review candidates always go to quarantine, independent of routine-cache settings.
        $manifest = Move-ItemToQuarantine -Path $target -Reason $finding.Reason -Tier $finding.Tier -DetectorName 'Find-OrphanFolders' -WhatIf:$Preview
        if (-not $manifest) { throw "Could not quarantine: $target" }
        $manifest
    }
}
