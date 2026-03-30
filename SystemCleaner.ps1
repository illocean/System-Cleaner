[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview')]
    [string]$Mode = 'Menu',
    [string[]]$ExtraExcludePath = @(),
    [switch]$NoPause
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'System Cleaner'

$script:IsPreview = $false
$script:IsAggressive = $false
$script:CurrentModeName = 'Menu'
$script:StepIndex = 0
$script:TotalSteps = 0
$script:ExcludedPaths = $null
$script:LastRunSummary = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$SelectedMode)

    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add('-NoProfile')
    $argsList.Add('-ExecutionPolicy')
    $argsList.Add('Bypass')
    $argsList.Add('-File')
    $argsList.Add(('"'+$PSCommandPath+'"'))

    if ($SelectedMode) {
        $argsList.Add('-Mode')
        $argsList.Add($SelectedMode)
    }

    if ($NoPause) {
        $argsList.Add('-NoPause')
    }

    try {
        Write-Host ''
        Write-Host 'Administrator rights are required. Requesting elevation...' -ForegroundColor Yellow
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argsList | Out-Null
        return $true
    } catch {
        Write-Host 'Elevation was cancelled.' -ForegroundColor Red
        return $false
    }
}

function Get-FreeSpaceInfo {
    param([string]$DriveLetter = $env:SystemDrive.TrimEnd(':'))

    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $DriveLetter)
    if (-not $drive) {
        return [pscustomobject]@{
            MB = 0
            GB = 0
        }
    }

    return [pscustomobject]@{
        MB = [math]::Round($drive.FreeSpace / 1MB)
        GB = [math]::Round($drive.FreeSpace / 1GB, 2)
    }
}

function Get-SystemLocations {
    $windowsRoot = Resolve-FullPath $env:SystemRoot
    $programData = Resolve-FullPath $env:ProgramData
    $systemDrive = Resolve-FullPath $env:SystemDrive

    return [pscustomobject]@{
        WindowsRoot = $windowsRoot
        ProgramData = $programData
        SystemDrive = $systemDrive
        WindowsTemp = $(if ($windowsRoot) { Join-Path $windowsRoot 'Temp' })
        WerArchive = $(if ($programData) { Join-Path $programData 'Microsoft\Windows\WER\ReportArchive' })
        WerQueue = $(if ($programData) { Join-Path $programData 'Microsoft\Windows\WER\ReportQueue' })
        NetworkDownloader = $(if ($programData) { Join-Path $programData 'Microsoft\Network\Downloader' })
        SoftwareDistributionDownload = $(if ($windowsRoot) { Join-Path $windowsRoot 'SoftwareDistribution\Download' })
    }
}

function Resolve-FullPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $null
    }
}

function New-TrackedSet {
    return New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function Get-ExcludedPaths {
    $set = New-TrackedSet
    foreach ($candidate in @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        $(if ($env:OneDrive) { Join-Path $env:OneDrive 'Downloads' })
    )) {
        $resolved = Resolve-FullPath $candidate
        if ($resolved) {
            [void]$set.Add($resolved)
        }
    }

    foreach ($candidate in $ExtraExcludePath) {
        $resolved = Resolve-FullPath $candidate
        if ($resolved) {
            [void]$set.Add($resolved)
        }
    }

    return $set
}

function Test-IsExcludedPath {
    param([string]$Path)

    $resolved = Resolve-FullPath $Path
    if (-not $resolved) {
        return $false
    }

    foreach ($excluded in $script:ExcludedPaths) {
        if (
            $resolved.Equals($excluded, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolved.StartsWith(($excluded + '\'), [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return $true
        }
    }

    return $false
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'CMD', 'STEP')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'CMD'  { 'DarkGray' }
        'STEP' { 'Cyan' }
        default { 'White' }
    }

    Write-Host ("[{0}] {1}" -f $timestamp, $Message) -ForegroundColor $color
}

function Write-CommandLog {
    param(
        [string]$Verb,
        [string]$Target
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Log -Message $Verb -Level 'CMD'
        return
    }

    Write-Log -Message ("{0} {1}" -f $Verb, $Target) -Level 'CMD'
}

function Get-ConsoleWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -lt 60) {
            return 60
        }

        return $width
    } catch {
        return 100
    }
}

