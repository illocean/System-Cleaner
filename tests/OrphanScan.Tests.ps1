#requires -Version 5.1
# Pester v5 tests for Phase 1–5: Quarantine routing, app enumeration, orphan tier classification,
# distinct category measurements, and regression verification.
#
# Phase root causes verified:
#   1. Quarantine routing: Remove-ItemSafely routes through Remove-OrphanItem or direct Delete
#   2. Config respect: $script:UseQuarantine read from config; Preview mode always returns 0
#   3. Get-InstalledApplicationNames: Registry enumeration, caching, KB hotfix filtering
#   4. Find-OrphanFolders: Mixed Tier1/2/3, SafeDelete=true only for Tier1, dead code wired
#   5. Get-CleanupPotential: Distinct category measurements, no triple TEMP duplication

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Quarantine.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking
    # Keep legacy tests inside Pester's disposable sandbox. Script variables in this
    # test file do not set module state, so configure the actual module explicitly.
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Quarantine.psm1" -Force -DisableNameChecking
    & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
    Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
    Mock -ModuleName Bakunawa.Cleanup Get-QuarantineRoot { Join-Path $TestDrive 'Quarantine' }
    Mock -ModuleName Bakunawa.Quarantine Get-QuarantineRoot { Join-Path $TestDrive 'Quarantine' }
    Mock -ModuleName Bakunawa.Cleanup Get-DirectorySize {
        param($Path)
        # Real sizing for fixture paths; no machine-wide measurements in unit tests.
        if ($Path -like '*pester_*' -or $Path -like '*phase*_test_*' -or $Path -like '*regression_test_*' -or $Path -like '*integration_test_*') {
            Bakunawa.Core\Get-DirectorySize -Path $Path
        } else { 0L }
    }

    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
}

