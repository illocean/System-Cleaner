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
$Host.UI.RawUI.WindowTitle = 'Bakunawa v3'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
foreach ($mod in @('Core','Config','Cleanup','UI')) {
    $modPath = Join-Path $scriptDir "Bakunawa.$mod.psm1"
    if (Test-Path -LiteralPath $modPath) { Import-Module $modPath -Force -Scope Global -ErrorAction Stop }
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

if ($SkipBootstrap) { return }

if (-not (Test-IsAdministrator)) {
    if (Restart-Elevated -SelectedMode $Mode) { exit 0 }
    if (-not $NoPause) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit 1
}

switch ($Mode) {
    'Standard'   { Invoke-CleanupRun 'Standard';   if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Aggressive' { Invoke-CleanupRun 'Aggressive'; if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    'Preview'    { Invoke-CleanupRun 'Preview';    if(-not $NoPause){Write-Host '';[void](Read-Host 'Press Enter to close')} }
    default      { Show-Menu }
}