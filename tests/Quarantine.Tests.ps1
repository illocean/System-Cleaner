#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.Quarantine.psm1
Contract locked by deepwork Phase 4:
  - Quarantine round-trip: move -> manifest written -> restore -> manifest updated
  - Choke point: excluded paths are refused BEFORE any move
  - WhatIf/Tier3 never touch disk
  - Retention purge honors manifests and the daily stamp file
Uses the real default quarantine root (LOCALAPPDATA\Bakunawa\Quarantine); cleans up after itself.
#>

BeforeAll {
    $script:Src = Join-Path $PSScriptRoot '..\src'
    function script:Reset-QuarantineStack {
        Remove-Module Bakunawa.Quarantine -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Config     -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.UI         -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Core       -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Core.psm1')       -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Config.psm1')     -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.UI.psm1')         -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Quarantine.psm1') -Force -WarningAction SilentlyContinue
        $null = Initialize-CoreSafetyState
        $script:QRoot = Initialize-Quarantine
    }
}

Describe 'Bakunawa.Quarantine: initialization and manifests' {

    BeforeAll { script:Reset-QuarantineStack }

    It 'Initialize-Quarantine returns an existing container with a Manifests dir' {
        Test-Path -LiteralPath $QRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $QRoot 'Manifests') -PathType Container | Should -BeTrue
    }

    It 'New-QuarantineManifest produces the full tracked shape' {
        $m = New-QuarantineManifest -OriginalPath 'C:\Some\Target' -SizeBytes 1234 -Reason 'test' -Tier 'Tier2' -DetectorName 'Pester'
        $m.QuarantineId      | Should -Not -BeNullOrEmpty
        $m.OriginalPath      | Should -Be 'C:\Some\Target'
        $m.OriginalPathLower | Should -Be 'c:\some\target'
        $m.SizeBytes         | Should -Be 1234
        $m.Restored          | Should -BeFalse
        $m.QuarantinedPath   | Should -BeNullOrEmpty
        { New-QuarantineManifest -OriginalPath '' -SizeBytes 0 -Reason 'x' -Tier 'Tier1' -DetectorName 'P' } |
            Should -Throw -Because 'empty OriginalPath must be rejected by validation'
    }
}

Describe 'Bakunawa.Quarantine: move and restore round-trip' {

    BeforeEach {
        script:Reset-QuarantineStack
        $script:VictimDir = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $VictimDir | Out-Null
        Set-Content -LiteralPath (Join-Path $VictimDir 'data.txt') -Value 'precious'
    }

    It 'moves an item to quarantine, writes a manifest, and restores it intact' {
        $m = Move-ItemToQuarantine -Path $VictimDir -Reason 'pester' -Tier 'Tier2' -DetectorName 'Pester'
        $m | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $VictimDir | Should -BeFalse -Because 'original must be gone after move'
        Test-Path -LiteralPath $m.QuarantinedPath | Should -BeTrue

        $manifestFile = Join-Path $QRoot ("Manifests\{0}.json" -f $m.QuarantineId)
        Test-Path -LiteralPath $manifestFile | Should -BeTrue

        $ok = Restore-QuarantinedItem -QuarantineId $m.QuarantineId
        $ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $VictimDir 'data.txt') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $VictimDir 'data.txt') | Should -Be 'precious'

        $updated = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        $updated.Restored | Should -BeTrue
    }

    It 'WhatIf returns the plan without touching disk' {
        $m = Move-ItemToQuarantine -Path $VictimDir -Reason 'pester' -Tier 'Tier2' -DetectorName 'Pester' -WhatIf
        $m | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $VictimDir | Should -BeTrue -Because 'WhatIf must not move anything'
        Test-Path -LiteralPath $m.QuarantinedPath | Should -BeFalse
    }

    It 'refuses excluded paths before any move (choke point precedence)' {
        $null = Initialize-CoreSafetyState -ExtraExcludePath @($VictimDir)
        try {
            $m = Move-ItemToQuarantine -Path $VictimDir -Reason 'pester' -Tier 'Tier2' -DetectorName 'Pester'
            $m | Should -BeNullOrEmpty
            Test-Path -LiteralPath $VictimDir | Should -BeTrue
        } finally {
            $null = Initialize-CoreSafetyState
        }
    }

    It 'Remove-OrphanItem Tier3 plans but never deletes without explicit execute' {
        $m = Remove-OrphanItem -Path $VictimDir -Reason 'orphan' -Tier 'Tier3' -DetectorName 'Pester'
        $m | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $VictimDir | Should -BeTrue -Because 'Tier3 requires explicit confirmation flow'
    }
}