function Get-DisplayText {
    param(
        [string]$Text,
        [int]$MaxWidth
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    if ($Text.Length -le $MaxWidth) {
        return $Text
    }

    if ($MaxWidth -le 3) {
        return $Text.Substring(0, [Math]::Max(0, $MaxWidth))
    }

    return $Text.Substring(0, $MaxWidth - 3) + '...'
}

function Write-CenteredLine {
    param(
        [string]$Text,
        [string]$ForegroundColor = 'White'
    )

    $consoleWidth = Get-ConsoleWidth
    $renderText = Get-DisplayText -Text $Text -MaxWidth $consoleWidth
    $padding = [Math]::Max(0, [int](($consoleWidth - $renderText.Length) / 2))
    Write-Host ((' ' * $padding) + $renderText) -ForegroundColor $ForegroundColor
}

function Write-Panel {
    param(
        [string[]]$Lines,
        [string]$BorderColor = 'DarkCyan',
        [string]$TextColor = 'White',
        [int]$MinWidth = 60,
        [int]$MaxWidth = 92
    )

    $consoleWidth = Get-ConsoleWidth
    $availableWidth = [Math]::Max(20, $consoleWidth - 4)
    $contentWidth = 0

    foreach ($line in $Lines) {
        if ($line.Length -gt $contentWidth) {
            $contentWidth = $line.Length
        }
    }

    $panelWidth = [Math]::Min($availableWidth, [Math]::Max($MinWidth, $contentWidth + 4))
    $panelWidth = [Math]::Min($panelWidth, $MaxWidth)
    $panelWidth = [Math]::Min($panelWidth, $consoleWidth)

    $innerWidth = [Math]::Max(1, $panelWidth - 4)
    $padding = [Math]::Max(0, [int](($consoleWidth - $panelWidth) / 2))
    $leftPad = ' ' * $padding
    $border = '+' + ('-' * ($panelWidth - 2)) + '+'

    Write-Host ($leftPad + $border) -ForegroundColor $BorderColor
    foreach ($line in $Lines) {
        $renderLine = (Get-DisplayText -Text $line -MaxWidth $innerWidth).PadRight($innerWidth)
        Write-Host ($leftPad + '| ' + $renderLine + ' |') -ForegroundColor $TextColor
    }
    Write-Host ($leftPad + $border) -ForegroundColor $BorderColor
}

function Show-AppLogo {
    $logo = @(
        '   _____           _                  _____ _                           ',
        '  / ____|         | |                / ____| |                          ',
        ' | (___  _   _ ___| |_ ___ _ __     | |    | | ___  __ _ _ __   ___ _ __ ',
        '  \___ \| | | / __| __/ _ \ ''_ \    | |    | |/ _ \/ _` | ''_ \ / _ \ ''__|',
        '  ____) | |_| \__ \ ||  __/ | | |   | |____| |  __/ (_| | | | |  __/ |   ',
        ' |_____/ \__, |___/\__\___|_| |_|    \_____|_|\___|\__,_|_| |_|\___|_|   ',
        '          __/ |                                                           ',
        '         |___/                                                            '
    )

    foreach ($line in $logo) {
        Write-CenteredLine -Text $line -ForegroundColor 'Cyan'
    }

    Write-CenteredLine -Text '--------------------------------------------------------------' -ForegroundColor 'DarkCyan'
    Write-CenteredLine -Text 'Windows cleanup console for temp, cache, and maintenance tasks' -ForegroundColor 'DarkGray'
}

function Get-ExcludedPathSummary {
    $text = (($script:ExcludedPaths | Sort-Object) -join ', ')
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'None'
    }

    return $text
}

function Get-LastRunSummaryText {
    if (-not $script:LastRunSummary) {
        return 'No cleanup completed in this session'
    }

    return (
        "Mode {0} at {1} | {2}s | {3} MB freed" -f
        $script:LastRunSummary.Mode,
        $script:LastRunSummary.FinishedAt.ToString('HH:mm:ss'),
        $script:LastRunSummary.DurationSeconds,
        $script:LastRunSummary.FreedMB
    )
}