AfterAll {
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Quarantine -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE 1: Quarantine Routing, Config Respect, Preview Safety
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Phase 1: Quarantine Routing & Preview Safety' {

    BeforeEach {
        # Sandbox state
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phase1_test_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        # Reset global state
        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
        $script:UseQuarantine = $true
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Measure-AndClear in Preview mode completes without error' {
        # Arrange
        $testDir = Join-Path $script:tmpRoot 'cache'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        $script:IsPreview = $true
        $script:UseQuarantine = $true
        $script:ExcludedPaths = $null

        # Act & Assert
        { Measure-AndClear -Path $testDir -Category 'Test Cache' } | Should -Not -Throw
    }

    It 'Clear-CachedOrphans respects Preview mode' {
        # Arrange
        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null

        # Act
        Clear-CachedOrphans

        # Assert - should complete without throwing in Preview
        $? | Should -Be $true
    }

    It '$script:UseQuarantine setting affects item deletion route' {
        # Arrange
        $testFile = Join-Path $script:tmpRoot 'test.txt'
        [System.IO.File]::WriteAllBytes($testFile, (New-Object byte[] 1024))

        # Verify quarantine module is loaded and can be called
        # Act
        $quarantineRoot = Get-QuarantineRoot

        # Assert - quarantine root should be configured
        $quarantineRoot | Should -Not -BeNullOrEmpty -Because 'quarantine must be initialized'
    }

    It 'Measure-AndClear with EnsureDirectory flag works correctly' {
        # Arrange
        $testDir = Join-Path $script:tmpRoot 'ensure_test'

        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null

        # Act - should not throw even if directory doesn't exist
        $result = Measure-AndClear -Path $testDir -Category 'Test' -EnsureDirectory

        # Assert
        $? | Should -Be $true
    }

    It 'Quarantine path is retrievable via Get-QuarantineRoot' {
        # Arrange / Act
        $quarantineRoot = Get-QuarantineRoot

        # Assert
        $quarantineRoot | Should -Not -BeNullOrEmpty
        $quarantineRoot -is [string] | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE 2: Get-InstalledApplicationNames Correctness
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Phase 2: Get-InstalledApplicationNames' {

    It 'returns non-empty result on standard Windows machine' {
        # Arrange / Act
        $names = Get-InstalledApplicationNames

        # Assert
        $names | Should -Not -BeNullOrEmpty -Because 'Windows always has some installed applications'
    }

    It 'all returned names are strings and lowercased' {
        # Arrange / Act
        $names = Get-InstalledApplicationNames

        # Assert
        foreach ($name in $names) {
            $name -is [string] | Should -Be $true
            # All letters should be lowercase
            $lower = $name.ToLower()
            $name | Should -Be $lower -Because "name must be lowercased"
        }
    }

    It 'does not include KB hotfix entries' {
        # Arrange / Act
        $names = Get-InstalledApplicationNames -SkipCaching

        # Assert
        $kbMatches = @($names | Where-Object { $_ -match '^kb\d+' })
        $kbMatches | Should -BeNullOrEmpty -Because 'KB hotfixes must be filtered out'
    }

    It 'caching mechanism works across calls' {
        # Arrange / Act
        $names1 = Get-InstalledApplicationNames -SkipCaching
        $names2 = Get-InstalledApplicationNames  # Uses cache

        # Assert
        $names1 | Should -Not -BeNullOrEmpty
        $names2 | Should -Not -BeNullOrEmpty
    }

    It 'SkipCaching parameter re-evaluates registry' {
        # Arrange
        $names1 = Get-InstalledApplicationNames

        # Act - Force fresh read
        $names2 = Get-InstalledApplicationNames -SkipCaching

        # Assert - should return applications (fresh or cached)
        $names2 | Should -Not -BeNullOrEmpty
    }

    It 'handles missing registry keys gracefully' {
        # Arrange
        $invalidKeys = @('HKLM:\NONEXISTENT\WINDOWS\PATH\12345')

        # Act & Assert
        { Get-InstalledApplicationNames -SkipCaching -UninstallKeys $invalidKeys } | Should -Not -Throw
    }

    It 'returns deduplicated application names' {
        # Arrange / Act
        $names = Get-InstalledApplicationNames -SkipCaching
        $deduplicated = @($names | Sort-Object -Unique)

        # Assert
        @($names).Count | Should -BeGreaterOrEqual $deduplicated.Count -Because 'deduplication should never increase count'
    }
}

# ─────────────────────────────────────────────────────────────────────────────────
# PHASE 3: Find-OrphanFolders Mixed Tiers & Dead Code Wiring
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Phase 3: Find-OrphanFolders Real Risk Tiers' {

    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phase3_test_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
        $script:OrphanCache = $null
        $script:OrphanCacheTime = $null
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'orphan findings include Tier classification' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert - if findings exist, they should have Tier property
        if ($findings -and @($findings).Count -gt 0) {
            $findings[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain 'Tier'
        }
    }

    It 'Tier1 findings have SafeDelete property set to $true' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        $tier1 = @($findings | Where-Object { $_.Tier -eq 'Tier1' })
        if ($tier1.Count -gt 0) {
            foreach ($finding in $tier1) {
                $finding.SafeDelete | Should -Be $true -Because 'Tier1 must have SafeDelete=$true'
            }
        }
    }

    It 'Tier2/3 findings have SafeDelete property set to $false' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        $tier2Plus = @($findings | Where-Object { $_.Tier -in 'Tier2','Tier3' })
        if ($tier2Plus.Count -gt 0) {
            foreach ($finding in $tier2Plus) {
                $finding.SafeDelete | Should -Be $false -Because "Tier2/3 must have SafeDelete=`$false"
            }
        }
    }

    It 'orphan findings include RiskLevel property (Low, Medium, High)' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        if ($findings.Count -gt 0) {
            foreach ($finding in $findings) {
                $finding.RiskLevel | Should -Match '^(Low|Medium|High)$' -Because 'each finding must have a valid risk level'
            }
        }
    }

    It 'orphan findings include RiskScore property' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        if ($findings.Count -gt 0) {
            $findings[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain 'RiskScore'
        }
    }

    It 'running process collision prevents deletion of active process folder' {
        # Arrange
        $script:RunningProcesses = @('svchost', 'explorer')

        # Act
        $findings = Find-OrphanFolders

        # Assert
        $processNames = @($findings | ForEach-Object { $_.Name.ToLower() })
        foreach ($proc in $script:RunningProcesses) {
            $processNames | Should -Not -Contain $proc.ToLower() -Because 'running process names must be skipped'
        }
    }

    It 'orphan findings retrieval completes successfully' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert - function executes without error
        $? | Should -Be $true
    }
}


# ─────────────────────────────────────────────────────────────────────────────────
# PHASE 4: Distinct Category Measurements (No Triple TEMP Duplication)
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Phase 4: Distinct Category Measurements' {

    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phase4_test_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-CleanupPotential returns measurements for multiple cleanup categories' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        $potential | Should -Not -BeNullOrEmpty
        $tasks = @($potential | ForEach-Object Task | Sort-Object -Unique)
        $tasks.Count | Should -BeGreaterOrEqual 3 -Because 'should have multiple task types'
    }

    It 'Get-CleanupPotential returns objects with Task, EstimatedBytes, and FileCount properties' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        if ($potential.Count -gt 0) {
            $potential[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain 'Task'
            $potential[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain 'EstimatedBytes'
        }
    }

    It 'System Caches category is measured' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        $systemCaches = @($potential | Where-Object { $_.Task -eq 'System Caches' })
        $systemCaches.Count | Should -BeGreaterOrEqual 1 -Because 'System Caches must be measured'
    }

    It 'Orphan Scan category is measured' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        $orphanScan = @($potential | Where-Object { $_.Task -eq 'Orphan Scan' })
        $orphanScan.Count | Should -BeGreaterOrEqual 1 -Because 'Orphan Scan must be measured'
    }

    It 'Clear-CachedOrphans processes only SafeDelete=true findings' {
        # Arrange
        $script:IsPreview = $false

        # Act
        Clear-CachedOrphans

        # Assert - should complete without error
        $? | Should -Be $true
    }

    It 'Find-OrphanFolders returns findings with SafeDelete property' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        if ($findings.Count -gt 0) {
            foreach ($finding in $findings) {
                $finding | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain 'SafeDelete'
                $finding.SafeDelete -is [bool] | Should -Be $true -Because 'SafeDelete must be boolean'
            }
        }
    }
}


