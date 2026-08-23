# Bakunawa.Quarantine.psm1 — Quarantine engine with manifest tracking and 14-day retention

$script:QuarantineRoot = $null
$script:QuarantineRetentionDays = 14

function Get-QuarantineRoot {
    [CmdletBinding()]
    param()
    if ($script:QuarantineRoot) { return $script:QuarantineRoot }
    $cfg = Get-UserConfig -UseDefault
    $customRoot = if ($cfg.behaviorSettings.quarantineBeforeDelete) { $cfg.quarantineRoot } else { $null }
    if ($customRoot) {
        $resolved = Resolve-FullPath $customRoot
        if ($resolved) {
            $script:QuarantineRoot = $resolved
            return $resolved
        }
    }
    $localAppData = Get-EnvPath 'LOCALAPPDATA'
    if ($localAppData) {
        $script:QuarantineRoot = Join-Path $localAppData 'Bakunawa\Quarantine'
        return $script:QuarantineRoot
    }
    return $null
}

function Get-QuarantineRetentionDays {
    [CmdletBinding()]
    param()
    $cfg = Get-UserConfig -UseDefault
    $retention = $cfg.behaviorSettings.deleteQuarantineAfterDays
    if ($retention -and [int]::TryParse($retention, [ref]0)) {
        $script:QuarantineRetentionDays = $retention
    }
    return $script:QuarantineRetentionDays
}

function Initialize-Quarantine {
    [CmdletBinding()]
    param()
    $root = Get-QuarantineRoot
    if (-not $root) { throw 'Quarantine root could not be resolved' }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $manifestDir = Join-Path $root 'Manifests'
    if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    }
    return $root
}

function New-QuarantineManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OriginalPath,
        [Parameter(Mandatory)][ValidateNotNull()][long]$SizeBytes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [Parameter(Mandatory)][ValidateSet('Tier1','Tier2','Tier3')][string]$Tier,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DetectorName
    )
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $guid = [Guid]::NewGuid().ToString('N')
    $manifestName = "{0}_{1}.json" -f $timestamp, $guid.Substring(0, 8)
    $manifest = [PSCustomObject]@{
        QuarantineId      = $guid
        OriginalPath      = $OriginalPath
        OriginalPathLower = $OriginalPath.ToLowerInvariant()
        SizeBytes         = $SizeBytes
        Reason            = $Reason
        Tier              = $Tier
        DetectorName      = $DetectorName
        Timestamp         = (Get-Date).ToString('o')
        QuarantinedPath   = $null
        Restored          = $false
        RestoredAt        = $null
    }
    return $manifest
}

function Move-ItemToQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [ValidateSet('Tier1','Tier2','Tier3')][string]$Tier = 'Tier2',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DetectorName,
        [switch]$WhatIf
    )

    $root = Initialize-Quarantine
    $resolvedPath = Resolve-FullPath $Path
    if (-not $resolvedPath -or -not (Test-Path -LiteralPath $resolvedPath)) {
        return $null
    }

    if (Test-IsExcludedPath $resolvedPath) {
        return $null
    }

    $size = 0
    try {
        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
            $size = (Get-Item -LiteralPath $resolvedPath -EA SilentlyContinue).Length
        } else {
            $size = Get-DirectorySize $resolvedPath
        }
    } catch {}

    $manifest = New-QuarantineManifest -OriginalPath $resolvedPath -SizeBytes $size -Reason $Reason -Tier $Tier -DetectorName $DetectorName
    $manifestDir = Join-Path $root 'Manifests'
    $manifestPath = Join-Path $manifestDir "$($manifest.QuarantineId).json"

    $quarantineSubDir = Join-Path $root $manifest.QuarantineId
    $quarantineTarget = Join-Path $quarantineSubDir (Split-Path -Leaf $resolvedPath)

    if ($WhatIf) {
        $manifest.QuarantinedPath = $quarantineTarget
        return $manifest
    }

    try {
        New-Item -ItemType Directory -Path $quarantineSubDir -Force | Out-Null
        Move-Item -LiteralPath $resolvedPath -Destination $quarantineTarget -Force -EA Stop
        $manifest.QuarantinedPath = $quarantineTarget
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        return $manifest
    } catch {
        if (Test-Path -LiteralPath $quarantineSubDir) { Remove-Item -LiteralPath $quarantineSubDir -Recurse -Force -EA SilentlyContinue }
        return $null
    }
}