function Show-Header {
    Clear-Host
    Write-Host ''
    Show-AppLogo
    Write-Host ''

    $free = Get-FreeSpaceInfo
    $modeLabel = if ($script:CurrentModeName -eq 'Menu') { 'Interactive menu' } else { $script:CurrentModeName }
    $statusLines = @(
        ("Session mode     : {0}" -f $modeLabel),
        ("Free space       : {0} MB ({1} GB)" -f $free.MB, $free.GB),
        ("Protected paths  : {0}" -f (Get-ExcludedPathSummary)),
        ("Last run recap   : {0}" -f (Get-LastRunSummaryText))
    )
    Write-Panel -Lines $statusLines -BorderColor 'DarkCyan' -TextColor 'White' -MinWidth 68 -MaxWidth 100
    Write-Host ''
}

function Show-Menu {
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        Write-Panel -Lines @(
            'MAIN MENU',
            '',
            '[1] Standard clean   Routine cleanup for temp files, browser caches, and common app caches',
            '[2] Aggressive clean Adds DISM component cleanup and Windows event log clearing',
            '[3] Preview run      Shows the cleanup plan without deleting anything',
            '[Q] Quit             Exit the console'
        ) -BorderColor 'Cyan' -TextColor 'White' -MinWidth 76 -MaxWidth 108
        Write-Host ''
        Write-CenteredLine -Text 'Choose a mode and press Enter. Cleanup logs remain visible after each run.' -ForegroundColor 'DarkGray'
        Write-Host ''

        $choice = (Read-Host 'Selection').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' {
                Invoke-CleanupRun -SelectedMode 'Standard'
                if (-not (Handle-PostRunPrompt -PreviousMode 'Standard')) { break }
            }
            '2' {
                Invoke-CleanupRun -SelectedMode 'Aggressive'
                if (-not (Handle-PostRunPrompt -PreviousMode 'Aggressive')) { break }
            }
            '3' {
                Invoke-CleanupRun -SelectedMode 'Preview'
                if (-not (Handle-PostRunPrompt -PreviousMode 'Preview')) { break }
            }
            'Q' { return }
            default {
                Write-Host ''
                Write-Host 'Invalid selection. Press Enter to continue.' -ForegroundColor Yellow
                [void](Read-Host)
            }
        }
    }
}

function Handle-PostRunPrompt {
    param([string]$PreviousMode)

    while ($true) {
        Write-Host ''
        Write-Panel -Lines @(
            'POST-RUN ACTIONS',
            '',
            '[Enter] Return to the main menu',
            ("[R] Run {0} again" -f $PreviousMode),
            '[Q] Exit the console'
        ) -BorderColor 'Yellow' -TextColor 'White' -MinWidth 54 -MaxWidth 72
        $choice = (Read-Host 'Next action').Trim().ToUpperInvariant()

        switch ($choice) {
            '' {
                return $true
            }
            'R' {
                Invoke-CleanupRun -SelectedMode $PreviousMode
            }
            'Q' {
                return $false
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
            }
        }
    }
}

function Start-Step {
    param([string]$Name)

    $script:StepIndex++
    Write-Host ''
    Write-Log -Message ("[{0}/{1}] {2}" -f $script:StepIndex, $script:TotalSteps, $Name) -Level 'STEP'
}

function Finish-Step {
    param([string]$Summary)

    Write-Log -Message $Summary -Level 'OK'
}

function Clear-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$EnsureDirectory
    )

    $resolved = Resolve-FullPath $Path
    if (-not $resolved -or (Test-IsExcludedPath $resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        return $false
    }

    Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW clear' } else { 'CLEAR' })) -Target $resolved

    if ($script:IsPreview) {
        return $true
    }

    $items = Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($EnsureDirectory -and -not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }

    return $true
}