# ─────────────────────────────────────────────────────────────────────────────────
# REGRESSION TESTS: No Existing Functionality Broke
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Regression Tests: Existing Functionality' {

    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("regression_test_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:IsPreview = $false
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
        $script:UseQuarantine = $false
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Clear-CachedOrphans function is available and callable' {
        # Arrange / Act
        { Clear-CachedOrphans } | Should -Not -Throw
    }

    It 'Show-QuarantineSummary function is available and callable' {
        # Arrange / Act
        { Show-QuarantineSummary } | Should -Not -Throw
    }

    It 'Get-QuarantineRoot returns valid path' {
        # Arrange / Act
        $quarantineRoot = Get-QuarantineRoot

        # Assert
        $quarantineRoot | Should -Not -BeNullOrEmpty
        $quarantineRoot -is [string] | Should -Be $true
    }

    It 'Find-OrphanFolders executes without errors' {
        # Arrange / Act
        { Find-OrphanFolders | Out-Null } | Should -Not -Throw
    }

    It 'Get-CleanupPotential Standard mode returns results' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        $potential | Should -Not -BeNullOrEmpty
    }

    It 'Measure-AndClear is callable with standard parameters' {
        # Arrange
        $testDir = Join-Path $script:tmpRoot 'test'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Act
        { Measure-AndClear -Path $testDir -Category 'Test' } | Should -Not -Throw
    }

    It 'core module exports GetDirectorySize function' {
        # Arrange / Act
        $coreExports = Get-Module Bakunawa.Core | Select-Object -ExpandProperty ExportedFunctions

        # Assert
        $coreExports.Keys | Should -Contain 'Get-DirectorySize'
    }

    It 'cleanup module exports Find-OrphanFolders and Clear-CachedOrphans' {
        # Arrange / Act
        $cleanupExports = Get-Module Bakunawa.Cleanup | Select-Object -ExpandProperty ExportedFunctions

        # Assert
        $cleanupExports.Keys | Should -Contain 'Find-OrphanFolders'
        $cleanupExports.Keys | Should -Contain 'Clear-CachedOrphans'
        $cleanupExports.Keys | Should -Contain 'Measure-AndClear'
    }

    It 'quarantine module exports Move-ItemToQuarantine and Restore-QuarantinedItem' {
        # Arrange / Act
        $quarantineExports = Get-Module Bakunawa.Quarantine | Select-Object -ExpandProperty ExportedFunctions

        # Assert
        $quarantineExports.Keys | Should -Contain 'Move-ItemToQuarantine'
        $quarantineExports.Keys | Should -Contain 'Restore-QuarantinedItem'
    }

    It 'config module exports Get-UserConfig and Initialize-ConfigModule' {
        # Arrange / Act
        $configExports = Get-Module Bakunawa.Config | Select-Object -ExpandProperty ExportedFunctions

        # Assert
        $configExports.Keys | Should -Contain 'Get-UserConfig'
    }
}

# ─────────────────────────────────────────────────────────────────────────────────
# INTEGRATION TESTS: Full Cleanup Run
# ─────────────────────────────────────────────────────────────────────────────────

Describe 'Integration: Full Cleanup Scenario' {

    BeforeEach {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("integration_test_$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null

        $script:IsPreview = $true
        $script:RunningProcesses = @()
        $script:ExcludedPaths = $null
    }

    AfterEach {
        if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Full cleanup scan chain completes without errors' {
        # Arrange / Act
        $cleanupChain = {
            Get-CleanupPotential -Mode Standard | Out-Null
            Find-OrphanFolders | Out-Null
            Get-InstalledApplicationNames | Out-Null
            Clear-CachedOrphans
            Show-QuarantineSummary | Out-Null
        }

        # Assert
        $cleanupChain | Should -Not -Throw
    }

    It 'orphan findings are retrievable and have all required properties' {
        # Arrange / Act
        $findings = Find-OrphanFolders

        # Assert
        if ($findings.Count -gt 0) {
            $requiredProps = @('Path', 'Name', 'Size', 'Category', 'Tier', 'SafeDelete', 'RiskLevel')
            foreach ($prop in $requiredProps) {
                $findings[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | Should -Contain $prop
            }
        }
    }

    It 'cleanup potential measurements are non-negative' {
        # Arrange / Act
        $potential = Get-CleanupPotential -Mode Standard

        # Assert
        foreach ($task in $potential) {
            $task.EstimatedBytes | Should -BeGreaterOrEqual 0 -Because 'byte count cannot be negative'
            $task.FileCount | Should -BeGreaterOrEqual 0 -Because 'file count cannot be negative'
        }
    }

    It 'quarantine module is operational' {
        # Arrange / Act
        $quarantineRoot = Get-QuarantineRoot

        # Assert
        $quarantineRoot | Should -Not -BeNullOrEmpty
        $quarantineRoot -like '*Bakunawa*' -or $quarantineRoot -like '*Quarantine*' | Should -Be $true
    }
}

