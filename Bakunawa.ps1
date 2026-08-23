<#
Bakunawa v4.0 - Self-Contained System Cleaner
Modular architecture with separate modules in src/
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')]
    [string]$Mode = 'Menu',
    [switch]$NoPause,
    [switch]$VerboseScan,
    [string[]]$ExtraExcludePath,
    [string]$LogFile,
    [string]$Profile,
    [switch]$SkipBootstrap,
    [switch]$ForceAdmin,
    [switch]$NoAnimations
)

Set-Variable -Name ErrorActionPreference -Value 'Continue' -Scope Script
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Animation frames
$script:SpinnerFrames = @('|','/','-','\')
$script:SpinnerIndex = 0
$script:WaveFrames = @('1','2','3','4','5','6','7','8')
$script:WaveIndex = 0
$script:PulseFrames = @('o','O','@','*')
$script:PulseIndex = 0

# Import modules from src/
$moduleDir = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleDir 'Bakunawa.Core.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Config.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Runspace.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Cleanup.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.UI.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Quarantine.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue

function Show-RunSummary {
    param([PSCustomObject]$Result)
    $width = [Math]::Min(64, (Get-ConsoleWidth) - 1)
    $rule = ([string][char]0x2500) * $width
    Write-Host ''
    Write-Host $rule -ForegroundColor DarkGray

    $verb = switch ($Result.Mode) {
        'Preview'    { 'Preview complete' }
        'Aggressive' { 'Deep clean complete' }
        default      { 'Cleanup complete' }
    }
    $dur = '{0:m\:ss}' -f [TimeSpan]::FromSeconds([double]$Result.DurationSec)
    Write-Host ("{0} in {1}" -f $verb, $dur) -ForegroundColor White

    $label = if ($Result.Mode -eq 'Preview') { 'Reclaimable' } else { 'Freed' }
    Write-Host ("  {0} : {1} ({2} path{3})" -f $label, (Format-FileSize $Result.BytesFreed), $Result.PathsCleared, $(if ($Result.PathsCleared -eq 1) { '' } else { 's' }))

    $skipCount = @($Result.SkippedItems).Count
    Write-Host ("  Skipped     : {0}" -f $skipCount) -ForegroundColor $(if ($skipCount -gt 0) { 'Yellow' } else { 'Gray' })
    foreach ($s in (@($Result.SkippedItems) | Select-Object -First 3)) {
        Write-Host ("    - {0}: {1}" -f (Get-DisplayText $s.Target 46), $s.Reason) -ForegroundColor DarkYellow
    }

    $errCount = @($Result.Errors).Count
    Write-Host ("  Errors      : {0}" -f $errCount) -ForegroundColor $(if ($errCount -gt 0) { 'Red' } else { 'Gray' })
    foreach ($e in (@($Result.Errors) | Select-Object -First 3)) {
        Write-Host ("    - {0}: {1}" -f (Get-DisplayText $e.Path 46), $e.Error) -ForegroundColor Red
    }
    Write-Host $rule -ForegroundColor DarkGray
}

function Test-IsWSL {
    try {
        $isWSL = Get-Process -Name 'wsl' -EA SilentlyContinue
        Write-Verbose "Test-IsWSL: probing WSL environment"
        if ($isWSL) { return $true } else { return $false }
    } catch {
        Write-Verbose "Test-IsWSL: could not probe, assuming Windows"
        return $false
    }
}

function Convert-ToWindowsPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return $Path.Replace('/', '\')
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$SelectedMode)
    $hostExe = $null
    $pwsh = Get-Command pwsh.exe -ErrorAction Ignore
    if ($pwsh) { $hostExe = $pwsh.Source }
    else {
        $winPs = Get-Command powershell.exe -ErrorAction Ignore
        if ($winPs) { $hostExe = $winPs.Source }
    }
    if (-not $hostExe) {
        Write-Host 'PowerShell executable not found. Elevation requires powershell.exe or pwsh.exe.' -ForegroundColor Red
        return $false
    }
    $entry = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'Bakunawa.ps1' }
    # Single pre-quoted string: PowerShell 5.1 Start-Process mangles ArgumentList arrays on join.
    $cmd = "-NoProfile -ExecutionPolicy Bypass -File `"$entry`""
    if ($SelectedMode) { $cmd += " -Mode $SelectedMode" }
    if ($ForceAdmin) { $cmd += ' -ForceAdmin' }
    if ($NoAnimations) { $cmd += ' -NoAnimations' }
    if ($VerboseScan) { $cmd += ' -VerboseScan' }
    if ($ExtraExcludePath) { $cmd += ' -ExtraExcludePath ' + ($ExtraExcludePath -join ',') }
    if ($LogFile) { $cmd += " -LogFile `"$LogFile`"" }
    if ($Profile) { $cmd += " -Profile `"$Profile`"" }
    Write-Host ''
    Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $cmd | Out-Null
        return $true
    } catch {
        Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

if (-not $SkipBootstrap) {
    # Validate mode against allowed values
    $validModes = @('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')
    if ($Mode -notin $validModes) {
        Write-Host "Invalid mode: '$Mode'. Valid modes: $($validModes -join ', ')" -ForegroundColor Red
        exit 1
    }

    # Admin check for modes that require it (Menu requires admin for cleanup actions)
    $needsAdmin = $Mode -in @('Menu','Standard','Aggressive','Scan') -and -not (Test-IsAdministrator) -and -not $ForceAdmin
    if ($needsAdmin) {
        Write-Host "$Mode mode requires administrator privileges for full system access." -ForegroundColor Yellow
        if (-not (Restart-Elevated -SelectedMode $Mode)) {
            Write-Host ''
            Write-Host 'Automatic elevation failed. Without admin rights, system-level cleanup fails with "Access is denied".' -ForegroundColor Red
            Write-Host 'Fix: right-click PowerShell, choose "Run as administrator", then run Bakunawa again.' -ForegroundColor Yellow
            Write-Host '      (Your account must be in the local Administrators group and UAC must be enabled.)' -ForegroundColor Yellow
            exit 1
        }
        exit 0
    }

    # Profile handling with validation
    if ($Profile) {
        $profilePath = Join-Path $PSScriptRoot "profiles\$Profile.json"
        if (Test-Path -LiteralPath $profilePath) {
            try {
                $profileConfig = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($profileConfig.mode) {
                    if ($profileConfig.mode -in $validModes) {
                        $Mode = $profileConfig.mode
                    } else {
                        Write-Host "Profile specifies invalid mode: '$($profileConfig.mode)'. Using '$Mode'." -ForegroundColor Yellow
                    }
                }
                if ($profileConfig.aggressive -and $profileConfig.aggressive.enabled) { $script:IsAggressive = $true }
            } catch {
                Write-Host "Failed to load profile '$Profile': $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "Profile file not found: $profilePath" -ForegroundColor Red
            exit 1
        }
    }

    if ($VerboseScan) { $script:VerboseScan = $true }
    if ($ExtraExcludePath) { $script:ExtraExcludePaths = $ExtraExcludePath }
    
    # Validate and set log file path (explicit single-writer contract via UI module)
    if ($LogFile) {
        try {
            $null = Initialize-UiLogging -Path $LogFile
        } catch {
            Write-Host "Invalid log file path: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    # Initialize config module with default path
    $configPath = Join-Path $env:APPDATA 'Bakunawa\config.json'
    Initialize-ConfigModule -ConfigPath $configPath

    $config = Get-UserConfig -ConfigPath $configPath -UseDefault
    $extraExclusions = @()
    if ($config.extraExcludePaths) { $extraExclusions += $config.extraExcludePaths }
    if ($script:ExtraExcludePaths) { $extraExclusions += $script:ExtraExcludePaths }

    $null = Initialize-CoreSafetyState -ExtraExcludePath $extraExclusions

    Initialize-Quarantine | Out-Null
    Clear-ExpiredQuarantine | Out-Null

    switch ($Mode) {
        'Standard'   { Show-RunSummary (Invoke-CleanupRun -Mode 'Standard') }
        'Aggressive' { Show-RunSummary (Invoke-CleanupRun -Mode 'Aggressive') }
        'Preview'    { Show-RunSummary (Invoke-CleanupRun -Mode 'Preview' -WhatIf) }
        'Scan'       {
            Show-Header
            $script:IsPreview = $false
            Start-Step 'Orphan scan'
            $o = Invoke-OrphanScan
            Show-OrphanScanResults $o
            Write-Host ''
            [void](Read-Host '[Press Enter to return to Menu]')
        }
        'Health'     {
            Show-Header
            Show-HealthDetail
            Write-Host ''
            [void](Read-Host '[Press Enter to return to Menu]')
        }
'Benchmark'  {
            Show-Header
            Write-Log 'Running performance benchmark...' 'INFO'
            Write-Log 'This will scan all cleanup categories without deleting anything.' 'INFO'
            Write-Host ''
            
            $totalSb = [System.Diagnostics.Stopwatch]::StartNew()
            $categoryTimes = @{}
            
            $tasks = Get-CleanupTasks -Mode 'Standard'
            foreach ($task in $tasks) {
                $taskSb = [System.Diagnostics.Stopwatch]::StartNew()
                $potential = Get-CleanupPotential -Mode 'Standard' | Where-Object { $_.Task -eq $task.Name }
                $taskSb.Stop()
                $categoryTimes[$task.Name] = [math]::Round($taskSb.Elapsed.TotalMilliseconds, 2)
                if ($potential) {
                    Write-Log "  [$task.Name] ${categoryTimes[$task.Name]}ms - Potential: $(Format-FileSize $potential.Bytes) ($($potential.Count) locations)" 'SCAN'
                } else {
                    Write-Log "  [$task.Name] ${categoryTimes[$task.Name]}ms - No data" 'SCAN'
                }
            }
            
            $totalSb.Stop()
            $totalMs = [math]::Round($totalSb.Elapsed.TotalMilliseconds, 2)
            
            Write-Host ''
            Write-Log "=== BENCHMARK SUMMARY ===" 'STEP'
            Write-Log "Total time: ${totalMs}ms ($([math]::Round($totalSb.Elapsed.TotalSeconds, 2))s)" 'OK'
            Write-Log "Categories scanned: $($tasks.Count)" 'INFO'
            
            # Show top 5 slowest categories
            $sorted = $categoryTimes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
            foreach ($entry in $sorted) {
                Write-Log "  $($entry.Key): $($entry.Value)ms" 'SIZE'
            }
            
            # Performance rating
            $rating = if ($totalMs -lt 500) { 'EXCELLENT' }
            elseif ($totalMs -lt 2000) { 'GOOD' }
            elseif ($totalMs -lt 5000) { 'FAIR' }
            else { 'SLOW' }
            Write-Log "Performance rating: $rating" 'OK'
            
            Write-Host ''
            [void](Read-Host '[Press Enter to return to Menu]')
        }
        default      { Show-Menu }
    }

    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
}
