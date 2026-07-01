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
