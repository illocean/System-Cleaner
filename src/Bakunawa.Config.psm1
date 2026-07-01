# Bakunawa.Config.psm1 - Configuration I/O

$script:AppDefinitionsDir = $null
$script:ConfigFilePath = $null

function Resolve-EnvTemplate {
    param(
        [string]$EnvVar,
        [string]$SubPath
    )
    $base = [Environment]::ExpandEnvironmentVariables("%$EnvVar%")
    if ([string]::IsNullOrWhiteSpace($base) -or $base -eq "%$EnvVar%") { return $null }
    if ([string]::IsNullOrWhiteSpace($SubPath)) { return $base }
    try {
        $full = [System.IO.Path]::GetFullPath((Join-Path $base $SubPath))
        return $full
    } catch { return $null }
}

function Get-AppDefinitions {
    param([string]$Category)
    $dir = $script:AppDefinitionsDir
    if (-not $dir) {
        $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        # Modules live in src/ — app-definitions is at the project root
        if ((Split-Path -Leaf $scriptPath) -eq 'src') { $scriptPath = Split-Path $scriptPath -Parent }
        $dir = Join-Path $scriptPath 'app-definitions'
        $script:AppDefinitionsDir = $dir
    }
    $file = Join-Path $dir "$Category.json"
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
        if (-not $raw) { return @() }
        $defs = $null
        if ([bool]('System.Text.Json.JsonSerializer' -as [type])) {
            $defs = [System.Text.Json.JsonSerializer]::Deserialize($raw, [System.Collections.Generic.List[System.Object]])
        } else {
            $defs = ConvertFrom-Json $raw -EA Stop
        }
        if (-not $defs) { return @() }
        return @($defs)
    } catch {
        Write-Verbose "Get-AppDefinitions($Category): $_"
        return @()
    }
}

function Get-AllAppDefinitions {
    $all = [System.Collections.Generic.List[System.Object]]::new()
    foreach ($cat in @('browsers', 'messaging', 'devtools', 'system', 'apps', 'games', 'cloud', 'creative', 'productivity', 'devops')) {
        $defs = Get-AppDefinitions -Category $cat
        foreach ($d in $defs) { $all.Add($d) }
    }
    return @($all)
}

function Get-BakunawaConfig {
    param([switch]$ForceReload)
    $cfgPath = $script:ConfigFilePath
    if (-not $cfgPath) {
        $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        if ((Split-Path -Leaf $scriptPath) -eq 'src') { $scriptPath = Split-Path $scriptPath -Parent }
        $cfgPath = Join-Path $scriptPath 'Bakunawa.json'
        $script:ConfigFilePath = $cfgPath
    }
    $defaults = @{
        mode = 'Menu'
        extraExcludePaths = @()
        orphanThresholdDays = 30
        logRetention = 7
        parallel = $true
        uiStyle = 'auto'
    }
    if (-not $ForceReload -and $script:CachedConfig) { return $script:CachedConfig }
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
            $userConfig = ConvertFrom-Json $raw -EA Stop
            foreach ($key in $defaults.Keys) {
                if (-not ($userConfig.PSObject.Properties.Name -contains $key)) {
                    $userConfig | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
                }
            }
            $script:CachedConfig = $userConfig
            return $userConfig
        } catch { Write-Verbose "Get-BakunawaConfig: $_" }
    }
    $script:CachedConfig = [PSCustomObject]$defaults
    return $script:CachedConfig
}

function Merge-Exclusions {
    param([string[]]$ConfigPaths, [string[]]$CliPaths)
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ConfigPaths) { if ($p) { [void]$set.Add($p) } }
    foreach ($p in $CliPaths) { if ($p) { [void]$set.Add($p) } }
    return @($set)
}

Export-ModuleMember -Function Resolve-EnvTemplate, Get-AppDefinitions, Get-AllAppDefinitions, Get-BakunawaConfig, Merge-Exclusions
