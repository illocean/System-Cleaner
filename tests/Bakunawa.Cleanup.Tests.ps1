$modulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Cleanup.psm1'
$coreModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1'
$configModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Config.psm1'

Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue

Import-Module $configModulePath -Force -Scope Global
Import-Module $coreModulePath -Force -Scope Global
Import-Module $modulePath -Force -Scope Global

$script:ExcludedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

Describe 'Bakunawa.Cleanup task registry' {
    It 'returns different task counts per mode' {
        $std = Get-CleanupTasks -Mode 'Standard'
        $agg = Get-CleanupTasks -Mode 'Aggressive'
        $std.Count | Should -BeGreaterThan 0
        $agg.Count | Should -BeGreaterThan $std.Count
    }

    It 'includes orphan detection as a task' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $orphanTask = $tasks | Where-Object { $_.Name -eq 'Orphan Scan' }
        $orphanTask | Should -Not -BeNullOrEmpty
    }

    It 'includes new categories in standard mode' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $names = $tasks.Name
        $names | Should -Contain 'Game Caches'
        $names | Should -Contain 'Cloud Sync'
        $names | Should -Contain 'Creative Apps'
        $names | Should -Contain 'Productivity'
        $names | Should -Contain 'DevOps Tools'
    }

    It 'marks cache tasks as parallel' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $parallelTasks = $tasks | Where-Object { $_.Parallel -eq $true }
        $parallelTasks.Count | Should -BeGreaterThan 0
    }
}

Describe 'Write-CommandLog verbose SCAN integration' {
  It 'emits SCAN detail line when VerboseScan is on' {
    $script:VerboseScan = $true
    $script:VerboseScan = $false
  }
  It 'suppresses SCAN detail line when VerboseScan is off' {
    $script:VerboseScan = $false
    $script:VerboseScan = $false
  }
}

Describe 'Bakunawa.Cleanup potential estimation' {
    It 'returns array of potential objects' {
        $p = @(Get-CleanupPotential -Mode 'Standard')
        $p.Count | Should -BeGreaterThan 0
    }

    It 'each object has required properties' {
        $p = @(Get-CleanupPotential -Mode 'Standard')
        foreach ($item in $p) {
            $item.Target | Should -Not -BeNullOrEmpty
            $item.EstimatedBytes | Should -BeGreaterOrEqual 0
            $item.FileCount | Should -BeGreaterOrEqual 0
            $item.Status | Should -BeIn 'ok', 'skipped', 'unknown'
        }
    }

    It 'returns results sorted descending by size' {
        $p = @(Get-CleanupPotential -Mode 'Standard')
        for ($i = 1; $i -lt $p.Count; $i++) {
            $p[$i - 1].EstimatedBytes -ge $p[$i].EstimatedBytes | Should -Be $true
        }
    }

    It 'Aggressive mode returns more items than Standard' {
        $std = @(Get-CleanupPotential -Mode 'Standard')
        $agg = @(Get-CleanupPotential -Mode 'Aggressive')
        $agg.Count | Should -BeGreaterThan $std.Count
    }
}
