$modulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Config.psm1'
Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -Scope Global

Describe 'Bakunawa.Config' {
    It 'resolves environment path templates correctly' {
        $result = Resolve-EnvTemplate -EnvVar 'LOCALAPPDATA' -SubPath 'discord/Cache'
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match 'discord\\Cache$'
    }

    It 'returns null for missing environment variable' {
        $result = Resolve-EnvTemplate -EnvVar 'NONEXISTENT_TEST_VAR' -SubPath 'test'
        $result | Should -BeNullOrEmpty
    }

    It 'loads app definitions from a category file' {
        $defs = Get-AppDefinitions -Category 'messaging'
        $defs | Should -Not -BeNullOrEmpty
        $defs.Count | Should -BeGreaterThan 0
        $defs[0].name | Should -Not -BeNullOrEmpty
        $defs[0].locations | Should -Not -BeNullOrEmpty
    }

    It 'loads all app definition categories' {
        $all = Get-AllAppDefinitions
        $all.Count | Should -BeGreaterThan 10
    }

    It 'loads new categories (games, cloud, creative, productivity, devops)' {
        $games = Get-AppDefinitions -Category 'games'
        $cloud = Get-AppDefinitions -Category 'cloud'
        $creative = Get-AppDefinitions -Category 'creative'
        $productivity = Get-AppDefinitions -Category 'productivity'
        $devops = Get-AppDefinitions -Category 'devops'
        $games.Count | Should -BeGreaterThan 0
        $cloud.Count | Should -BeGreaterThan 0
        $creative.Count | Should -BeGreaterThan 0
        $productivity.Count | Should -BeGreaterThan 0
        $devops.Count | Should -BeGreaterThan 0
    }

    It 'loads default config when no config file exists' {
        $config = Get-BakunawaConfig
        $config.mode | Should -Be 'Menu'
        $config.parallel | Should -Be $true
    }

    It 'merges CLI extra exclusions with config file exclusions' {
        $merged = Merge-Exclusions -ConfigPaths @('D:\Backups') -CliPaths @('E:\Data')
        $merged.Count | Should -Be 2
    }

    It 'processes null process name safely' {
        $defs = Get-AppDefinitions -Category 'system'
        $nullNames = $defs | Where-Object { $null -eq $_.process }
        $nullNames.Count | Should -BeGreaterThan 0
    }
    It 'Resolve-EnvTemplate catch logs via Write-Verbose instead of silent return' {
        $cfgContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.Config.psm1') -Raw
        ($cfgContent -match 'Write-Verbose.*Resolve-EnvTemplate') | Should -Be $true
    }
}
