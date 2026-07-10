$modulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.UI.psm1'
$coreModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1'
$cleanupModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Cleanup.psm1'
$configModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Config.psm1'

Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue

Import-Module $configModulePath -Force -Scope Global
Import-Module $coreModulePath -Force -Scope Global
Import-Module $cleanupModulePath -Force -Scope Global
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

Describe 'Bakunawa.UI menu content' {
    It 'Show-Menu does not contain Disk Usage option [6]' {
        $ast = (Get-Command Show-Menu).ScriptBlock.Ast
        $text = $ast.Extent.Text
        $text | Should -Not -Match '\[6\]'
        $text | Should -Not -Match 'Disk Usage'
    }
}

Describe 'Bakunawa.UI Windows Terminal detection' {
    It 'Test-IsWindowsTerminal is available' {
        { Get-Command Test-IsWindowsTerminal -Module Bakunawa.UI -ErrorAction Stop } | Should -Not -Throw
    }
    It 'returns false when WT_SESSION is not set' {
        $orig = $env:WT_SESSION
        try {
            $env:WT_SESSION = $null
            Test-IsWindowsTerminal | Should -Be $false
        } finally {
            $env:WT_SESSION = $orig
        }
    }
    It 'returns true when WT_SESSION is set' {
        $orig = $env:WT_SESSION
        try {
            $env:WT_SESSION = 'test-session-123'
            Test-IsWindowsTerminal | Should -Be $true
        } finally {
            $env:WT_SESSION = $orig
        }
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
    It 'Write-Log file write catch does not silently swallow errors' {
        $uiContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.UI.psm1') -Raw
        $uiContent | Should -Not -Match 'Add-Content.*-EA SilentlyContinue'
    }
    It 'Write-Log accepts SCAN level without crashing' {
        { Write-Log 'scan detail' 'SCAN' } | Should -Not -Throw
    }
    It 'Write-Log SCAN case emits values (not local variable assignments) for multi-value switch' {
        $uiContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.UI.psm1') -Raw
        # Extract the SCAN case body (inside the braces, excluding the 'SCAN' label)
        $scanBody = [regex]::Match($uiContent, "'SCAN'\s*\{([\s\S]*?)\n    \}", 'Singleline').Groups[1].Value
        # Should emit values (string literals), not set local variables
        ($scanBody -match "'[^']*',\s*'[A-Za-z]+'") | Should -Be $true
        ($scanBody -match '\$prefix\s*=') | Should -Be $false
        ($scanBody -match '\$color\s*=') | Should -Be $false
    }
}

Describe 'Bakunawa.UI Show-CleanupPotential' {
    It 'does not crash when called with Standard mode' {
        { Show-CleanupPotential -Mode 'Standard' } | Should -Not -Throw
    }
    It 'does not crash when called with Preview mode' {
        { Show-CleanupPotential -Mode 'Preview' } | Should -Not -Throw
    }
    It 'is exported from the module' {
        Get-Command Show-CleanupPotential -Module Bakunawa.UI -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}
