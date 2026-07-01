$modulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.UI.psm1'
$coreModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1'

Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue

Import-Module $coreModulePath -Force -Scope Global
Import-Module $modulePath -Force -Scope Global

Describe 'Bakunawa.UI mode colors' {
    It 'returns expected color for Standard mode' {
        Get-ModeColor 'Standard' | Should -Be 'Green'
    }
    It 'returns expected color for Aggressive mode' {
        Get-ModeColor 'Aggressive' | Should -Be 'Yellow'
    }
    It 'returns expected color for Preview mode' {
        Get-ModeColor 'Preview' | Should -Be 'DarkGray'
    }
    It 'returns default color for Menu mode' {
        Get-ModeColor 'Menu' | Should -Be 'DarkCyan'
    }
    It 'returns default color for unknown mode' {
        Get-ModeColor 'Unknown' | Should -Be 'DarkCyan'
    }
}

Describe 'Bakunawa.UI VT100 detection' {
    It 'detects VT100 support without crashing' {
        $result = Test-VT100Supported
        $result | Should -BeOfType System.Boolean
    }
}

Describe 'Bakunawa.UI logging' {
    It 'writes INFO log entries without crashing' {
        { Write-Log 'Test message' 'INFO' } | Should -Not -Throw
    }
    It 'writes OK log entries without crashing' {
        { Write-Log 'Test ok' 'OK' } | Should -Not -Throw
    }
    It 'writes WARN log entries without crashing' {
        { Write-Log 'Test warn' 'WARN' } | Should -Not -Throw
    }
}
