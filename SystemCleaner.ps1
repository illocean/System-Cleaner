[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview')]
    [string]$Mode = 'Menu',
    [string[]]$ExtraExcludePath = @(),
    [switch]$NoPause,
    [switch]$SkipBootstrap,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'System Cleaner v2'

# ── Script-wide state ──
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
$script:UiStopwatch      = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastUiMs         = [long]0
$script:UiTickMs         = 250
$script:SpinnerFrames    = @('|','/','-','\')
$script:SpinnerIndex     = 0
$script:LogFilePath      = ''
$script:HealthCache      = $null   # { Score, Signals, Timestamp } for 30s cache
$script:LastOrphanRisks  = $null   # { Count, HighCount, MedCount, LowCount }

# ════════════════════════════════════════════════════════════════
#  C# COMPILED ACCELERATORS (FOR NATIVE SPEED)
# ════════════════════════════════════════════════════════════════
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
            } catch { /* Ignore locked/unauthorized folders without throwing slow PS errors! */ }
            return size;
        }
    }
"@ -ErrorAction SilentlyContinue
} catch {}

# ════════════════════════════════════════════════════════════════
#  UTILITY FUNCTIONS
# ════════════════════════════════════════════════════════════════

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$SelectedMode)
    $args_ = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($SelectedMode) { $args_ += '-Mode'; $args_ += $SelectedMode }
    if ($NoPause)      { $args_ += '-NoPause' }
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

function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $null }
}

function Get-EnvPath {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($s in 'Process','User','Machine') {
        $v = [Environment]::GetEnvironmentVariable($Name, $s)
        $r = Resolve-FullPath $v
        if ($r) { return $r }
    }
    $null
}

function Join-EnvPath {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ChildPath)
    $b = Get-EnvPath -Name $Name
    if (-not $b) { return $null }
    Resolve-FullPath (Join-Path $b $ChildPath)
}

function Get-FreeSpaceInfo {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        $sd = [Environment]::GetEnvironmentVariable('SystemDrive','Process')
        if (-not $sd) { $sd = 'C:' }
        $DriveLetter = $sd.TrimEnd(':')
    }
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'"
    if (-not $d) { return [pscustomobject]@{MB=0;GB=0} }
    [pscustomobject]@{
        MB = [math]::Round($d.FreeSpace / 1MB)
        GB = [math]::Round($d.FreeSpace / 1GB, 2)
    }
}

function Get-DirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [long]0 }
    
    if ([bool]('FastSys' -as [type])) {
        return [FastSys]::GetDirectorySize($Path)
    }

    # Slower PowerShell Fallback if class failed to compile
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -EA SilentlyContinue |
        Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
    if ($null -eq $sum) { [long]0 } else { [long]$sum }
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

# ── Excluded paths ──
function Get-ExcludedPaths {
    $set = New-TrackedSet
    foreach ($c in @(
        (Join-EnvPath 'USERPROFILE' 'Downloads'),
        (Join-EnvPath 'USERPROFILE' 'Documents'),
        (Join-EnvPath 'USERPROFILE' 'Desktop'),
        (Join-EnvPath 'USERPROFILE' 'Pictures'),
        (Join-EnvPath 'USERPROFILE' 'Videos'),
        (Join-EnvPath 'USERPROFILE' 'Music'),
        (Join-EnvPath 'OneDrive' 'Downloads'),
        # Store/UWP packages keep functional app state here; touching it can break apps like Photos.
        (Join-EnvPath 'LOCALAPPDATA' 'Packages')
    )) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    foreach ($c in $ExtraExcludePath) {
        $r = Resolve-FullPath $c
        if ($r) { [void]$set.Add($r) }
    }
    $set
}

