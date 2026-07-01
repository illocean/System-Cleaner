# Bakunawa.Core.psm1 — Core engine, safety, sizing, health

Set-Variable -Name ErrorActionPreference -Value 'SilentlyContinue' -Scope Script

# ── C# ACCELERATOR ──
try {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
public static class FastSys {
    public static long GetDirectorySize(string path) {
        long size = 0;
        try {
            var d = new DirectoryInfo(path);
            foreach (var f in d.GetFiles()) { size += f.Length; }
            foreach (var s in d.GetDirectories()) { size += GetDirectorySize(s.FullName); }
        } catch { /* Ignore locked/unauthorized folders */ }
        return size;
    }
}
"@ -ErrorAction SilentlyContinue
} catch {}

# ── SCRIPT STATE ──
$script:IsPreview        = $false
$script:IsAggressive     = $false
$script:CurrentModeName  = 'Menu'
$script:StepIndex        = 0
$script:TotalSteps       = 0
$script:ExcludedPaths    = $null
$script:LastRunSummary   = $null
$script:BytesFreed       = [long]0
$script:CategorySizes    = @{}
$script:OrphanReport     = @()
$script:SkippedItems     = @()
$script:RunningProcesses = $null
$script:ActiveStepName   = $null
$script:ActiveStepPct    = 0
$script:Errors           = @()
$script:LogFilePath      = ''
$script:HealthCache      = $null
$script:LastOrphanRisks  = $null
$script:SysLoc           = $null
$script:UiStopwatch      = $null
$script:LastUiMs         = 0
$script:UiTickMs         = 150

function Get-FreeSpaceInfo {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        $sd = [Environment]::GetEnvironmentVariable('SystemDrive','Process')
        if (-not $sd) { $sd = 'C:' }
        $DriveLetter = $sd.TrimEnd(':')
    }
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'" -ErrorAction SilentlyContinue
    if (-not $d) { return [PSCustomObject]@{MB=0;GB=0} }
    [PSCustomObject]@{
        MB = [math]::Round($d.FreeSpace / 1MB)
        GB = [math]::Round($d.FreeSpace / 1GB, 2)
    }
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [long]0 }
    if ([bool]('FastSys' -as [type])) { return [FastSys]::GetDirectorySize($Path) }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -EA SilentlyContinue |
        Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
    if ($null -eq $sum) { [long]0 } else { [long]$sum }
}

function Get-DirectorySizeEstimate {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path,
        [int]$MaxFiles = 1000
    )
    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            return [PSCustomObject]@{ Path = $Path; Bytes = [long]0; FileCount = 0; IsEstimate = $false }
        }
        $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -EA SilentlyContinue | Select-Object -First $MaxFiles
        $count = @($files).Count
        if ($count -eq 0) {
            return [PSCustomObject]@{ Path = $Path; Bytes = [long]0; FileCount = 0; IsEstimate = $false }
        }
        $sum = ($files | Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [PSCustomObject]@{
            Path       = $Path
            Bytes      = [long]$sum
            FileCount  = $count
            IsEstimate = ($count -ge $MaxFiles)
        }
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    "$Bytes B"
}

function New-TrackedSet {
    New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { Write-Verbose "Resolve-FullPath: $_"; return $null }
}

function Get-EnvPath {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($s in 'Process','User','Machine') {
        $v = [Environment]::GetEnvironmentVariable($Name, $s)
        $r = Resolve-FullPath $v
        if ($r) { return $r }
    }
    return $null
}

