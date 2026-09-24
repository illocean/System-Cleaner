# Bakunawa.Quarantine.psm1 — Quarantine engine with manifest tracking and 14-day retention

$script:QuarantineRoot = $null
$script:QuarantineRetentionDays = 14

function Get-QuarantineRoot {
    [CmdletBinding()]
    param()
    if ($script:QuarantineRoot) { return $script:QuarantineRoot }
    $cfg = Get-UserConfig
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
    $cfg = Get-UserConfig
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
    if (-not [Bakunawa.Scanner]::IsAllowedPath($root)) { throw 'Quarantine must be on C: without reparse points.' }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    $manifestDir = Join-Path $root 'Manifests'
    if (-not [Bakunawa.Scanner]::IsAllowedPath($manifestDir)) { throw 'Unsafe quarantine manifest directory.' }
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
        Status            = 'Pending'
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

    $root = Get-QuarantineRoot
    $resolvedPath = Resolve-FullPath $Path
    if (-not [Bakunawa.Scanner]::IsAllowedPath($Path) -or -not [Bakunawa.Scanner]::IsAllowedPath($root)) {
        throw 'Quarantine source and destination must be on C: without reparse points.'
    }
    if (-not $resolvedPath -or -not (Test-Path -LiteralPath $resolvedPath)) {
        return $null
    }

    if ($resolvedPath -eq [IO.Path]::GetPathRoot($resolvedPath).TrimEnd('\')) { throw 'Cannot quarantine a drive root.' }
    $measurement = [Bakunawa.Scanner]::Inspect($resolvedPath, [string[]](@(Get-CoreExcludedPaths) + @($root)))

    $size = $measurement.Bytes

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
        $null = Initialize-Quarantine
        New-Item -ItemType Directory -Path $quarantineSubDir -Force | Out-Null
        # Persist recovery information BEFORE moving data. Never delete payload on failure.
        $manifest.QuarantinedPath = $quarantineTarget
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $resolvedPath -Destination $quarantineTarget -Force -EA Stop
        $manifest.Status = 'Complete'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
        return $manifest
    } catch {
        throw "Quarantine failed; any recovery data and manifest were retained: $($_.Exception.Message)"
    }
}

function Restore-QuarantinedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string]$QuarantineId,
        [AllowEmptyString()][string]$DestinationPath
    )

    $root = Get-QuarantineRoot
    if (-not $root) { throw 'Quarantine root not initialized' }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($root)) { throw 'Quarantine must be on C: without reparse points.' }

    $manifestDir = Join-Path $root 'Manifests'
    $manifestPath = Join-Path $manifestDir "$QuarantineId.json"
    if (-not [Bakunawa.Scanner]::IsAllowedPath($manifestPath)) { throw 'Unsafe quarantine manifest path.' }

    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.Restored) { return $false }

    $sourcePath = $manifest.QuarantinedPath
    if (-not (Test-Path -LiteralPath $sourcePath)) { return $false }
    $payloadRoot = Join-Path $root $QuarantineId
    if (-not [Bakunawa.Scanner]::Within([IO.Path]::GetFullPath($sourcePath), $payloadRoot)) { throw 'Invalid quarantine payload path.' }
    $null = [Bakunawa.Scanner]::Inspect($sourcePath, [string[]]@())

    $targetPath = $DestinationPath
    if (-not $targetPath) { $targetPath = $manifest.OriginalPath }
    if (-not [Bakunawa.Scanner]::IsAllowedPath($targetPath)) { throw 'Restore destination must be on C: without reparse points.' }
    if (Test-Path -LiteralPath $targetPath) { throw 'Restore destination already exists. Choose an empty destination.' }

    try {
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Move-Item -LiteralPath $sourcePath -Destination $targetPath -EA Stop
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
    if (-not [Bakunawa.Scanner]::IsAllowedPath($root) -or -not [Bakunawa.Scanner]::IsAllowedPath((Join-Path $root 'Manifests')) -or -not (Test-Path -LiteralPath $root)) { return 0 }

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
        if (-not [Bakunawa.Scanner]::IsAllowedPath($_.FullName)) { return }
        $manifestPath = $_.FullName
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $quarantineTime = [DateTime]::Parse($manifest.Timestamp)
            if ($quarantineTime -lt $cutoff -and -not $manifest.Restored -and $manifest.Status -ne 'Pending') {
                if ($manifest.QuarantineId -notmatch '^[a-fA-F0-9]{32}$') { throw 'Invalid quarantine ID.' }
                $quarantineSubDir = Join-Path $root $manifest.QuarantineId
                if (Test-Path -LiteralPath $quarantineSubDir) {
                    $null = [Bakunawa.Scanner]::Inspect($quarantineSubDir, [string[]]@())
                    Remove-Item -LiteralPath $quarantineSubDir -Recurse -Force -EA Stop
                }
                Remove-Item -LiteralPath $manifestPath -Force -EA Stop
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
    if (-not [Bakunawa.Scanner]::IsAllowedPath($root) -or -not [Bakunawa.Scanner]::IsAllowedPath((Join-Path $root 'Manifests')) -or -not (Test-Path -LiteralPath $root)) { return @() }

    $manifestDir = Join-Path $root 'Manifests'
    if (-not (Test-Path -LiteralPath $manifestDir)) { return @() }

    $items = @()
    Get-ChildItem -LiteralPath $manifestDir -Filter '*.json' -File -Force -EA SilentlyContinue | ForEach-Object {
        if (-not [Bakunawa.Scanner]::IsAllowedPath($_.FullName)) { return }
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