Describe 'Bakunawa.Quarantine: retention and inventory' {

    BeforeEach { script:Reset-QuarantineStack }

    It 'Get-QuarantineInventory returns array without throwing on empty/real root' {
        { $null = Get-QuarantineInventory } | Should -Not -Throw
    }

    It 'Clear-ExpiredQuarantine purges stale manifests, keeps fresh ones, respects daily stamp' {
        # Craft one stale + one fresh quarantined item directly in the real root
        function script:New-FakeQuarantined([string]$ageDays) {
            $id = [Guid]::NewGuid().ToString('N')
            $sub = Join-Path $QRoot $id
            New-Item -ItemType Directory -Path $sub | Out-Null
            Set-Content -LiteralPath (Join-Path $sub 'blob.bin') -Value 'z'
            $ts = (Get-Date).AddDays(-$ageDays).ToString('o')
            $manifest = @{ QuarantineId = $id; OriginalPath = "$sub-orig"; OriginalPathLower = "$sub-orig";
                          SizeBytes = 1; Reason = 'pester'; Tier = 'Tier2'; DetectorName = 'Pester';
                          Timestamp = $ts; QuarantinedPath = (Join-Path $sub 'blob.bin');
                          Restored = $false; RestoredAt = $null }
            $json = $manifest | ConvertTo-Json
            Set-Content -LiteralPath (Join-Path $QRoot "Manifests\$id.json") -Value $json -Encoding UTF8
            return $id
        }
        $staleId = New-FakeQuarantined 30
        $freshId = New-FakeQuarantined 0

        # Daily stamp would suppress the purge; contract says stamp suppresses SAME-DAY reruns,
        # so remove it to force evaluation.
        Remove-Item -LiteralPath (Join-Path $QRoot '.last-expiry-check') -Force -ErrorAction SilentlyContinue
        $removed = Clear-ExpiredQuarantine -RetentionDays 14
        $removed | Should -BeGreaterOrEqual 1
        Test-Path -LiteralPath (Join-Path $QRoot $staleId) | Should -BeFalse -Because 'stale item must be purged'
        Test-Path -LiteralPath (Join-Path $QRoot "Manifests\$staleId.json") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $QRoot $freshId) | Should -BeTrue -Because 'fresh item must survive'

        # Stamp now exists -> immediate second call is a no-op
        Test-Path -LiteralPath (Join-Path $QRoot '.last-expiry-check') | Should -BeTrue
        (Clear-ExpiredQuarantine -RetentionDays 14) | Should -Be 0

        # Cleanup fresh fake
        Remove-Item -LiteralPath (Join-Path $QRoot $freshId) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $QRoot "Manifests\$freshId.json") -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Bakunawa.Quarantine: module hygiene' {

    BeforeAll { script:Reset-QuarantineStack }

    It 'every public function declares CmdletBinding' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.Quarantine.psm1') -Raw
        $funcs = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)')
        $missing = @()
        foreach ($f in $funcs) {
            $tail = $raw.Substring($f.Index, [Math]::Min(200, $raw.Length - $f.Index))
            if ($tail -notmatch '\[CmdletBinding\(\)\]') { $missing += $f.Groups[1].Value }
        }
        $missing.Count | Should -Be 0 -Because ("missing CB: " + ($missing -join ', '))
    }

    It 'explicit allowlist covers every defined function; no PS7 syntax' {
        $path = Join-Path $script:Src 'Bakunawa.Quarantine.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'Export-ModuleMember\s+-Function\s+\*'
        $raw | Should -Not -Match '-AsHashtable'
        $defined = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $exported = @(Get-Command -Module Bakunawa.Quarantine -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name) | Sort-Object -Unique
        (Compare-Object $defined $exported | Out-String) | Should -BeNullOrEmpty
    }
}