function Join-EnvPath {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath
    )
    $b = Get-EnvPath -Name $Name
    if (-not $b) { return $null }
    $joined = $b
    foreach ($segment in $ChildPath) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $joined = Join-Path $joined $segment
    }
    # Skip Resolve-FullPath if path contains wildcards to avoid errors
    if ($joined -match '[\?\*]') { return $joined }
    return Resolve-FullPath $joined
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param(
        [string]$SelectedMode,
        [string]$ScriptPath = ''
    )
    # Resolve the script to launch: caller-provided path, or $PSCommandPath, or fallback relative to module
    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $ScriptPath = if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
            $PSCommandPath
        } else {
            # Fallback: Bakunawa.ps1 lives one dir up from src/
            Join-Path (Split-Path $PSScriptRoot -Parent) 'Bakunawa.ps1'
        }
    }
    $args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ScriptPath`"")
    if ($SelectedMode) { $args_ += '-Mode'; $args_ += $SelectedMode }
    try {
        Write-Host ''
        Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args_ | Out-Null
        return $true
    } catch {
        Write-Host 'Elevation cancelled.' -ForegroundColor Red
        return $false
    }
}

function Get-ExcludedPaths {
    param([string[]]$ExtraExcludePath)
    $set = New-TrackedSet
    foreach ($c in @(
        (Join-EnvPath 'USERPROFILE' 'Downloads'),
        (Join-EnvPath 'USERPROFILE' 'Documents'),
        (Join-EnvPath 'USERPROFILE' 'Desktop'),
        (Join-EnvPath 'USERPROFILE' 'Pictures'),
        (Join-EnvPath 'USERPROFILE' 'Videos'),
        (Join-EnvPath 'USERPROFILE' 'Music'),
        (Join-EnvPath 'OneDrive' 'Downloads'),
        (Join-EnvPath 'LOCALAPPDATA' 'Packages')
    )) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    foreach ($c in $ExtraExcludePath) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    return $set
}

function Test-IsExcludedPath {
    param([string]$Path)
    $r = Resolve-FullPath $Path
    if (-not $r -or -not $script:ExcludedPaths) { return $false }
    foreach ($e in $script:ExcludedPaths) {
        if ($r.Equals($e,[StringComparison]::OrdinalIgnoreCase) -or
            $r.StartsWith("$e\",[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DefaultApprovedRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA'),
        (Get-EnvPath 'USERPROFILE'),
        $(if ($script:SysLoc) { $script:SysLoc.ProgramData }),
        $(if ($script:SysLoc) { $script:SysLoc.WindowsRoot })
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    return @($set)
}

function Test-SafeCleanupTarget {
    param([string]$Path, [string[]]$ApprovedRoots = @(), [switch]$AllowRoot)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or (Test-IsExcludedPath $resolved)) { return $false }
    $roots = @($ApprovedRoots | ForEach-Object { Resolve-FullPath $_ } | Where-Object { $_ })
    if (-not $roots) { $roots = Get-DefaultApprovedRoots }
    foreach ($root in $roots) {
        if ($resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $AllowRoot.IsPresent }
        if ($resolved.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DisposableDirectoryNames {
    $names = New-TrackedSet
    @(
        'cache','caches','code cache','gpucache','media cache','dawncache',
        'shadercache','grshadercache','graphitedawncache','startupcache','cache2',
        'temp','tmp','logs','log','crashpad','crashdumps','blob_storage'
    ) | ForEach-Object { [void]$names.Add($_) }
    return $names
}

function Test-IsDisposableLogPath {
    param([string]$Path, [string]$Root)
    $resolvedPath = Resolve-FullPath $Path
    $resolvedRoot = Resolve-FullPath $Root
    if (-not $resolvedPath -or -not $resolvedRoot) { return $false }
    if (-not $resolvedPath.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $relativeDirectory = Split-Path -Parent $resolvedPath
    if (-not $relativeDirectory.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $segmentNames = (Split-Path -NoQualifier $relativeDirectory).TrimStart('\').Split('\', [StringSplitOptions]::RemoveEmptyEntries)
    $disposableNames = Get-DisposableDirectoryNames
    foreach ($segment in $segmentNames) {
        if ($disposableNames.Contains($segment)) { return $true }
    }
    return $false
}

function Get-DisposableLogCandidates {
    param([string[]]$Roots, [int]$OlderThanDays = 14)
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $candidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($root in $Roots) {
        $resolvedRoot = Resolve-FullPath $root
        if (-not $resolvedRoot -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { continue }
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        try {
            $directory = [System.IO.DirectoryInfo]::new($resolvedRoot)
            foreach ($file in $directory.EnumerateFiles('*.log', [System.IO.SearchOption]::AllDirectories)) { $files.Add($file) }
        } catch {
            foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Filter '*.log' -File -Recurse -Force -EA SilentlyContinue)) { $files.Add($file) }
        }
        foreach ($file in $files) {
            if ($file.LastWriteTime -ge $cutoff) { continue }
            if (-not (Test-SafeCleanupTarget -Path $file.FullName -ApprovedRoots @($resolvedRoot) -AllowRoot)) { continue }
            if (-not (Test-IsDisposableLogPath -Path $file.FullName -Root $resolvedRoot)) { continue }
            $candidates.Add($file)
        }
    }
    return $candidates
}

function Get-StaleDisposableDirectories {
    param([string[]]$Roots, [int]$OlderThanDays = 45)
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $disposableNames = Get-DisposableDirectoryNames
    $candidates = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($root in $Roots) {
        $resolvedRoot = Resolve-FullPath $root
        if (-not $resolvedRoot -or -not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { continue }
        foreach ($directory in (Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -Force -EA SilentlyContinue)) {
            if ($directory.LastWriteTime -ge $cutoff) { continue }
            if (-not $disposableNames.Contains($directory.Name)) { continue }
            if (-not (Test-SafeCleanupTarget -Path $directory.FullName -ApprovedRoots @($resolvedRoot))) { continue }
            $candidates.Add($directory)
        }
    }
    return $candidates
}

function Get-JunkSweepRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $(if ($script:SysLoc) { $script:SysLoc.WindowsTemp }),
        $(if ($script:SysLoc) { $script:SysLoc.SoftDistDL }),
        $(if ($script:SysLoc) { $script:SysLoc.DeliveryOpt })
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    return @($set)
}

function Get-RunningProcessNames {
    $set = New-TrackedSet
    foreach ($name in (Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique)) {
        [void]$set.Add($name)
    }
    return $set
}

function Test-AnyProcessRunning {
    param($RunningProcesses, [string[]]$Names)
    foreach ($name in $Names) {
        if ($RunningProcesses.Contains($name)) { return $true }
    }
    return $false
}

function Register-SkippedItem {
    param([string]$Reason, [string]$Target)
    $script:SkippedItems += [PSCustomObject]@{ Reason = $Reason; Target = $Target }
    Write-Log "Skipped ${Target}: $Reason" 'WARN'
}

function Get-OrphanRiskScore {
    param([string]$Name, [long]$SizeBytes, [int]$DaysStale, [string]$PathSuffix,
          [string[]]$InstalledNames = @(), [string[]]$RunningNames = @())
    $staleness = if ($DaysStale -ge 365) { 40 } elseif ($DaysStale -ge 90) { 30 } elseif ($DaysStale -ge 30) { 15 } else { 0 }
    $sizeMB = $SizeBytes / 1MB
    $sizeScore = if ($sizeMB -ge 500) { 20 } elseif ($sizeMB -ge 200) { 15 } elseif ($sizeMB -ge 50) { 10 } elseif ($sizeMB -ge 1) { 5 } else { 0 }
    $installSignal = 0
    $nameLower = $Name.ToLowerInvariant()
    $foundExact = $false; $foundPartial = $false
    foreach ($n in $InstalledNames) {
        $nl = $n.ToLowerInvariant()
        if ($nl -eq $nameLower) { $foundExact = $true; break }
        if ($nl.Contains($nameLower) -or $nameLower.Contains($nl)) { $foundPartial = $true }
    }
    if (-not $foundExact) {
        foreach ($n in $RunningNames) {
            $nl = $n.ToLowerInvariant()
            if ($nl -eq $nameLower) { $foundExact = $true; break }
            if ($nl.Contains($nameLower) -or $nameLower.Contains($nl)) { $foundPartial = $true }
        }
    }
    $installSignal = if ($foundExact) { -30 } elseif ($foundPartial) { -10 } else { 0 }
    $pathScore = if ($PathSuffix -match 'ProgramData') { 5 } elseif ($PathSuffix -match 'Local') { 3 } else { 0 }
    $total = [Math]::Max(0, $staleness + $sizeScore + $installSignal + $pathScore)
    $level = if ($total -le 15) { 'Low' } elseif ($total -le 40) { 'Medium' } else { 'High' }
    $color = if ($total -le 15) { 'Green' } elseif ($total -le 40) { 'Yellow' } else { 'Red' }
    return [PSCustomObject]@{ Score = $total; RiskLevel = $level; Color = $color; Staleness = $staleness; SizeScore = $sizeScore; InstallSig = $installSignal; PathTrust = $pathScore }
}

function Get-HealthScore {
    $now = Get-Date
    if ($script:HealthCache -and ($now -lt $script:HealthCache.Expires)) { return $script:HealthCache.Data }
    $free = Get-FreeSpaceInfo
    $totalMB = $free.MB + 1
    $diskPct = [math]::Round(($free.MB / $totalMB) * 100)
    $diskScore = if ($diskPct -ge 30) { 30 } elseif ($diskPct -ge 20) { 25 } elseif ($diskPct -ge 10) { 15 } elseif ($diskPct -ge 5) { 5 } else { 0 }
    $tempTotal = 0L
    foreach ($tp in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'))) { $tempTotal += Get-DirectorySize $tp }
    $tempMB = $tempTotal / 1MB
    $tempScore = if ($tempMB -lt 500) { 25 } elseif ($tempMB -lt 2000) { 18 } elseif ($tempMB -lt 5000) { 10 } elseif ($tempMB -lt 10000) { 5 } else { 0 }
    $browserRoots = @(
        (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data\Default\Cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data\Default\Cache')
    )
    $oldestCacheDays = 0
    foreach ($br in $browserRoots) {
        if (Test-Path $br) {
            $age = ((Get-Date) - (Get-Item $br -EA SilentlyContinue).LastWriteTime).TotalDays
            if ($age -gt $oldestCacheDays) { $oldestCacheDays = [int]$age }
        }
    }
    $browserScore = if ($oldestCacheDays -lt 7) { 20 } elseif ($oldestCacheDays -lt 30) { 14 } elseif ($oldestCacheDays -lt 90) { 8 } else { 0 }
    $orphanScore = 25
    $orphanInfo = $script:LastOrphanRisks
    if ($orphanInfo) {
        $orphanScore = if ($orphanInfo.HighCount -eq 0 -and $orphanInfo.MedCount -lt 3) { 25 }
                    elseif ($orphanInfo.HighCount -le 2 -or $orphanInfo.MedCount -le 5) { 15 }
                    elseif ($orphanInfo.HighCount -le 5 -or $orphanInfo.MedCount -le 10) { 5 }
                    else { 0 }
    }
    $totalScore = $diskScore + $tempScore + $browserScore + $orphanScore
    $grade = if ($totalScore -ge 85) { 'Excellent' } elseif ($totalScore -ge 65) { 'Good' } elseif ($totalScore -ge 40) { 'Fair' } else { 'Needs attention' }
    $gradeColor = if ($totalScore -ge 85) { 'Green' } elseif ($totalScore -ge 65) { 'Cyan' } elseif ($totalScore -ge 40) { 'Yellow' } else { 'Red' }
    $result = [PSCustomObject]@{ Score = $totalScore; Grade = $grade; GradeColor = $gradeColor; DiskScore = $diskScore; TempScore = $tempScore; BrowserScore = $browserScore; OrphanScore = $orphanScore; DiskPct = $diskPct; TempMB = [math]::Round($tempMB); BrowserAge = $oldestCacheDays; OrphanInfo = $orphanInfo }
    $script:HealthCache = @{ Data = $result; Expires = $now.AddSeconds(30) }
    return $result
}

function Get-AppLogoLines {
    @(
        '██████╗  █████╗ ██╗  ██╗██╗   ██╗███╗   ██╗ █████╗ ██╗    ██╗ █████╗ '
        '██╔══██╗██╔══██╗██║ ██╔╝██║   ██║████╗  ██║██╔══██╗██║    ██║██╔══██╗'
        '██████╔╝███████║█████╔╝ ██║   ██║██╔██╗ ██║███████║██║ █╗ ██║███████║'
        '██╔══██╗██╔══██║██╔═██╗ ██║   ██║██║╚██╗██║██╔══██║██║███╗██║██╔══██║'
        '██████╔╝██║  ██║██║  ██╗╚██████╔╝██║ ╚████║██║  ██║╚███╔███╔╝██║  ██║'
        '╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝'
    )
}

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if($w -lt 60){return 60}else{return $w} } catch { return 100 }
}

function New-Checkpoint {
    param([string]$Description = 'Bakunawa cleanup checkpoint')
    try {
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -EA Stop
        return $true
    } catch {
        return $false
    }
}

function Get-DisplayText {
    param([string]$Text,[int]$MaxWidth)
    if(!$Text){return ''}
    if($Text.Length -le $MaxWidth){return $Text}
    if($MaxWidth -le 3){return $Text.Substring(0,[Math]::Max(0,$MaxWidth))}
    return $Text.Substring(0,$MaxWidth-3)+'...'
}

function Get-PathLabel {
    param([string]$Path)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved) { return $null }
    $leaf = Split-Path -Path $resolved -Leaf
    if ($leaf) { return $leaf }
    return $resolved
}

function Format-CompactList {
    param([string[]]$Items,[int]$MaxItems=3)
    $labels = @($Items | Where-Object { $_ } | ForEach-Object { Get-PathLabel $_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $labels) { return 'none' }
    $shown = @($labels | Select-Object -First $MaxItems)
    $extra = $labels.Count - $shown.Count
    if ($extra -gt 0) { return ('{0} (+{1} more)' -f ($shown -join ', '), $extra) }
    return $shown -join ', '
}

function New-AsciiBar {
    param([int]$Value,[int]$Total,[int]$Width=18)
    if ($Width -lt 1) { $Width = 1 }
    $safeValue = [Math]::Max(0, $Value)
    $safeTotal = [Math]::Max(0, $Total)
    if ($safeTotal -le 0) { return ('[{0}] 0%' -f ('.' * $Width)) }
    if ($safeValue -gt $safeTotal) { $safeValue = $safeTotal }
    $filled = [Math]::Min($Width, [int][Math]::Round(($safeValue / [double]$safeTotal) * $Width))
    $empty  = [Math]::Max(0, $Width - $filled)
    $pct    = [int][Math]::Round(($safeValue / [double]$safeTotal) * 100)
    return ('[{0}{1}] {2}%' -f ('#' * $filled), ('.' * $empty), $pct)
}

function Get-SystemLocations {
    $wr = Get-EnvPath 'SystemRoot'
    $pd = Get-EnvPath 'ProgramData'
    $sd = Get-EnvPath 'SystemDrive'
    return [PSCustomObject]@{
        WindowsRoot  = $wr
        ProgramData  = $pd
        SystemDrive  = $sd
        WindowsTemp  = $(if($wr){Join-Path $wr 'Temp'})
        WerArchive   = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportArchive'})
        WerQueue     = $(if($pd){Join-Path $pd 'Microsoft\Windows\WER\ReportQueue'})
        NetDownloader= $(if($pd){Join-Path $pd 'Microsoft\Network\Downloader'})
        SoftDistDL   = $(if($wr){Join-Path $wr 'SoftwareDistribution\Download'})
        Prefetch     = $(if($wr){Join-Path $wr 'Prefetch'})
        DeliveryOpt  = $(if($wr){Join-Path $wr 'SoftwareDistribution\DeliveryOptimization'})
        RecycleBin   = $(if($sd){Join-Path $sd '$Recycle.Bin'})
    }
}

Export-ModuleMember -Function * -Variable *
