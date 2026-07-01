[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview')]
    [string]$Mode = 'Menu',
    [string[]]$ExtraExcludePath = @(),
    [switch]$NoPause,
    [switch]$SkipBootstrap,
    [string]$LogFile = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Variable -Name ErrorActionPreference -Value 'SilentlyContinue' -Scope Script
$Host.UI.RawUI.WindowTitle = 'Bakunawa v3'

# ── Detect WSL ──
function Test-IsWSL {
    try {
        if (Test-Path /proc/version) {
            $ver = Get-Content /proc/version -EA SilentlyContinue
            if ($ver -match 'Microsoft|WSL') { return $true }
        }
    } catch {}
    return $false
}

# ── Resolve script path (works from WSL and native Windows) ──
$script:ThisScriptPath = $null
if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    $script:ThisScriptPath = $PSCommandPath
} elseif ($PSScriptRoot) {
    $candidate = Join-Path $PSScriptRoot 'Bakunawa.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:ThisScriptPath = $candidate }
}
if (-not $script:ThisScriptPath) {
    $candidate = Join-Path (Get-Location).Path 'Bakunawa.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:ThisScriptPath = $candidate }
}

# ── Convert any path to a Windows path ──
function Convert-ToWindowsPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    # WSL /mnt/c/... -> C:\...
    if ($Path -match '^/mnt/([a-zA-Z])/(.*)') {
        $drive = $Matches[1].ToUpper()
        $rest  = $Matches[2] -replace '/', '\'
        return "${drive}:\${rest}"
    }
    # Already Windows path
    if ($Path -match '^[A-Za-z]:\\') { return $Path }
    # Try wslpath if available
    try {
        $converted = & wslpath -w $Path 2>$null
        if ($converted) { return $converted }
    } catch {}
    return $Path
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$SelectedMode)
    if (-not $script:ThisScriptPath) {
        Write-Host 'ERROR: Cannot resolve script path for elevation.' -ForegroundColor Red
        return $false
    }

    $winPath = Convert-ToWindowsPath $script:ThisScriptPath
    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$winPath`""
    if ($SelectedMode) { $argStr += " -Mode $SelectedMode" }
    if ($NoPause) { $argStr += ' -NoPause' }

    if (Test-IsWSL) {
        # From WSL: launch Windows PowerShell that elevates via UAC
        $wslElevate = "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"$winPath`""
        if ($SelectedMode) { $wslElevate += " -Mode $SelectedMode" }
        if ($NoPause) { $wslElevate += ' -NoPause' }
        $wslElevate += "'"
        try {
            Write-Host ''
            Write-Host 'Launching elevated instance via Windows...' -ForegroundColor Yellow
            $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -Command `"$wslElevate`"" -PassThru
            return $true
        } catch {
            Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    } else {
        # Native Windows: direct UAC elevation
        $exe = 'powershell.exe'
        if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { $exe = 'pwsh.exe' }
        try {
            Write-Host ''
            Write-Host 'Requesting administrator privileges...' -ForegroundColor Yellow
            Start-Process $exe -Verb RunAs -ArgumentList $argStr | Out-Null
            return $true
        } catch {
            Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# ── Auto-elevate ──
if (-not $SkipBootstrap -and -not (Test-IsAdministrator)) {
    if (Restart-Elevated -SelectedMode $Mode) { exit 0 }
    if (-not $NoPause) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit 1
}

# ── Bootstrap modules (order matters: Core -> UI -> Config -> Cleanup) ──
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$moduleDir = Join-Path $scriptDir 'src'
foreach ($mod in @('Core','UI','Config','Cleanup')) {
    $modPath = Join-Path $moduleDir "Bakunawa.$mod.psm1"
    if (Test-Path -LiteralPath $modPath) { $null = Import-Module $modPath -Force -Scope Global -ErrorVariable +modErr; if ($modErr) { throw "Failed to import module: $modPath" } }
    else { Write-Error "Missing module: $modPath"; exit 1 }
}

$script:SysLoc = Get-SystemLocations
$config = Get-BakunawaConfig
$mergedExclusions = Merge-Exclusions -ConfigPaths $config.extraExcludePaths -CliPaths $ExtraExcludePath
$script:ExcludedPaths = Get-ExcludedPaths -ExtraExcludePath $mergedExclusions
$script:RunningProcesses = Get-RunningProcessNames
$script:SpinnerFrames = @('|','/','-','\')
$script:SpinnerIndex = 0
$script:UiStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastUiMs = [long]0
$script:UiTickMs = 250

if ($LogFile) {
    $script:LogFilePath = Resolve-FullPath $LogFile
    if (-not $script:LogFilePath) { $script:LogFilePath = $LogFile }
    try {
        $header = "# Bakunawa v3 log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Mode: $Mode"
        Set-Content -LiteralPath $script:LogFilePath -Value $header -Encoding UTF8 -EA SilentlyContinue
    } catch { $script:LogFilePath = '' }
}

# $SkipBootstrap handled above — modules loaded, proceed to dispatch

switch ($Mode) {
    'Standard'   { Invoke-CleanupRun 'Standard';   if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Aggressive' { Invoke-CleanupRun 'Aggressive'; if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Preview'    { Invoke-CleanupRun 'Preview';    if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    default      { Show-Menu }
}