function Clear-ChromiumCaches {
    param(
        [string]$UserDataRoot,
        [string]$Label
    )

    $profilesCleaned = 0
    if (-not (Test-Path -LiteralPath $UserDataRoot -PathType Container)) {
        return $profilesCleaned
    }

    $cacheDirs = @(
        'Cache',
        'Code Cache',
        'GPUCache',
        'Media Cache',
        'DawnCache',
        'ShaderCache',
        'GrShaderCache',
        'GraphiteDawnCache'
    )

    $profiles = Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue
    foreach ($profile in $profiles) {
        $hit = $false

        foreach ($cacheDir in $cacheDirs) {
            $target = Join-Path $profile.FullName $cacheDir
            if (Test-Path -LiteralPath $target) {
                [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
                $hit = $true
            }
        }

        foreach ($extra in @(
            (Join-Path $profile.FullName 'Service Worker\CacheStorage'),
            (Join-Path $profile.FullName 'Crashpad')
        )) {
            if (Test-Path -LiteralPath $extra) {
                [void](Clear-DirectoryContents -Path $extra -EnsureDirectory)
                $hit = $true
            }
        }

        if ($hit) {
            Write-Log -Message ("Processed {0} profile: {1}" -f $Label, $profile.Name)
            $profilesCleaned++
        }
    }

    return $profilesCleaned
}

function Clear-FirefoxCaches {
    $profilesCleaned = 0
    $root = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $profilesCleaned
    }

    $profiles = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
    foreach ($profile in $profiles) {
        $hit = $false
        foreach ($target in @(
            (Join-Path $profile.FullName 'cache2'),
            (Join-Path $profile.FullName 'startupCache'),
            (Join-Path $profile.FullName 'thumbnails')
        )) {
            if (Test-Path -LiteralPath $target) {
                [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
                $hit = $true
            }
        }

        if ($hit) {
            Write-Log -Message ("Processed Firefox profile: {0}" -f $profile.Name)
            $profilesCleaned++
        }
    }

    return $profilesCleaned
}

function Clear-AppCaches {
    $locationsCleaned = 0

    foreach ($discordName in @('discord', 'discordcanary', 'discordptb')) {
        $root = Join-Path $env:APPDATA $discordName
        $hit = $false
        foreach ($dirName in @('Cache', 'Code Cache', 'GPUCache')) {
            $target = Join-Path $root $dirName
            if (Test-Path -LiteralPath $target) {
                [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
                $hit = $true
            }
        }
        if ($hit) {
            Write-Log -Message ("Processed app cache: {0}" -f $discordName)
            $locationsCleaned++
        }
    }

    foreach ($codeRoot in @(
        (Join-Path $env:APPDATA 'Code'),
        (Join-Path $env:APPDATA 'Code - Insiders')
    )) {
        $hit = $false
        foreach ($dirName in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) {
            $target = Join-Path $codeRoot $dirName
            if (Test-Path -LiteralPath $target) {
                [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
                $hit = $true
            }
        }
        if ($hit) {
            Write-Log -Message ("Processed app cache: {0}" -f ([System.IO.Path]::GetFileName($codeRoot)))
            $locationsCleaned++
        }
    }

    foreach ($spotifyTarget in @(
        (Join-Path $env:APPDATA 'Spotify\Cache'),
        (Join-Path $env:APPDATA 'Spotify\Storage'),
        (Join-Path $env:LOCALAPPDATA 'Spotify\Storage')
    )) {
        if (Test-Path -LiteralPath $spotifyTarget) {
            [void](Clear-DirectoryContents -Path $spotifyTarget -EnsureDirectory)
            Write-Log -Message ("Processed Spotify cache: {0}" -f $spotifyTarget)
            $locationsCleaned++
        }
    }

    $telegramRoot = Join-Path $env:APPDATA 'Telegram Desktop\tdata'
    if (Test-Path -LiteralPath $telegramRoot -PathType Container) {
        $telegramCaches = Get-ChildItem -LiteralPath $telegramRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'cache' }
        $telegramHit = $false
        foreach ($cacheDir in $telegramCaches) {
            [void](Clear-DirectoryContents -Path $cacheDir.FullName -EnsureDirectory)
            $telegramHit = $true
        }
        if ($telegramHit) {
            Write-Log -Message 'Processed app cache: Telegram Desktop'
            $locationsCleaned++
        }
    }

    $stremioRoot = Join-Path $env:APPDATA 'Stremio'
    if (Test-Path -LiteralPath $stremioRoot -PathType Container) {
        $stremioTargets = Get-ChildItem -LiteralPath $stremioRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { @('cache', 'temp', 'logs') -contains $_.Name.ToLowerInvariant() }
        $stremioHit = $false
        foreach ($target in $stremioTargets) {
            [void](Clear-DirectoryContents -Path $target.FullName -EnsureDirectory)
            $stremioHit = $true
        }
        if ($stremioHit) {
            Write-Log -Message 'Processed app cache: Stremio'
            $locationsCleaned++
        }
    }

    return $locationsCleaned
}

function Clear-SystemCaches {
    $locationsCleaned = 0

    foreach ($target in @(
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        $script:SystemLocations.WindowsTemp,
        (Join-Path $env:LOCALAPPDATA 'CrashDumps'),
        $script:SystemLocations.WerArchive,
        $script:SystemLocations.WerQueue,
        $script:SystemLocations.NetworkDownloader
    )) {
        if (Test-Path -LiteralPath $target) {
            [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
            $locationsCleaned++
        }
    }

    $servicesToRestart = @()
    foreach ($serviceName in @('wuauserv', 'bits', 'dosvc')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Stopped') {
            Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW stop-service' } else { 'STOP-SERVICE' })) -Target $serviceName
            if (-not $script:IsPreview) {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                $servicesToRestart += $serviceName
            }
        }
    }

    $softwareDistribution = $script:SystemLocations.SoftwareDistributionDownload
    if (Test-Path -LiteralPath $softwareDistribution) {
        [void](Clear-DirectoryContents -Path $softwareDistribution -EnsureDirectory)
        $locationsCleaned++
    }

    foreach ($serviceName in $servicesToRestart) {
        Write-CommandLog -Verb 'START-SERVICE' -Target $serviceName
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
    }

    return $locationsCleaned
}

function Clear-GpuAndShellCaches {
    $locationsCleaned = 0

    foreach ($target in @(
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')
    )) {
        if (Test-Path -LiteralPath $target) {
            [void](Clear-DirectoryContents -Path $target -EnsureDirectory)
            $locationsCleaned++
        }
    }

    $explorerCacheRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $explorerCacheRoot) {
        $files = Get-ChildItem -LiteralPath $explorerCacheRoot -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like 'thumbcache_*.db' -or
                $_.Name -like 'iconcache_*.db'
            }

        if ($files) {
            $explorerWasRunning = $false
            if (-not $script:IsPreview) {
                $explorerWasRunning = @(Get-Process explorer -ErrorAction SilentlyContinue).Count -gt 0
                if ($explorerWasRunning) {
                    Write-CommandLog -Verb 'STOP-PROCESS' -Target 'explorer.exe'
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                }
            }

            foreach ($file in $files) {
                Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW remove' } else { 'REMOVE' })) -Target $file.FullName
                if (-not $script:IsPreview) {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not $script:IsPreview -and $explorerWasRunning) {
                Write-CommandLog -Verb 'START-PROCESS' -Target 'explorer.exe'
                Start-Process explorer.exe
            }

            $locationsCleaned++
        }
    }

    return $locationsCleaned
}

function Clear-RecycleBinSafe {
    Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW clear' } else { 'CLEAR' })) -Target 'Recycle Bin'
    if ($script:IsPreview) {
        return $true
    }

    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    return $true
}

function Remove-EmptyDirectories {
    param([string[]]$Roots)

    $removed = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $dirs = Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending

        foreach ($dir in $dirs) {
            if (Test-IsExcludedPath $dir.FullName) {
                continue
            }

            $hasEntries = Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $hasEntries) {
                Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW remove-empty' } else { 'REMOVE-EMPTY' })) -Target $dir.FullName
                if (-not $script:IsPreview) {
                    Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
                }
                $removed++
            }
        }
    }

    return $removed
}

