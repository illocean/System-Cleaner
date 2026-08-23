#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.UI.psm1
Contract locked by deepwork Phase 4:
  - Pure formatters: null-safe, boundary-safe, deterministic
  - File logging via EXPLICIT Initialize-UiLogging contract (mirrors Core's single-writer rule;
    Bakunawa.ps1 assigning $script:LogFilePath in its own scope is the same inert-state bug
    class Phase 2 fixed for exclusions)
#>

BeforeAll {
    $script:Src = Join-Path $PSScriptRoot '..\src'
    function script:Reset-UiStack {
        Remove-Module Bakunawa.UI   -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Core.psm1') -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.UI.psm1')   -Force -WarningAction SilentlyContinue
    }
}

Describe 'Bakunawa.UI: pure formatters' {

    BeforeAll { script:Reset-UiStack }

    It 'Get-DisplayText passes through short text and truncates long text with ellipsis' {
        Get-DisplayText -Text 'short' -MaxWidth 10 | Should -Be 'short'
        $t = Get-DisplayText -Text 'abcdefghij' -MaxWidth 5
        $t.Length | Should -Be 5
        $t | Should -Match '\.\.\.$'
    }

    It 'Get-DisplayText handles MaxWidth<=3 and null/empty without throwing' {
        { Get-DisplayText -Text 'abc' -MaxWidth 1 } | Should -Not -Throw
        Get-DisplayText -Text ''     -MaxWidth 10 | Should -Be ''
        Get-DisplayText -Text $null  -MaxWidth 10 | Should -Be ''
    }

    It 'New-AsciiBar renders 0% and 100% correctly and clamps overflow' {
        New-AsciiBar -Value 0 -Total 10 -Width 10 | Should -Match '0%'
        New-AsciiBar -Value 10 -Total 10 -Width 10 | Should -Match '100%'
        New-AsciiBar -Value 99 -Total 10 -Width 10 | Should -Match '100%' -Because 'overflow must clamp'
    }

    It 'New-AsciiBar tolerates zero/negative totals and tiny widths (boundary)' {
        { New-AsciiBar -Value 1 -Total 0 -Width 0 } | Should -Not -Throw
        New-AsciiBar -Value 1 -Total 0 -Width 5 | Should -Not -BeNullOrEmpty
    }

    It 'glyph helpers return non-empty values across the full percent range' {
        foreach ($kind in 'Step','Ok','Warn','Err','Cmd','Scan','Size','Info','Serp','Flame') {
            (Get-ThemedGlyph -Kind $Kind).ToString() | Should -Not -BeNullOrEmpty
        }
        foreach ($p in 0,10,25,50,75,99,100) {
            (Get-MoonPhaseGlyph -Percent $p) | Should -Not -BeNullOrEmpty
        }
    }

    It 'Get-ConsoleWidth returns a sane positive width' {
        (Get-ConsoleWidth) | Should -BeGreaterThan 10
    }
}

Describe 'Bakunawa.UI: explicit logging contract' {

    BeforeEach { script:Reset-UiStack }

    It 'Initialize-UiLogging registers a log path; Write-Log appends timestamped lines' {
        $logFile = Join-Path $TestDrive 'ui-log.txt'
        Initialize-UiLogging -Path $logFile
        Write-Log 'contract message' 'INFO'
        Test-Path -LiteralPath $logFile | Should -BeTrue
        $line = (Get-Content -LiteralPath $logFile | Select-Object -First 1)
        $line | Should -Match '\[\d{2}:\d{2}:\d{2}\]\[INFO\] contract message'
    }

    It 'Initialize-UiLogging creates missing parent directories' {
        $deep = Join-Path $TestDrive 'a\b\c\log.txt'
        { Initialize-UiLogging -Path $deep } | Should -Not -Throw
        Test-Path -LiteralPath (Split-Path -Parent $deep) | Should -BeTrue
    }

    It 'Write-Log never throws for any level or message shape' {
        Initialize-UiLogging -Path (Join-Path $TestDrive 'l2.txt')
        foreach ($lvl in 'INFO','OK','WARN','ERR','CMD','STEP','SIZE','SCAN') {
            { Write-Log "m-$lvl" $lvl } | Should -Not -Throw
        }
        { Write-Log '' } | Should -Not -Throw
    }
}

Describe 'Bakunawa.UI: module hygiene' {

    BeforeAll { script:Reset-UiStack }

    It 'every public function declares CmdletBinding' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.UI.psm1') -Raw
        $funcs = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)')
        $missing = @()
        foreach ($f in $funcs) {
            $tail = $raw.Substring($f.Index, [Math]::Min(200, $raw.Length - $f.Index))
            if ($tail -notmatch '\[CmdletBinding\(\)\]') { $missing += $f.Groups[1].Value }
        }
        $missing.Count | Should -Be 0 -Because ("missing CB: " + ($missing -join ', '))
    }

    It 'uses an explicit export allowlist and exports every defined function' {
        $path = Join-Path $script:Src 'Bakunawa.UI.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'Export-ModuleMember\s+-Function\s+\*'
        # No documented-private functions remain: the serpent/VT animation engine
        # was fully excised with the minimal-UI redesign (dead-code removal pass).
        $defined = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $exported = @(Get-Command -Module Bakunawa.UI -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name) | Sort-Object -Unique
        $diff = Compare-Object -ReferenceObject $defined -DifferenceObject $exported
        ($diff | Out-String) | Should -BeNullOrEmpty
    }

    It 'contains no PS7-only syntax' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.UI.psm1') -Raw
        $raw | Should -Not -Match '-AsHashtable'
        $raw | Should -Not -Match '&&'
    }
}