function Test-IsExcludedPath {
    param([string]$Path)
    $r = Resolve-FullPath $Path
    if (-not $r) { return $false }
    foreach ($e in $script:ExcludedPaths) {
        if ($r.Equals($e,[StringComparison]::OrdinalIgnoreCase) -or
            $r.StartsWith("$e\",[StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

# ── Smart features ──

function Get-OrphanRiskScore {
    param(
        [string]$Name,
        [long]$SizeBytes,
        [int]$DaysStale,
        [string]$PathSuffix,
        [string[]]$InstalledNames = @(),
        [string[]]$RunningNames = @()
    )

    # Staleness 0–40
    $staleness = if ($DaysStale -ge 365) { 40 } elseif ($DaysStale -ge 90) { 30 } elseif ($DaysStale -ge 30) { 15 } else { 0 }

    # Size impact 0–20
    $sizeMB = $SizeBytes / 1MB
    $sizeScore = if ($sizeMB -ge 500) { 20 } elseif ($sizeMB -ge 200) { 15 } elseif ($sizeMB -ge 50) { 10 } elseif ($sizeMB -ge 1) { 5 } else { 0 }

    # Install signal -30–0
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

    # Path trust 0–10
    $pathScore = if ($PathSuffix -match 'ProgramData') { 5 } elseif ($PathSuffix -match 'Local') { 3 } else { 0 }

    $total = [Math]::Max(0, $staleness + $sizeScore + $installSignal + $pathScore)
    $level = if ($total -le 15) { 'Low' } elseif ($total -le 40) { 'Medium' } else { 'High' }
    $color = if ($total -le 15) { 'Green' } elseif ($total -le 40) { 'Yellow' } else { 'Red' }

    [pscustomobject]@{
        Score        = $total
        RiskLevel    = $level
        Color        = $color
        Staleness    = $staleness
        SizeScore    = $sizeScore
        InstallSig   = $installSignal
        PathTrust    = $pathScore
    }
}

function Get-HealthScore {
    $now = Get-Date
    if ($script:HealthCache -and ($now -lt $script:HealthCache.Expires)) {
        return $script:HealthCache.Data
    }

    # Signal 1: Disk pressure (30 pts)
    $free = Get-FreeSpaceInfo
    $diskPct = [math]::Round(($free.MB / [math]::Max(1, ($free.MB + 1))) * 100)
    $diskScore = if ($diskPct -ge 30) { 30 } elseif ($diskPct -ge 20) { 25 } elseif ($diskPct -ge 10) { 15 } elseif ($diskPct -ge 5) { 5 } else { 0 }

    # Signal 2: Temp accumulation (25 pts)
    $tempTotal = 0L
    foreach ($tp in @((Get-EnvPath 'TEMP'), (Join-EnvPath 'LOCALAPPDATA' 'Temp'))) {
        $tempTotal += Get-DirectorySize $tp
    }
    $tempMB = $tempTotal / 1MB
    $tempScore = if ($tempMB -lt 500) { 25 } elseif ($tempMB -lt 2000) { 18 } elseif ($tempMB -lt 5000) { 10 } elseif ($tempMB -lt 10000) { 5 } else { 0 }

    # Signal 3: Browser cache age (20 pts)
    $browserScore = 20
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

    # Signal 4: Orphan risk (25 pts) — from cached last run data
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

    $result = [pscustomobject]@{
        Score       = $totalScore
        Grade       = $grade
        GradeColor  = $gradeColor
        DiskScore   = $diskScore
        TempScore   = $tempScore
        BrowserScore = $browserScore
        OrphanScore = $orphanScore
        DiskPct     = $diskPct
        TempMB      = [math]::Round($tempMB)
        BrowserAge  = $oldestCacheDays
        OrphanInfo  = $orphanInfo
    }

    $script:HealthCache = @{ Data = $result; Expires = $now.AddSeconds(30) }
    $result
}

function Show-HealthDetail {
    $h = Get-HealthScore
    Clear-Host
    Write-Host ''
    Write-CenteredLine '═══════════════════ System Health Report ═══════════════════' $h.GradeColor
    Write-Host ''
    Write-Panel @(
        "Score : $($h.Score)/100 $($h.Grade)"
        ''
        "Disk Pressure   : $($h.DiskScore)/30  ($($h.DiskPct)% free)"
        "Temp/Cache      : $($h.TempScore)/25  ($($h.TempMB) MB)"
        "Browser Cache   : $($h.BrowserScore)/20 ($($h.BrowserAge)d oldest)"
        "Orphan Risk     : $($h.OrphanScore)/25 $(if($h.OrphanInfo){'('+$h.OrphanInfo.HighCount+' high, '+$h.OrphanInfo.MedCount+' medium)'}else{'(no orphan data yet)'})"
    ) -BorderColor $h.GradeColor -TextColor 'White' -MinWidth 60 -MaxWidth 88
    Write-Host ''
    Write-Log 'Next full evaluation in 30 seconds.' 'INFO'
    Write-Host ''
}

# ── System locations ──
function Get-SystemLocations {
    $wr = Get-EnvPath 'SystemRoot'
    $pd = Get-EnvPath 'ProgramData'
    $sd = Get-EnvPath 'SystemDrive'
    [pscustomobject]@{
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
    }
}

function Get-DefaultApprovedRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA'),
        (Get-EnvPath 'USERPROFILE'),
        $script:SysLoc.ProgramData,
        $script:SysLoc.WindowsRoot
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    @($set)
}

function Test-SafeCleanupTarget {
    param(
        [string]$Path,
        [string[]]$ApprovedRoots = @(),
        [switch]$AllowRoot
    )

    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or (Test-IsExcludedPath $resolved)) { return $false }

    $roots = @($ApprovedRoots | ForEach-Object { Resolve-FullPath $_ } | Where-Object { $_ })
    if (-not $roots) { $roots = Get-DefaultApprovedRoots }

    foreach ($root in $roots) {
        if ($resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            return $AllowRoot.IsPresent
        }

        if ($resolved.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $false
}

function Get-DisposableDirectoryNames {
    $names = New-TrackedSet
    @(
        'cache','caches','code cache','gpucache','media cache','dawncache',
        'shadercache','grshadercache','graphitedawncache','startupcache','cache2',
        'temp','tmp','logs','log','crashpad','crashdumps','blob_storage'
    ) | ForEach-Object { [void]$names.Add($_) }
    $names
}

function Test-IsDisposableLogPath {
    param([string]$Path, [string]$Root)

    $resolvedPath = Resolve-FullPath $Path
    $resolvedRoot = Resolve-FullPath $Root
    if (-not $resolvedPath -or -not $resolvedRoot) { return $false }
    if (-not $resolvedPath.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $relativeDirectory = Split-Path -Parent $resolvedPath
    if (-not $relativeDirectory.StartsWith("$resolvedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $segmentNames = (Split-Path -NoQualifier $relativeDirectory).TrimStart('\').Split('\', [StringSplitOptions]::RemoveEmptyEntries)
    $disposableNames = Get-DisposableDirectoryNames
    foreach ($segment in $segmentNames) {
        if ($disposableNames.Contains($segment)) { return $true }
    }

    $false
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
            foreach ($file in $directory.EnumerateFiles('*.log', [System.IO.SearchOption]::AllDirectories)) {
                $files.Add($file)
            }
        } catch {
            foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Filter '*.log' -File -Recurse -Force -EA SilentlyContinue)) {
                $files.Add($file)
            }
        }

        foreach ($file in $files) {
            if ($file.LastWriteTime -ge $cutoff) { continue }
            if (-not (Test-SafeCleanupTarget -Path $file.FullName -ApprovedRoots @($resolvedRoot) -AllowRoot)) { continue }
            if (-not (Test-IsDisposableLogPath -Path $file.FullName -Root $resolvedRoot)) { continue }
            $candidates.Add($file)
        }
    }

    $candidates
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

    $candidates
}

function Get-JunkSweepRoots {
    $set = New-TrackedSet
    foreach ($root in @(
        (Get-EnvPath 'TEMP'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp,
        $script:SysLoc.SoftDistDL,
        $script:SysLoc.DeliveryOpt
    )) {
        $resolved = Resolve-FullPath $root
        if ($resolved) { [void]$set.Add($resolved) }
    }
    @($set)
}

function Get-RunningProcessNames {
    $set = New-TrackedSet
    foreach ($name in (Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique)) {
        [void]$set.Add($name)
    }
    $set
}

function Test-AnyProcessRunning {
    param($RunningProcesses, [string[]]$Names)
    foreach ($name in $Names) {
        if ($RunningProcesses.Contains($name)) { return $true }
    }
    $false
}

function Register-SkippedItem {
    param([string]$Reason, [string]$Target)
    $script:SkippedItems += [pscustomobject]@{
        Reason = $Reason
        Target = $Target
    }
    Write-Log "Skipped ${Target}: $Reason" 'WARN'
}

# ════════════════════════════════════════════════════════════════
#  LOGGING & UI
# ════════════════════════════════════════════════════════════════

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    
    $prefix, $color = switch($Level) {
        'OK'   { ' [+] ', 'Green' }
        'WARN' { ' [!] ', 'Yellow' }
        'ERR'  { ' [X] ', 'Red' }
        'CMD'  { ' > ', 'DarkGray' }
        'STEP' { ' >> ', 'Cyan' }
        'SIZE' { ' vv ', 'Magenta' }
        default{ ' [i] ', 'Gray' }
    }
    
    Write-Host "[$ts]$prefix $Message" -ForegroundColor $color
    if ($script:LogFilePath) {
        $line = "[$ts][$Level] $Message"
        try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -EA SilentlyContinue } catch {}
    }
}

function Update-UiTicker {
    param([string]$CurrentOperation)
    if (-not $script:ActiveStepName) { return }
    if ($script:TotalSteps -le 0) { return }

    $nowMs = [long]$script:UiStopwatch.ElapsedMilliseconds
    if (($nowMs - $script:LastUiMs) -lt $script:UiTickMs) { return }
    $script:LastUiMs = $nowMs

    $frame = $script:SpinnerFrames[$script:SpinnerIndex % $script:SpinnerFrames.Count]
    $script:SpinnerIndex++

    $op = if ([string]::IsNullOrWhiteSpace($CurrentOperation)) { $script:ActiveStepName } else { $CurrentOperation }
    $bar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 10
    $status = "[${frame}] $bar $op"

    Write-Progress -Activity 'SystemCleaner tuning performance...' -Status $status -PercentComplete $script:ActiveStepPct -Id 1
    $Host.UI.RawUI.WindowTitle = "System Cleaner v2 $frame $($script:StepIndex)/$($script:TotalSteps) $($script:ActiveStepName)"
}

function Write-CommandLog {
    param([string]$Verb,[string]$Target)
    if ($Verb) { Update-UiTicker -CurrentOperation $Verb }
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Get-ConsoleWidth {
    try { $w = $Host.UI.RawUI.WindowSize.Width; if($w -lt 60){60}else{$w} } catch {100}
}

function Get-DisplayText { param([string]$Text,[int]$MaxWidth)
    if(!$Text){return ''}
    if($Text.Length -le $MaxWidth){return $Text}
    if($MaxWidth -le 3){return $Text.Substring(0,[Math]::Max(0,$MaxWidth))}
    $Text.Substring(0,$MaxWidth-3)+'...'
}

function Get-PathLabel {
    param([string]$Path)
    $resolved = Resolve-FullPath $Path
    if (-not $resolved) { return $null }
    $leaf = Split-Path -Path $resolved -Leaf
    if ($leaf) { return $leaf }
    $resolved
}

function Format-CompactList {
    param([string[]]$Items,[int]$MaxItems=3)
    $labels = @(
        $Items |
        Where-Object { $_ } |
        ForEach-Object { Get-PathLabel $_ } |
        Where-Object { $_ } |
        Select-Object -Unique
    )
    if (-not $labels) { return 'none' }
    $shown = @($labels | Select-Object -First $MaxItems)
    $extra = $labels.Count - $shown.Count
    if ($extra -gt 0) { return ('{0} (+{1} more)' -f ($shown -join ', '), $extra) }
    $shown -join ', '
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

    ('[{0}{1}] {2}%' -f ('#' * $filled), ('.' * $empty), $pct)
}

function Get-AppLogoLines {
    @(
        ' .------------------------------------------------------------. '
        ' |   _____           __                                       | '
        ' |  / ___/__ _____  / /____ ___  ___ ______                   | '
        ' | / /__/ _ `/ __/ / __/ -_) _ \/ -_) __/                     | '
        ' | \___/\_,_/_/    \__/\__/_//_/\__/_/  SYSTEM CLEANER        | '
        ' `------------------------------------------------------------` '
    )
}

function Get-ModeColor {
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-CenteredLine { param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-SectionHeader {
    param([string]$Title,[string]$ForegroundColor='Cyan')
    $cw = Get-ConsoleWidth
    $prefix = "-- $Title "
    $line = $prefix + ('-' * [Math]::Max(0, $cw - $prefix.Length))
    Write-Host (Get-DisplayText $line $cw) -ForegroundColor $ForegroundColor
}

function Write-Panel {
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth; $aw = [Math]::Max(20,$cw-4); $mxl=0
    foreach($l in $Lines){if($l.Length -gt $mxl){$mxl=$l.Length}}
    $pw = [Math]::Min($aw,[Math]::Max($MinWidth,$mxl+4))
    $pw = [Math]::Min($pw,$MaxWidth); $pw = [Math]::Min($pw,$cw)
    $iw = [Math]::Max(1,$pw-4); $pad = [Math]::Max(0,[int](($cw-$pw)/2))
    $lp = ' '*$pad; $bdr = '+'+('-'*($pw-2))+'+'
    Write-Host ($lp+$bdr) -ForegroundColor $BorderColor
    foreach($l in $Lines){
        $rl = (Get-DisplayText $l $iw).PadRight($iw)
        Write-Host ($lp+'| '+$rl+' |') -ForegroundColor $TextColor
    }
    Write-Host ($lp+$bdr) -ForegroundColor $BorderColor
}

function Show-AppLogo {
    $logo = Get-AppLogoLines
    $colors = @('DarkCyan','Cyan','Cyan','White','Cyan','DarkCyan')
    for ($index = 0; $index -lt $logo.Count; $index++) {
        $color = $colors[[Math]::Min($index, $colors.Count - 1)]
        Write-CenteredLine $logo[$index] $color
    }
    Write-CenteredLine 'fixed-width ASCII banner | PowerShell-safe | no module' 'DarkGray'
}

function Show-Header {
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    $modeColor = Get-ModeColor $script:CurrentModeName
    $free = Get-FreeSpaceInfo
    $ml = if($script:CurrentModeName -eq 'Menu'){'INTERACTIVE'}else{$script:CurrentModeName.ToUpperInvariant()}
    $lr = if($script:LastRunSummary){"$($script:LastRunSummary.Mode) | $($script:LastRunSummary.DurationSeconds)s | $(Format-FileSize $script:LastRunSummary.TotalFreed)"}else{'none yet'}
    $protected = Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3
    $runBar = if($script:CurrentModeName -eq 'Menu'){'[..................] idle'}else{New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 18}
    $healthLine = 'Health     : not available'
    try {
        $h = Get-HealthScore
        $barChar = [char]0x2588
        $filled = [math]::Floor($h.Score / 10)
        $hb = "$($barChar.ToString() * $filled)$('.' * (10 - $filled))"
        $healthLine = "Health     : $hb $($h.Score)/100 $($h.Grade)"
    } catch { $healthLine = 'Health     : unavailable' }
    Write-Panel @(
        "Mode       : $ml"
        "Free       : $($free.MB) MB ($($free.GB) GB)"
        "Protected  : $protected"
        $healthLine
        "Last run   : $lr"
        "Run bar    : $runBar"
    ) -BorderColor $modeColor -TextColor 'White' -MinWidth 62 -MaxWidth 92
    Write-Host ''
}

# ════════════════════════════════════════════════════════════════
#  MENU
# ════════════════════════════════════════════════════════════════

function Show-Menu {
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        Write-Panel @(
            'MAIN MENU'
            ''
            '[1] Standard    temp, browsers, apps, dev caches, orphans'
            '[2] Aggressive  standard + DISM + event logs + prefetch'
            '[3] Preview     show the cleanup plan only'
            '[4] Orphans     scan leftovers and review deletions'
            '[5] Health      system health dashboard with details'
            ''
            'Busy browsers and selected apps are skipped for safety.'
            '[Q] Quit'
        ) -BorderColor 'Cyan' -TextColor 'White' -MinWidth 64 -MaxWidth 88
        Write-Host ''
        Write-CenteredLine 'Choose a mode and press Enter.' 'DarkGray'
        Write-Host ''
        $choice = (Read-Host 'Selection').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { Invoke-CleanupRun 'Standard';   Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '2' { Invoke-CleanupRun 'Aggressive'; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '3' { Invoke-CleanupRun 'Preview';    Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '4' { Show-Header; $script:IsPreview=$false; Start-Step 'Orphan folder scan'; $o=Find-OrphanFolders -InteractiveDelete; Finish-Step "Orphan check complete"; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '5' { Show-HealthDetail; [void](Read-Host '[Press Enter to return to Menu]') }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}


function Start-Step { param([string]$Name)
    $script:StepIndex++
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    $stepBar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 12
    Write-Log "$stepTag $stepBar $Name" 'STEP'
    
    # Progress bar and UI
    if ($script:TotalSteps -gt 0) {
        $pct = [Math]::Max(1,[int](($script:StepIndex / $script:TotalSteps) * 100))
        $script:ActiveStepName = $Name
        $script:ActiveStepPct  = $pct
        $script:LastUiMs       = -999999
        Update-UiTicker
    }
}

function Finish-Step { param([string]$Summary)
    Write-Log $Summary 'OK'
    $script:ActiveStepName = $null
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'SystemCleaner runs deep sweep' -Completed -Id 1
        $Host.UI.RawUI.WindowTitle = 'System Cleaner v2 - Sweep Complete'
    }
}

# ════════════════════════════════════════════════════════════════
#  CORE CLEANING ENGINE
# ════════════════════════════════════════════════════════════════

function Measure-AndClear {
    param([string]$Path,[switch]$EnsureDirectory,[string]$Category='General')
    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Container)) { return $false }
    if (-not (Test-SafeCleanupTarget -Path $resolved)) { return $false }

    $sizeBefore = Get-DirectorySize $resolved
    $verb = if($script:IsPreview){'PREVIEW'}else{'CLEAR'}
    Write-CommandLog $verb $resolved

    if (-not $script:IsPreview) {
        Get-ChildItem -LiteralPath $resolved -Force -EA SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA SilentlyContinue
        }
        if ($EnsureDirectory -and -not (Test-Path -LiteralPath $resolved)) {
            New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        }
        $sizeAfter = Get-DirectorySize $resolved
        $freed = [Math]::Max(0, $sizeBefore - $sizeAfter)
    } else {
        $freed = $sizeBefore
    }

    $script:BytesFreed += $freed
    if (-not $script:CategorySizes.ContainsKey($Category)) { $script:CategorySizes[$Category] = [long]0 }
    $script:CategorySizes[$Category] += $freed
    return $true
}

function Remove-FilesByPattern {
    param([string]$Directory,[string[]]$Patterns,[string]$Category='General')
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return 0 }
    
    $count = 0
    foreach ($pat in $Patterns) {
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        try {
            # Bypass pipeline memory costs using .NET Framework EnumerateFiles natively
            $di = [System.IO.DirectoryInfo]::new($Directory)
            foreach ($f in $di.EnumerateFiles($pat, [System.IO.SearchOption]::AllDirectories)) {
                $files.Add($f)
            }
        } catch {
            # Fallback if unhandled Access Denied hits halfway
            $files = Get-ChildItem -LiteralPath $Directory -Filter $pat -File -Force -Recurse -EA SilentlyContinue
        }

        foreach ($f in $files) {
            $full = $f.FullName
            if (Test-IsExcludedPath $full) { continue }
            $sz = $f.Length
            $verb = if($script:IsPreview){'PREVIEW rm'}else{'REMOVE'}
            Write-CommandLog $verb $full
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

# ════════════════════════════════════════════════════════════════
#  STEP 1: SYSTEM CACHES
# ════════════════════════════════════════════════════════════════

function Clear-SystemCaches {
    $cat = 'System Caches'
    $n = 0
    foreach ($t in @(
        (Get-EnvPath 'TEMP'),
        (Join-EnvPath 'LOCALAPPDATA' 'Temp'),
        $script:SysLoc.WindowsTemp,
        (Join-EnvPath 'LOCALAPPDATA' 'CrashDumps'),
        $script:SysLoc.WerArchive,
        $script:SysLoc.WerQueue,
        $script:SysLoc.NetDownloader
    )) {
        if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ }
    }

    # Stop update services, clean, restart
    $restart = @()
    try {
        foreach ($svc in 'wuauserv','bits','dosvc') {
            $s = Get-Service $svc -EA SilentlyContinue
            if ($s -and $s.Status -ne 'Stopped') {
                Write-CommandLog ($(if($script:IsPreview){'PREVIEW stop'}else{'STOP'})) $svc
                if (-not $script:IsPreview) {
                    Stop-Service $svc -Force -EA SilentlyContinue
                    $restart += $svc
                }
            }
        }

        if ($script:SysLoc.SoftDistDL -and (Measure-AndClear $script:SysLoc.SoftDistDL -EnsureDirectory -Category $cat)) { $n++ }
        if ($script:SysLoc.DeliveryOpt -and (Measure-AndClear $script:SysLoc.DeliveryOpt -EnsureDirectory -Category $cat)) { $n++ }
    }
    finally {
        foreach ($svc in $restart) {
            Write-CommandLog 'START' $svc
            Start-Service $svc -EA SilentlyContinue
        }
    }
    $n
}

# ════════════════════════════════════════════════════════════════
#  STEP 2: BROWSER CACHES
# ════════════════════════════════════════════════════════════════

function Clear-ChromiumCaches {
    param([string]$UserDataRoot,[string]$Label)
    $cat = 'Browser Caches'
    $n = 0
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) { return 0 }
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }
    $processNames = switch ($Label) {
        'Chrome' { @('chrome') }
        'Edge'   { @('msedge') }
        'Brave'  { @('brave') }
        'Opera'  { @('opera') }
        'Vivaldi'{ @('vivaldi') }
        default  { @() }
    }
    if ($processNames.Count -gt 0 -and (Test-AnyProcessRunning -RunningProcesses $running -Names $processNames)) {
        Register-SkippedItem -Reason 'close the browser for a deeper cache cleanup' -Target $Label
        return 0
    }
    $cacheDirs = @('Cache','Code Cache','GPUCache','Media Cache','DawnCache',
        'ShaderCache','GrShaderCache','GraphiteDawnCache','DawnWebGPUCache','Local Storage')
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
        if ($hit) { Write-Log "Cleaned $Label profile: $($prof.Name)"; $n++ }
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
        if ($hit) { Write-Log "Cleaned Firefox profile: $($p.Name)"; $n++ }
    }
    $n
}

# ════════════════════════════════════════════════════════════════
#  STEP 3: APP CACHES (tailored to YOUR system)
# ════════════════════════════════════════════════════════════════

function Clear-AppCaches {
    $cat = 'App Caches'; $n = 0
    $running = if ($script:RunningProcesses) { $script:RunningProcesses } else { Get-RunningProcessNames }

    # Discord variants
    foreach ($dn in 'discord','discordcanary','discordptb') {
        $root = Join-EnvPath 'APPDATA' $dn
        if ($root -and (Test-Path -LiteralPath $root) -and (Test-AnyProcessRunning -RunningProcesses $running -Names @('discord'))) {
            Register-SkippedItem -Reason 'close Discord before clearing live cache folders' -Target $dn
            continue
        }
        $hit = $false
        foreach ($d in 'Cache','Code Cache','GPUCache','blob_storage') {
            $t = Join-Path $root $d
            if (Test-Path -LiteralPath $t) { [void](Measure-AndClear $t -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { Write-Log "Cleaned: $dn"; $n++ }
    }

    # VS Code
    foreach ($cr in @((Join-EnvPath 'APPDATA' 'Code'),(Join-EnvPath 'APPDATA' 'Code - Insiders'))) {
        if (-not $cr) { continue }
        if ((Test-Path -LiteralPath $cr) -and (Test-AnyProcessRunning -RunningProcesses $running -Names @('Code','Code - Insiders'))) {
            Register-SkippedItem -Reason 'close VS Code before clearing its runtime caches' -Target ([IO.Path]::GetFileName($cr))
            continue
        }
        $hit=$false
        foreach ($d in 'Cache','CachedData','CachedExtensions','CachedExtensionVSIXs',
                       'Code Cache','GPUCache','Service Worker\CacheStorage','logs') {
            $t = Join-Path $cr $d
            if (Test-Path -LiteralPath $t) { [void](Measure-AndClear $t -EnsureDirectory -Category $cat); $hit=$true }
        }
        if ($hit) { Write-Log "Cleaned: $([IO.Path]::GetFileName($cr))"; $n++ }
    }

    # Spotify
    foreach ($st in @(
        (Join-EnvPath 'APPDATA' 'Spotify\Cache'),
        (Join-EnvPath 'APPDATA' 'Spotify\Storage'),
        (Join-EnvPath 'LOCALAPPDATA' 'Spotify\Storage'),
        (Join-EnvPath 'LOCALAPPDATA' 'Spotify\Data')
    )) {
        if ($st -and (Test-Path -LiteralPath $st) -and (Test-AnyProcessRunning -RunningProcesses $running -Names @('Spotify'))) {
            Register-SkippedItem -Reason 'close Spotify before clearing storage and cache folders' -Target 'Spotify'
            break
        }
        if ($st -and (Measure-AndClear $st -EnsureDirectory -Category $cat)) { Write-Log "Cleaned Spotify: $st"; $n++ }
    }

    # Telegram Desktop
    $tg = Join-EnvPath 'APPDATA' 'Telegram Desktop\tdata'
    if (Test-Path -LiteralPath $tg -PathType Container) {
        $hit=$false
        Get-ChildItem $tg -Directory -Recurse -Force -EA SilentlyContinue |
            Where-Object { $_.Name -ieq 'cache' } | ForEach-Object {
                [void](Measure-AndClear $_.FullName -EnsureDirectory -Category $cat); $hit=$true
            }
        if ($hit) { Write-Log 'Cleaned: Telegram Desktop'; $n++ }
    }

    # Stremio
    $sr = Join-EnvPath 'APPDATA' 'Stremio'
    if (Test-Path -LiteralPath $sr -PathType Container) {
        $hit=$false
        Get-ChildItem $sr -Directory -Recurse -Force -EA SilentlyContinue |
            Where-Object { @('cache','temp','logs') -contains $_.Name.ToLower() } | ForEach-Object {
                [void](Measure-AndClear $_.FullName -EnsureDirectory -Category $cat); $hit=$true
            }
        if ($hit) { Write-Log 'Cleaned: Stremio'; $n++ }
    }

    # Zoom
    foreach ($zp in @(
        (Join-EnvPath 'APPDATA' 'Zoom\data'),
        (Join-EnvPath 'APPDATA' 'Zoom\logs'),
        (Join-EnvPath 'LOCALAPPDATA' 'Zoom\logs')
    )) {
        if ($zp -and (Measure-AndClear $zp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned Zoom: $zp"; $n++ }
    }

    # Viber
    foreach ($vp in @(
        (Join-EnvPath 'APPDATA' 'ViberPC\cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Viber\cache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Viber Media S.`a r.l\cache')
    )) {
        if ($vp -and (Test-Path $vp) -and (Measure-AndClear $vp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned Viber cache"; $n++ }
    }

    # OBS Studio
    $obs = Join-EnvPath 'APPDATA' 'obs-studio\logs'
    if ($obs -and (Measure-AndClear $obs -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: OBS logs'; $n++ }
    $obsCrash = Join-EnvPath 'APPDATA' 'obs-studio\crashes'
    if ($obsCrash -and (Measure-AndClear $obsCrash -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: OBS crashes'; $n++ }

    # qBittorrent logs
    $qbt = Join-EnvPath 'LOCALAPPDATA' 'qBittorrent\logs'
    if ($qbt -and (Measure-AndClear $qbt -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: qBittorrent logs'; $n++ }

    # TeamViewer logs
    $tv = Join-EnvPath 'APPDATA' 'TeamViewer'
    if (Test-Path -LiteralPath $tv) {
        $c = Remove-FilesByPattern $tv @('*.log','*.log.*') -Category $cat
        if ($c -gt 0) { Write-Log "Cleaned $c TeamViewer log files"; $n++ }
    }

    # JetBrains (all IDEs)
    $jb = Join-EnvPath 'LOCALAPPDATA' 'JetBrains'
    if (Test-Path -LiteralPath $jb) {
        $hit=$false
        Get-ChildItem $jb -Directory -Force -EA SilentlyContinue | ForEach-Object {
            foreach ($sub in 'log','tmp','caches') {
                $t = Join-Path $_.FullName $sub
                if (Test-Path $t) { [void](Measure-AndClear $t -EnsureDirectory -Category $cat); $hit=$true }
            }
        }
        if ($hit) { Write-Log 'Cleaned: JetBrains caches/logs'; $n++ }
    }

    # Obsidian
    $obsApp = Join-EnvPath 'APPDATA' 'obsidian\Cache'
    if ($obsApp -and (Measure-AndClear $obsApp -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Obsidian cache'; $n++ }
    $obsGpu = Join-EnvPath 'APPDATA' 'obsidian\GPUCache'
    if ($obsGpu -and (Measure-AndClear $obsGpu -EnsureDirectory -Category $cat)) { $n++ }

    # ShareX logs
    $sx = Join-EnvPath 'USERPROFILE' 'Documents\ShareX\Logs'
    if ($sx -and (Measure-AndClear $sx -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: ShareX logs'; $n++ }

    # Roblox
    $rblx = Join-EnvPath 'LOCALAPPDATA' 'Roblox\logs'
    if ($rblx -and (Measure-AndClear $rblx -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Roblox logs'; $n++ }

    # Draw.io
    $dio = Join-EnvPath 'APPDATA' 'draw.io\Cache'
    if ($dio -and (Measure-AndClear $dio -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: draw.io cache'; $n++ }

    # Slack
    foreach ($sp in @(
        (Join-EnvPath 'APPDATA' 'Slack\Cache'),
        (Join-EnvPath 'APPDATA' 'Slack\Service Worker\CacheStorage'),
        (Join-EnvPath 'APPDATA' 'Slack\Code Cache'),
        (Join-EnvPath 'APPDATA' 'Slack\GPUCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Slack\logs')
    )) {
        if ($sp -and (Measure-AndClear $sp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned Slack: $sp"; $n++ }
    }

    # Microsoft Teams
    foreach ($tp in @(
        (Join-EnvPath 'APPDATA' 'Microsoft\Teams\Cache'),
        (Join-EnvPath 'APPDATA' 'Microsoft\Teams\Code Cache'),
        (Join-EnvPath 'APPDATA' 'Microsoft\Teams\GPUCache'),
        (Join-EnvPath 'APPDATA' 'Microsoft\Teams\logs'),
        (Join-EnvPath 'APPDATA' 'Microsoft\Teams\blob_storage'),
        (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Teams\old_weblogs')
    )) {
        if ($tp -and (Measure-AndClear $tp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned Teams: $tp"; $n++ }
    }

    # WhatsApp Desktop
    foreach ($wp in @(
        (Join-EnvPath 'APPDATA' 'WhatsApp\Cache'),
        (Join-EnvPath 'APPDATA' 'WhatsApp\Code Cache'),
        (Join-EnvPath 'APPDATA' 'WhatsApp\GPUCache'),
        (Join-EnvPath 'APPDATA' 'WhatsApp\Service Worker\CacheStorage')
    )) {
        if ($wp -and (Measure-AndClear $wp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned WhatsApp"; $n++ }
    }

    # Windows Terminal
    $wt = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows Terminal\Cache'
    if ($wt -and (Measure-AndClear $wt -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Windows Terminal cache'; $n++ }

    # Notion
    foreach ($np in @(
        (Join-EnvPath 'APPDATA' 'Notion\Cache'),
        (Join-EnvPath 'APPDATA' 'Notion\Code Cache'),
        (Join-EnvPath 'APPDATA' 'Notion\GPUCache'),
        (Join-EnvPath 'APPDATA' 'Notion\blob_storage')
    )) {
        if ($np -and (Measure-AndClear $np -EnsureDirectory -Category $cat)) { Write-Log "Cleaned: Notion"; $n++ }
    }

    # Figma
    $fg = Join-EnvPath 'APPDATA' 'Figma\Cache'
    if ($fg -and (Measure-AndClear $fg -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Figma cache'; $n++ }

    $n
}

# ════════════════════════════════════════════════════════════════
#  STEP 4: DEVELOPER TOOL CACHES
# ════════════════════════════════════════════════════════════════

function Clear-DevCaches {
    $cat = 'Dev Tool Caches'; $n = 0

    # npm cache
    $npm = Join-EnvPath 'LOCALAPPDATA' 'npm-cache'
    if ($npm -and (Measure-AndClear $npm -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: npm cache'; $n++ }

    # pnpm cache
    $pnpm = Join-EnvPath 'LOCALAPPDATA' 'pnpm-cache'
    if ($pnpm -and (Measure-AndClear $pnpm -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: pnpm cache'; $n++ }

    # pip cache
    $pip = Join-EnvPath 'LOCALAPPDATA' 'pip\cache'
    if ($pip -and (Measure-AndClear $pip -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: pip cache'; $n++ }

    # uv cache
    $uv = Join-EnvPath 'LOCALAPPDATA' 'uv\cache'
    if ($uv -and (Measure-AndClear $uv -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: uv cache'; $n++ }

    # NuGet caches
    foreach ($ng in @('v3-cache','plugins-cache','http-cache')) {
        $t = Join-EnvPath 'LOCALAPPDATA' "NuGet\$ng"
        if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { Write-Log "Cleaned: NuGet $ng"; $n++ }
    }

    # Composer cache
    $comp = Join-EnvPath 'LOCALAPPDATA' 'Composer\cache'
    if (-not $comp) { $comp = Join-EnvPath 'APPDATA' 'Composer\cache' }
    if ($comp -and (Measure-AndClear $comp -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Composer cache'; $n++ }

    # Prisma engines
    $prisma = Join-EnvPath 'LOCALAPPDATA' 'prisma-nodejs'
    if ($prisma -and (Measure-AndClear $prisma -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Prisma engines'; $n++ }

    # Playwright browsers (can be huge)
    $pw = Join-EnvPath 'LOCALAPPDATA' 'ms-playwright'
    if ($pw -and (Test-Path $pw)) {
        $pwSize = Get-DirectorySize $pw
        if ($pwSize -gt 0) {
            Write-Log "Playwright browsers: $(Format-FileSize $pwSize) - SKIPPED (run 'npx playwright install' to reinstall)" 'WARN'
        }
    }

    # .dotnet tools temp
    $dnTemp = Join-EnvPath 'USERPROFILE' '.dotnet\TelemetryFallbackDir'
    if ($dnTemp -and (Measure-AndClear $dnTemp -EnsureDirectory -Category $cat)) { $n++ }

    # Node modules - checkpoint
    $chk = Join-EnvPath 'LOCALAPPDATA' 'checkpoint-nodejs'
    if ($chk -and (Measure-AndClear $chk -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: checkpoint-nodejs'; $n++ }

    # Firebase heartbeat
    $fb = Join-EnvPath 'LOCALAPPDATA' 'firebase-heartbeat'
    if ($fb -and (Measure-AndClear $fb -EnsureDirectory -Category $cat)) { $n++ }

    # Yarn cache (v1 berry)
    $yarn = Join-EnvPath 'LOCALAPPDATA' 'Yarn\Cache'
    if (-not $yarn) { $yarn = Join-EnvPath 'APPDATA' 'Yarn\Cache' }
    if ($yarn -and (Measure-AndClear $yarn -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Yarn cache'; $n++ }
    $yarn2 = Join-EnvPath 'LOCALAPPDATA' 'Yarn\Berry\cache'
    if ($yarn2 -and (Measure-AndClear $yarn2 -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Yarn Berry cache'; $n++ }

    # Go module cache
    $go = Join-EnvPath 'USERPROFILE' 'go\pkg\mod'
    if ($go -and (Test-Path $go)) {
        $goSize = Get-DirectorySize $go
        if ($goSize -gt 0) {
            Write-Log "Go module cache: $(Format-FileSize $goSize) - SKIPPED (run 'go clean -modcache' to remove safely)" 'WARN'
        }
    }

    # Rust/Cargo cache
    foreach ($cp in @(
        (Join-EnvPath 'USERPROFILE' '.cargo\registry\cache'),
        (Join-EnvPath 'USERPROFILE' '.cargo\git\db')
    )) {
        if ($cp -and (Measure-AndClear $cp -EnsureDirectory -Category $cat)) { Write-Log "Cleaned: Cargo $([IO.Path]::GetFileName($cp))"; $n++ }
    }

    # Bun cache
    $bun = Join-EnvPath 'USERPROFILE' '.bun\install\cache'
    if ($bun -and (Measure-AndClear $bun -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Bun cache'; $n++ }

    # Flutter/Dart pub cache
    $pub = Join-EnvPath 'LOCALAPPDATA' 'Pub\Cache'
    if ($pub -and (Measure-AndClear $pub -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Dart pub cache'; $n++ }

    # Docker (Windows Docker Desktop)
    $dk = Join-EnvPath 'APPDATA' 'Docker\tmp'
    if ($dk -and (Measure-AndClear $dk -EnsureDirectory -Category $cat)) { Write-Log 'Cleaned: Docker tmp'; $n++ }

    $n
}

# ════════════════════════════════════════════════════════════════
#  STEP 5: GPU & SHELL CACHES
# ════════════════════════════════════════════════════════════════

function Clear-GpuAndShellCaches {
    $cat = 'GPU/Shell Caches'; $n = 0
    foreach ($t in @(
        (Join-EnvPath 'LOCALAPPDATA' 'D3DSCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\DXCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'NVIDIA\GLCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'AMD\DxCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'Intel\ShaderCache'),
        (Join-EnvPath 'LOCALAPPDATA' 'CEF\Cache')
    )) {
        if ($t -and (Measure-AndClear $t -EnsureDirectory -Category $cat)) { $n++ }
    }

    # Thumbnail & icon caches
    $exRoot = Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $exRoot) {
        $files = Get-ChildItem $exRoot -File -Force -EA SilentlyContinue |
            Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }
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
                    if (-not $script:IsPreview) {
                        Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue
                        $script:BytesFreed += $sz
                    }
                    if(-not $script:CategorySizes.ContainsKey($cat)){$script:CategorySizes[$cat]=[long]0}
                    $script:CategorySizes[$cat] += $sz
                }
            }
            finally {
                if (-not $script:IsPreview -and $wasRunning) { Write-CommandLog 'START' 'explorer.exe'; Start-Process explorer.exe }
            }
            $n++
        }
    }
    $n
}

# ════════════════════════════════════════════════════════════════
#  STEP 6: RECYCLE BIN
# ════════════════════════════════════════════════════════════════

function Clear-RecycleBinSafe {
    Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Recycle Bin'
    if (-not $script:IsPreview) { Clear-RecycleBin -Force -EA SilentlyContinue }
    $true
}

# ════════════════════════════════════════════════════════════════
#  STEP 7: EMPTY & STALE FOLDER CLEANUP
# ════════════════════════════════════════════════════════════════

function Remove-EmptyDirectories {
    param([string[]]$Roots)
    $removed = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        
        # Bottom-up enumeration required to safely cascade-delete empty trees
        Get-ChildItem $root -Directory -Recurse -Force -EA SilentlyContinue |
            Sort-Object FullName -Descending | ForEach-Object {
                if (Test-IsExcludedPath $_.FullName) { return }
                $has = Get-ChildItem -LiteralPath $_.FullName -Force -EA SilentlyContinue | Select-Object -First 1
                if (-not $has) {
                    Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-empty'}else{'RM-EMPTY'})) $_.FullName
                    if (-not $script:IsPreview) { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue }
                    $removed++
                }
            }
    }
    $removed
}

function Remove-StaleJunkFolders {
    param([string[]]$Roots,[int]$OlderThanDays=45)
    $removed = 0

    foreach ($directory in (Get-StaleDisposableDirectories -Roots $Roots -OlderThanDays $OlderThanDays | Sort-Object FullName -Descending)) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW rm-stale'}else{'RM-STALE'})) $directory.FullName
        if (-not $script:IsPreview) { Remove-Item -LiteralPath $directory.FullName -Recurse -Force -EA SilentlyContinue }
        $removed++
    }
    $removed
}

# ════════════════════════════════════════════════════════════════
#  STEP 8: ORPHAN FOLDER DETECTION
# ════════════════════════════════════════════════════════════════

function Find-OrphanFolders {
    param([switch]$InteractiveDelete)
    $cat = 'Orphan Cleanup'; $found = 0
    $script:OrphanReport = @()

    # Build set of installed program names from registry
    $installedNames = New-TrackedSet
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rp in $regPaths) {
        Get-ItemProperty $rp -EA SilentlyContinue | ForEach-Object {
            if ($_.DisplayName) { [void]$installedNames.Add($_.DisplayName.Trim()) }
            if ($_.InstallLocation) {
                $leaf = [IO.Path]::GetFileName($_.InstallLocation.TrimEnd('\'))
                if ($leaf) { [void]$installedNames.Add($leaf) }
            }
        }
    }

    # Also check running processes
    $running = Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty Name -Unique
    foreach ($r in $running) { [void]$installedNames.Add($r) }

    # Known safe folders to never flag
    $safeNames = New-TrackedSet
    @('Microsoft','Google','Mozilla','Windows','Common Files','Reference Assemblies',
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

    # Scan LocalAppData and AppData\Roaming for orphans
    foreach ($baseEnv in @('LOCALAPPDATA','APPDATA')) {
        $base = Get-EnvPath $baseEnv
        if (-not $base -or -not (Test-Path $base)) { continue }
        Get-ChildItem $base -Directory -Force -EA SilentlyContinue | ForEach-Object {
            $name = $_.Name
            if ($safeNames.Contains($name)) { return }
            if ($installedNames.Contains($name)) { return }

            # Check if folder hasn't been touched in 30+ days
            $lastWrite = $_.LastWriteTime
            $daysSince = ((Get-Date) - $lastWrite).TotalDays
            if ($daysSince -lt 30) { return }

            $dirSize = Get-DirectorySize $_.FullName
            $baseEnvLabel = if ($baseEnv -eq 'LOCALAPPDATA') { 'Local' } else { 'Roaming' }
            $risk = Get-OrphanRiskScore -Name $name -SizeBytes $dirSize -DaysStale $daysSince -PathSuffix $baseEnvLabel -InstalledNames @($installedNames) -RunningNames $running
            $entry = [pscustomobject]@{
                Path      = $_.FullName
                Name      = $name
                Size      = $dirSize
                SizeText  = Format-FileSize $dirSize
                DaysStale = [int]$daysSince
                RiskScore = $risk.Score
                RiskLevel = $risk.RiskLevel
                RiskColor = $risk.Color
            }
            $script:OrphanReport += $entry
            $badge = "[$($risk.RiskLevel.ToUpper().Substring(0,4))]"
            Write-Log "ORPHAN? $badge $name ($(Format-FileSize $dirSize), $([int]$daysSince)d stale) -> $($_.FullName)" 'WARN'
            $found++
        }
    }

    # Cache risk summary for health dashboard
    $highC = 0; $medC = 0; $lowC = 0
    foreach ($e in $script:OrphanReport) { if ($e.RiskLevel -eq 'High') { $highC++ } elseif ($e.RiskLevel -eq 'Medium') { $medC++ } else { $lowC++ } }
    $script:LastOrphanRisks = [pscustomobject]@{ Count = $found; HighCount = $highC; MedCount = $medC; LowCount = $lowC }

    # Sort by risk descending
    $script:OrphanReport = $script:OrphanReport | Sort-Object RiskScore -Descending

    if ($found -eq 0) {
        Write-Log 'No obvious orphan folders detected.' 'OK'
    } else {
        Write-Host ''
        Write-Log "$found potential orphan folder(s) found. ($highC high, $medC medium, $lowC low risk)" 'WARN'
        Write-Log 'These folders belong to apps that appear uninstalled and untouched 30+ days.' 'INFO'

        if ($InteractiveDelete -and -not $script:IsPreview) {
            Write-Host ''
            $deleteAll = $false
            $deletedCount = 0
            foreach ($o in $script:OrphanReport) {
                $badge = "[$($o.RiskLevel.ToUpper().Substring(0,4))]"
                if (-not $deleteAll) {
                    $ans = (Read-Host "Delete $badge '$($o.Name)' at $($o.Path)? (y/n/a/q) [n]").Trim().ToLowerInvariant()
                    if ($ans -eq 'q') { break }
                    if ($ans -eq 'a') { $deleteAll = $true }
                    if ($ans -ne 'y' -and $ans -ne 'a') { continue }
                }
                Write-CommandLog 'REMOVE' $o.Path
                Remove-Item -LiteralPath $o.Path -Recurse -Force -EA SilentlyContinue
                $deletedCount++
                $script:BytesFreed += $o.Size
                if (-not $script:CategorySizes.ContainsKey($cat)) { $script:CategorySizes[$cat] = [long]0 }
                $script:CategorySizes[$cat] += $o.Size
            }
            if ($deletedCount -gt 0) {
                Write-Log "Deleted $deletedCount orphan folder(s)." 'OK'
            } else {
                Write-Log 'No orphans deleted.' 'INFO'
            }
        }
    }
    $found
}

# ════════════════════════════════════════════════════════════════
#  STEP 9 (AGGRESSIVE): EXTRAS
# ════════════════════════════════════════════════════════════════

function Invoke-ComponentCleanup {
    Write-CommandLog 'RUN' 'Dism.exe /online /Cleanup-Image /StartComponentCleanup'
    if ($script:IsPreview) { return $true }
    & Dism.exe /online /Cleanup-Image /StartComponentCleanup
    $LASTEXITCODE -eq 0
}

function Clear-EventLogs {
    $cleared = 0
    $logs = & wevtutil.exe el
    foreach ($l in $logs) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW cl'}else{'CLEAR-LOG'})) $l
        if (-not $script:IsPreview) { & wevtutil.exe cl $l; if($LASTEXITCODE -eq 0){$cleared++} }
        else { $cleared++ }
    }
    $cleared
}

function Clear-Prefetch {
    $cat = 'Aggressive Extras'
    $pf = $script:SysLoc.Prefetch
    if ($pf -and (Test-Path $pf)) {
        $c = Remove-FilesByPattern $pf @('*.pf') -Category $cat
        Write-Log "Removed $c prefetch files"
    }
}

function Clear-FontCache {
    $fontPath = Join-Path $script:SysLoc.WindowsRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    if (Test-Path -LiteralPath $fontPath) {
        Write-CommandLog ($(if($script:IsPreview){'PREVIEW'}else{'CLEAR'})) 'Font Cache'
        $wasRunning = $false
        try {
            $svc = Get-Service FontCache -EA SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                if (-not $script:IsPreview) {
                    Write-CommandLog 'STOP' 'FontCache'
                    Stop-Service FontCache -Force -EA SilentlyContinue
                    $wasRunning = $true
                }
            }
            if (-not $script:IsPreview) {
                Get-ChildItem $fontPath -Force -EA SilentlyContinue | ForEach-Object {
                    Remove-Item $_.FullName -Force -EA SilentlyContinue
                }
            }
        }
        finally {
            if ($wasRunning -and -not $script:IsPreview) {
                Write-CommandLog 'START' 'FontCache'
                Start-Service FontCache -EA SilentlyContinue
            }
        }
    }
}

# ════════════════════════════════════════════════════════════════
#  STEP 10: LOG FILE SWEEP
# ════════════════════════════════════════════════════════════════

function Clear-SystemLogFiles {
    $cat = 'Log Files'; $count = 0
    $roots = @(
        (Get-EnvPath 'LOCALAPPDATA'),
        (Get-EnvPath 'APPDATA'),
        $script:SysLoc.ProgramData
    )
    $logFiles = Get-DisposableLogCandidates -Roots $roots -OlderThanDays 14 |
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
        $count++
    }
    $count
}

# ════════════════════════════════════════════════════════════════
#  MAIN CLEANUP ORCHESTRATOR
# ════════════════════════════════════════════════════════════════

function Invoke-CleanupRun {
    param([ValidateSet('Standard','Aggressive','Preview')][string]$SelectedMode)

    $script:IsPreview       = $SelectedMode -eq 'Preview'
    $script:IsAggressive    = $SelectedMode -eq 'Aggressive'
    $script:CurrentModeName = $SelectedMode
    $script:StepIndex       = 0
    $script:TotalSteps      = 10 + $(if($script:IsAggressive){3}else{0})
    $script:BytesFreed      = [long]0
    $script:CategorySizes   = @{}
    $script:OrphanReport    = @()
    $script:SkippedItems    = @()
    $script:RunningProcesses = Get-RunningProcessNames

    $start      = Get-Date
    $startSpace = Get-FreeSpaceInfo
    $junkRoots  = Get-JunkSweepRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    Show-Header
    Write-Log "Mode: $SelectedMode"
    Write-Log "Started: $($start.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log "Initial free: $($startSpace.MB) MB ($($startSpace.GB) GB)"

    # ── Execute steps ──
    Start-Step 'System temp, update, crash, delivery caches'
    $s1 = Clear-SystemCaches
    Finish-Step "$s1 locations processed"

    Start-Step 'Chromium browser caches (Chrome, Edge, Brave, Opera, Vivaldi)'
    $s2 = 0
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Google\Chrome\User Data') 'Chrome'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Microsoft\Edge\User Data') 'Edge'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'BraveSoftware\Brave-Browser\User Data') 'Brave'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'APPDATA' 'Opera Software\Opera Stable') 'Opera'
    $s2 += Clear-ChromiumCaches (Join-EnvPath 'LOCALAPPDATA' 'Vivaldi\User Data') 'Vivaldi'
    Finish-Step "$s2 browser profiles cleaned"

    Start-Step 'Firefox caches'
    $s3 = Clear-FirefoxCaches
    Finish-Step "$s3 Firefox profiles cleaned"

    Start-Step 'Application caches (Discord, Spotify, VS Code, Telegram, etc.)'
    $s4 = Clear-AppCaches
    Finish-Step "$s4 app locations cleaned"

    Start-Step 'Developer tool caches (npm, pip, pnpm, NuGet, Composer, etc.)'
    $s5 = Clear-DevCaches
    Finish-Step "$s5 dev cache locations cleaned"

    Start-Step 'GPU, thumbnail, and icon caches'
    $s6 = Clear-GpuAndShellCaches
    Finish-Step "$s6 cache locations cleaned"

    Start-Step 'Recycle Bin'
    [void](Clear-RecycleBinSafe)
    Finish-Step 'Recycle Bin emptied'

    Start-Step 'Old log files (14+ days)'
    $s8 = Clear-SystemLogFiles
    Finish-Step "$s8 log files cleaned"

    Start-Step 'Empty and stale junk folders'
    $emptyRm = Remove-EmptyDirectories -Roots $junkRoots
    $staleRm = Remove-StaleJunkFolders -Roots $junkRoots
    Finish-Step "$emptyRm empty, $staleRm stale folders removed"

    Start-Step 'Orphan folder scan'
    $orphans = Find-OrphanFolders  # Interactive deletion is ONLY explicitly invoked from Option 4
    Finish-Step "$orphans potential orphans detected"

    if ($script:IsAggressive) {
        Start-Step 'Prefetch cleanup'
        Clear-Prefetch
        Finish-Step 'Prefetch cleaned'

        Start-Step 'Component store cleanup (DISM)'
        [void](Invoke-ComponentCleanup)
        Finish-Step 'DISM cleanup finished'

        Start-Step 'Event logs + Font cache'
        $logsCl = Clear-EventLogs
        Clear-FontCache
        Finish-Step "$logsCl event logs cleared, font cache cleaned"
    }

    # ── Summary ──
    $finish   = Get-Date
    $endSpace = Get-FreeSpaceInfo
    $freedMB  = $endSpace.MB - $startSpace.MB
    $freedGB  = [math]::Round($freedMB / 1024, 2)
    $dur      = [math]::Round(($finish - $start).TotalSeconds, 1)

    $script:LastRunSummary = [pscustomobject]@{
        Mode = $SelectedMode; FinishedAt = $finish; DurationSeconds = $dur
        TotalFreed = [Math]::Max(0, $script:BytesFreed)
        FreedMB = $freedMB; FreedGB = $freedGB
    }

    Write-Host ''
    $summaryColor = Get-ModeColor $SelectedMode
    $pipelineBar = New-AsciiBar -Value $script:TotalSteps -Total $script:TotalSteps -Width 18
    $sumLines = @(
        "Run summary  : $($SelectedMode.ToUpper())",
        "Pipeline     : $pipelineBar",
        "Finished     : $($finish.ToString('yyyy-MM-dd HH:mm:ss'))",
        "Duration     : ${dur}s",
        "Before       : $($startSpace.MB) MB ($($startSpace.GB) GB)",
        "After        : $($endSpace.MB) MB ($($endSpace.GB) GB)",
        "Measured     : $(Format-FileSize ([Math]::Max(0, $script:BytesFreed)))",
        "Observed     : $freedMB MB ($freedGB GB)"
    )
    Write-Panel $sumLines -BorderColor $summaryColor -TextColor 'White' -MinWidth 58 -MaxWidth 86
    Write-Host ''

    # Category breakdown
    if ($script:CategorySizes.Count -gt 0) {
        Write-SectionHeader 'Category Breakdown'
        $script:CategorySizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("  {0,-22} {1,12}" -f $_.Key, (Format-FileSize $_.Value)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    Write-SectionHeader 'Impact'
    Write-Host ("  {0,-16} {1}" -f 'System caches', $s1) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Browsers', "$s2 Chromium | $s3 Firefox") -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'App caches', $s4) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Dev caches', $s5) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'GPU/Shell', $s6) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Log files', $s8) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Empty folders', $emptyRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Stale junk', $staleRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Orphans', $orphans) -ForegroundColor $(if($orphans -gt 0){'Yellow'}else{'DarkGray'})

    if ($script:SkippedItems.Count -gt 0) {
        Write-Host ''
        Write-SectionHeader 'Safety Skips'
        $script:SkippedItems | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    if ($script:IsPreview) {
        Write-Log 'PREVIEW mode. Nothing was deleted.' 'WARN'
    } elseif ($script:IsAggressive) {
        Write-Log 'Aggressive mode completed with extras.' 'WARN'
    }
}

# ════════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════════

$script:SysLoc       = Get-SystemLocations
$script:ExcludedPaths = Get-ExcludedPaths

if ($LogFile) {
    $script:LogFilePath = Resolve-FullPath $LogFile
    if (-not $script:LogFilePath) { $script:LogFilePath = $LogFile }
    try {
        $header = "# SystemCleaner log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Mode: $Mode"
        Set-Content -LiteralPath $script:LogFilePath -Value $header -Encoding UTF8 -EA SilentlyContinue
    } catch { $script:LogFilePath = '' }
}

if ($SkipBootstrap) { return }

if (-not (Test-IsAdministrator)) {
    if (Restart-Elevated -SelectedMode $Mode) { exit 0 }
    if (-not $NoPause) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit 1
}

switch ($Mode) {
    'Standard'   { Invoke-CleanupRun 'Standard';   if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Aggressive' { Invoke-CleanupRun 'Aggressive';  if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Preview'    { Invoke-CleanupRun 'Preview';     if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    default      { Show-Menu }
}