function Remove-StaleJunkFolders {
    param(
        [string[]]$Roots,
        [int]$OlderThanDays = 45
    )

    $removed = 0
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $allowedNames = @(
        'cache',
        'caches',
        'code cache',
        'gpucache',
        'media cache',
        'dawncache',
        'shadercache',
        'grshadercache',
        'graphitedawncache',
        'startupcache',
        'cache2',
        'temp',
        'tmp',
        'logs',
        'log',
        'crashpad',
        'crashdumps'
    )

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $dirs = Get-ChildItem -LiteralPath $root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-IsExcludedPath $_.FullName) -and
                $allowedNames -contains $_.Name.ToLowerInvariant() -and
                $_.LastWriteTime -lt $cutoff
            } |
            Sort-Object FullName -Descending

        foreach ($dir in $dirs) {
            Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW remove-stale' } else { 'REMOVE-STALE' })) -Target $dir.FullName
            if (-not $script:IsPreview) {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            $removed++
        }
    }

    return $removed
}

function Invoke-ComponentCleanup {
    Write-CommandLog -Verb 'RUN' -Target 'Dism.exe /online /Cleanup-Image /StartComponentCleanup'
    if ($script:IsPreview) {
        return $true
    }

    & Dism.exe /online /Cleanup-Image /StartComponentCleanup
    return $LASTEXITCODE -eq 0
}

