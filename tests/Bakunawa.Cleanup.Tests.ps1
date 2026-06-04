$modulePath = Join-Path $PSScriptRoot '..\Bakunawa.Cleanup.psm1'
$coreModulePath = Join-Path $PSScriptRoot '..\Bakunawa.Core.psm1'
$configModulePath = Join-Path $PSScriptRoot '..\Bakunawa.Config.psm1'

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
        $std.Count | Should BeGreaterThan 0
        $agg.Count | Should BeGreaterThan $std.Count
    }

    It 'includes orphan detection as a task' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $orphanTask = $tasks | Where-Object { $_.Name -eq 'Orphan Scan' }
        $orphanTask | Should Not BeNullOrEmpty
    }

    It 'includes orphan scan task' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $tasks.Name -contains 'Orphan Scan' | Should Be $true
    }
}