function Restore-QuarantinedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$QuarantineId,
        [AllowEmptyString()][string]$DestinationPath
    )

    $root = Get-QuarantineRoot
    if (-not $root) { throw 'Quarantine root not initialized' }

    $manifestDir = Join-Path $root 'Manifests'
    $manifestPath = Join-Path $manifestDir "$QuarantineId.json"

    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.Restored) { return $false }

    $sourcePath = $manifest.QuarantinedPath
    if (-not (Test-Path -LiteralPath $sourcePath)) { return $false }

    $targetPath = $DestinationPath
    if (-not $targetPath) { $targetPath = $manifest.OriginalPath }

    try {
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force -EA Stop
        $manifest.Restored = $true
        $manifest.RestoredAt = (Get-Date).ToString('o')
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Clear-ExpiredQuarantine {
    [CmdletBinding()]
    param([ValidateRange(0, 3650)][int]$RetentionDays = 0)
    if ($RetentionDays -le 0) { $RetentionDays = Get-QuarantineRetentionDays }

    $root = Get-QuarantineRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return 0 }

    # ponytail: the purge walk parses every manifest (GUID-named, no timestamp in the name)
    # and cost 16s with thousands of items; it only ever needs to run once per day.
    $stampFile = Join-Path $root '.last-expiry-check'
    if (Test-Path -LiteralPath $stampFile) {
        try {
            $lastCheck = [datetime]::Parse((Get-Content -LiteralPath $stampFile -Raw -EA SilentlyContinue))
            if ($lastCheck.Date -ge (Get-Date).Date) { return 0 }
        } catch {}
    }

    $manifestDir = Join-Path $root 'Manifests'
    if (-not (Test-Path -LiteralPath $manifestDir)) { return 0 }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $removed = 0

    Get-ChildItem -LiteralPath $manifestDir -Filter '*.json' -File -Force -EA SilentlyContinue | ForEach-Object {
        $manifestPath = $_.FullName
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $quarantineTime = [DateTime]::Parse($manifest.Timestamp)
            if ($quarantineTime -lt $cutoff -and -not $manifest.Restored) {
                $quarantineSubDir = Join-Path $root $manifest.QuarantineId
                if (Test-Path -LiteralPath $quarantineSubDir) {
                    Remove-Item -LiteralPath $quarantineSubDir -Recurse -Force -EA SilentlyContinue
                }
                Remove-Item -LiteralPath $manifestPath -Force -EA SilentlyContinue
                $removed++
            }
        } catch {}
    }
    Set-Content -LiteralPath $stampFile -Value ((Get-Date).ToString('o')) -Encoding UTF8 -EA SilentlyContinue
    return $removed
}

function Get-QuarantineInventory {
    [CmdletBinding()]
    param()
    $root = Get-QuarantineRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return @() }

    $manifestDir = Join-Path $root 'Manifests'
    if (-not (Test-Path -LiteralPath $manifestDir)) { return @() }

    $items = @()
    Get-ChildItem -LiteralPath $manifestDir -Filter '*.json' -File -Force -EA SilentlyContinue | ForEach-Object {
        try {
            $manifest = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $items += $manifest
        } catch {}
    }
    return @($items | Sort-Object { [DateTime]::Parse($_.Timestamp) } -Descending)
}

function Remove-OrphanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [ValidateSet('Tier1','Tier2','Tier3')][string]$Tier = 'Tier2',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DetectorName,
        [switch]$WhatIf
    )

    if ($script:IsPreview -or $WhatIf) {
        return Move-ItemToQuarantine -Path $Path -Reason $Reason -Tier $Tier -DetectorName $DetectorName -WhatIf
    }

    if ($Tier -eq 'Tier3') {
        return Move-ItemToQuarantine -Path $Path -Reason $Reason -Tier $Tier -DetectorName $DetectorName -WhatIf
    }

    return Move-ItemToQuarantine -Path $Path -Reason $Reason -Tier $Tier -DetectorName $DetectorName
}

Export-ModuleMember -Function Get-QuarantineRoot, Get-QuarantineRetentionDays, Initialize-Quarantine, New-QuarantineManifest, Move-ItemToQuarantine, Restore-QuarantinedItem, Clear-ExpiredQuarantine, Get-QuarantineInventory, Remove-OrphanItem