function Clear-EventLogs {
    $cleared = 0
    $logs = & wevtutil.exe el
    foreach ($logName in $logs) {
        Write-CommandLog -Verb ($(if ($script:IsPreview) { 'PREVIEW clear-log' } else { 'CLEAR-LOG' })) -Target $logName
        if ($script:IsPreview) {
            $cleared++
            continue
        }

        & wevtutil.exe cl $logName
        if ($LASTEXITCODE -eq 0) {
            $cleared++
        }
    }

    return $cleared
}

function Invoke-CleanupRun {
    param([ValidateSet('Standard', 'Aggressive', 'Preview')][string]$SelectedMode)

    $script:IsPreview = $SelectedMode -eq 'Preview'
    $script:IsAggressive = $SelectedMode -eq 'Aggressive'
    $script:CurrentModeName = $SelectedMode
    $script:StepIndex = 0
    $script:TotalSteps = 7 + $(if ($script:IsAggressive) { 2 } else { 0 })

    $start = Get-Date
    $startSpace = Get-FreeSpaceInfo
    $safeRoots = @(
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:TEMP,
        $script:SystemLocations.ProgramData,
        $script:SystemLocations.WindowsTemp,
        $script:SystemLocations.SoftwareDistributionDownload
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    Show-Header
    Write-Log -Message ("Mode: {0}" -f $SelectedMode)
    Write-Log -Message ("Started: {0}" -f $start.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Log -Message ("Initial free space: {0} MB ({1} GB)" -f $startSpace.MB, $startSpace.GB)

    Start-Step -Name 'System temp, update, crash, and delivery caches'
    $systemLocations = Clear-SystemCaches
    Finish-Step -Summary ("{0} locations processed" -f $systemLocations)

    Start-Step -Name 'Chromium browser caches'
    $browserCount = 0
    $browserCount += Clear-ChromiumCaches -UserDataRoot (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') -Label 'Chrome'
    $browserCount += Clear-ChromiumCaches -UserDataRoot (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') -Label 'Edge'
    $browserCount += Clear-ChromiumCaches -UserDataRoot (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') -Label 'Brave'
    Finish-Step -Summary ("{0} browser profiles processed" -f $browserCount)

    Start-Step -Name 'Firefox cache'
    $firefoxCount = Clear-FirefoxCaches
    Finish-Step -Summary ("{0} Firefox profiles processed" -f $firefoxCount)

    Start-Step -Name 'App caches'
    $appCount = Clear-AppCaches
    Finish-Step -Summary ("{0} app cache locations processed" -f $appCount)

    Start-Step -Name 'GPU, thumbnail, and icon caches'
    $shellCount = Clear-GpuAndShellCaches
    Finish-Step -Summary ("{0} cache locations processed" -f $shellCount)

    Start-Step -Name 'Recycle Bin'
    [void](Clear-RecycleBinSafe)
    Finish-Step -Summary 'Recycle Bin processed'

    Start-Step -Name 'Empty and stale junk folders'
    $emptyRemoved = Remove-EmptyDirectories -Roots $safeRoots
    $staleRemoved = Remove-StaleJunkFolders -Roots $safeRoots
    Finish-Step -Summary ("{0} empty folders processed, {1} stale junk folders processed" -f $emptyRemoved, $staleRemoved)

    if ($script:IsAggressive) {
        Start-Step -Name 'Component store cleanup'
        [void](Invoke-ComponentCleanup)
        Finish-Step -Summary 'DISM component cleanup finished'

        Start-Step -Name 'Event logs'
        $logsCleared = Clear-EventLogs
        Finish-Step -Summary ("{0} logs processed" -f $logsCleared)
    }

    $finish = Get-Date
    $endSpace = Get-FreeSpaceInfo
    $freedMB = $endSpace.MB - $startSpace.MB
    $freedGB = [math]::Round($freedMB / 1024, 2)
    $durationSeconds = [math]::Round(($finish - $start).TotalSeconds, 1)

    $script:LastRunSummary = [pscustomobject]@{
        Mode = $SelectedMode
        FinishedAt = $finish
        DurationSeconds = $durationSeconds
        FreedMB = $freedMB
        FreedGB = $freedGB
        SystemLocations = $systemLocations
        ChromiumProfiles = $browserCount
        FirefoxProfiles = $firefoxCount
        AppLocations = $appCount
        ShellCaches = $shellCount
        EmptyRemoved = $emptyRemoved
        StaleRemoved = $staleRemoved
        LogsCleared = $(if ($script:IsAggressive) { $logsCleared } else { 0 })
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor White
    Write-Host ' Run Summary' -ForegroundColor White
    Write-Host '============================================================' -ForegroundColor White
    Write-Log -Message ("Finished: {0}" -f $finish.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Log -Message ("Before:  {0} MB ({1} GB)" -f $startSpace.MB, $startSpace.GB)
    Write-Log -Message ("After:   {0} MB ({1} GB)" -f $endSpace.MB, $endSpace.GB)
    Write-Log -Message ("Freed:   {0} MB ({1} GB)" -f $freedMB, $freedGB)
    Write-Log -Message ("Duration: {0} seconds" -f $durationSeconds)
    Write-Host ''
    Write-Host ' Key results:' -ForegroundColor DarkGray
    Write-Host ("  - System caches: {0}" -f $systemLocations) -ForegroundColor DarkGray
    Write-Host ("  - Chromium profiles: {0}" -f $browserCount) -ForegroundColor DarkGray
    Write-Host ("  - Firefox profiles: {0}" -f $firefoxCount) -ForegroundColor DarkGray
    Write-Host ("  - App cache locations: {0}" -f $appCount) -ForegroundColor DarkGray
    Write-Host ("  - Shell/GPU cache locations: {0}" -f $shellCount) -ForegroundColor DarkGray
    Write-Host ("  - Empty folders removed: {0}" -f $emptyRemoved) -ForegroundColor DarkGray
    Write-Host ("  - Stale junk folders removed: {0}" -f $staleRemoved) -ForegroundColor DarkGray
    if ($script:IsAggressive) {
        Write-Host ("  - Event logs cleared: {0}" -f $logsCleared) -ForegroundColor DarkGray
    }
    if ($script:IsPreview) {
        Write-Log -Message 'Preview mode only. No files were deleted.' -Level 'WARN'
    } elseif ($script:IsAggressive) {
        Write-Log -Message 'Aggressive extras were enabled.' -Level 'WARN'
    }
}

$script:SystemLocations = Get-SystemLocations
$script:ExcludedPaths = Get-ExcludedPaths

if (-not (Test-IsAdministrator)) {
    if (Restart-Elevated -SelectedMode $Mode) {
        exit 0
    }

    if (-not $NoPause) {
        Write-Host ''
        [void](Read-Host 'Press Enter to close')
    }
    exit 1
}

switch ($Mode) {
    'Standard' {
        Invoke-CleanupRun -SelectedMode 'Standard'
        if (-not $NoPause) {
            Write-Host ''
            [void](Read-Host 'Press Enter to close')
        }
    }
    'Aggressive' {
        Invoke-CleanupRun -SelectedMode 'Aggressive'
        if (-not $NoPause) {
            Write-Host ''
            [void](Read-Host 'Press Enter to close')
        }
    }
    'Preview' {
        Invoke-CleanupRun -SelectedMode 'Preview'
        if (-not $NoPause) {
            Write-Host ''
            [void](Read-Host 'Press Enter to close')
        }
    }
    default {
        Show-Menu
    }
}
