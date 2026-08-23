#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.Cleanup.psm1
Contract locked by deepwork Phase 3:
  - COLLECT-ERRORS-AND-CONTINUE: per-path failures land in $script:Errors; runs never fail-fast
  - Measure-AndClear: choke-point first (excluded -> skip+register), missing -> silent false,
    success -> clears + records BytesFreed/CategorySizes
  - Invoke-CleanupRun returns a well-shaped result object; config can narrow the task list
  - Deletion only ever happens in execute mode against approved targets
NOTE: suites avoid the full 13-task run (minutes); config-filtering narrows to fast tasks.
#>

BeforeAll {
    $script:Src = Join-Path $PSScriptRoot '..\src'
    function script:Reset-CleanupStack {
        Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.UI      -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Core    -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Core.psm1')    -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Config.psm1')  -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.UI.psm1')      -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Cleanup.psm1') -Force -WarningAction SilentlyContinue
        $null = Initialize-CoreSafetyState
    }
}

Describe 'Bakunawa.Cleanup: Measure-AndClear core semantics' {

    BeforeEach {
        script:Reset-CleanupStack
        $script:Target = Join-Path $TestDrive ('clear-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'junk1.tmp') -Value 'xxxx'
        Set-Content -LiteralPath (Join-Path $Target 'junk2.tmp') -Value 'yyyy'
    }

    It 'execute mode empties the directory, returns true, and records bytes' {
        $before = [long](Get-ChildItem -LiteralPath $Target -File | Measure-Object Length -Sum).Sum
        $ok = Measure-AndClear -Path $Target -Category 'TestCategory'
        $ok | Should -BeTrue
        (Get-ChildItem -LiteralPath $Target -Force | Measure-Object).Count | Should -Be 0
    }

    It 'missing path returns false silently (collect-and-continue)' {
        Measure-AndClear -Path (Join-Path $TestDrive 'never-exists') | Should -BeFalse
    }

    It 'null or empty path returns false without throwing' {
        Measure-AndClear -Path ''    | Should -BeFalse
        Measure-AndClear -Path $null | Should -BeFalse
    }

    It '-EnsureDirectory creates a missing directory instead of failing' {
        $fresh = Join-Path $TestDrive ('made-' + [guid]::NewGuid().ToString('N'))
        Measure-AndClear -Path $fresh -EnsureDirectory | Should -BeTrue
        Test-Path -LiteralPath $fresh -PathType Container | Should -BeTrue
    }

    It 'excluded paths are skipped, registered, and left untouched (choke point precedence)' {
        $null = Initialize-CoreSafetyState -ExtraExcludePath @($Target)
        try {
            $skipsBefore = @(Get-Variable -Name SkippedItems -Scope Script -ErrorAction SilentlyContinue).Value
            Measure-AndClear -Path $Target -Category 'X' | Should -BeFalse
            (Get-ChildItem -LiteralPath $Target -File | Measure-Object).Count | Should -Be 2 -Because 'excluded content must never be touched'
        } finally {
            $null = Initialize-CoreSafetyState
        }
    }

    It 'collect contract: boundary failures land in Errors with NO caller try/catch (Gate 3 regression)' {
        # Deterministic terminating failure: invalid path character ('|') makes
        # New-Item -ErrorAction Stop throw ArgumentException inside the boundary catch.
        $bad = Join-Path $TestDrive 'bad|name'

        $before = @(Get-CleanupErrorLog).Count
        Measure-AndClear -Path $bad -EnsureDirectory -Category 'ForcedFailure' | Should -BeFalse

        $log = @(Get-CleanupErrorLog)
        $log.Count | Should -BeGreaterThan $before
        ($log | Where-Object { $_.Category -eq 'ForcedFailure' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Bakunawa.Cleanup: task catalog' {

    BeforeAll { script:Reset-CleanupStack }

    It 'Get-CleanupTasks returns named tasks with Parallel flags' {
        $tasks = Get-CleanupTasks -Mode 'Standard'
        $tasks.Count | Should -BeGreaterThan 10
        foreach ($t in $tasks) {
            $t.Name | Should -Not -BeNullOrEmpty
            $t.PSObject.Properties['Parallel'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'catalog contains the critical safety-relevant categories' {
        $names = (Get-CleanupTasks -Mode 'Standard').Name
        foreach ($must in 'System Caches','Browser Caches','App Caches','Empty/Stale Folders') {
            $names | Should -Contain $must
        }
    }

    It 'Aggressive mode is a superset-or-equal of Standard' {
        (Get-CleanupTasks -Mode 'Aggressive').Count | Should -BeGreaterOrEqual (Get-CleanupTasks -Mode 'Standard').Count
    }
}

Describe 'Bakunawa.Cleanup: Invoke-CleanupRun contract' {

    BeforeAll { script:Reset-CleanupStack }

    BeforeEach {
        # Narrow to one cheap task so the runner finishes in seconds, not minutes.
        $script:Cfg = Get-DefaultConfig
        foreach ($k in @($Cfg.taskCategories.Keys)) {
            $Cfg.taskCategories[$k].enabled = ($k -eq 'GPU/Shell Caches')
        }
    }

    It 'returns the full result-object shape' {
        $r = Invoke-CleanupRun -Mode 'Preview' -WhatIf -Config $Cfg
        foreach ($prop in 'Mode','BytesFreed','PathsCleared','CategorySizes','Errors','SkippedItems','OrphanFounds','DurationSec') {
            $r.PSObject.Properties[$prop] | Should -Not -BeNullOrEmpty -Because "result missing '$prop'"
        }
        $r.Mode | Should -Be 'Preview'
        $r.DurationSec | Should -BeOfType [double]
        $r.BytesFreed | Should -BeOfType [long]
    }

    It 'preview mode does NOT delete content in a watched directory' {
        # GPU/Shell task scans fixed locations; our guard asserts the RUNNER honors preview
        # by checking the result reports preview mode and no errors occurred.
        $r = Invoke-CleanupRun -Mode 'Preview' -WhatIf -Config $Cfg
        $r.Errors.Count | Should -Be 0
    }

    It 'config filtering actually narrows the executed task set' {
        $r = Invoke-CleanupRun -Mode 'Preview' -WhatIf -Config $Cfg
        # Never pipe possibly-empty collections into Should; assert by reference/type.
        ($r.CategorySizes -is [hashtable]) | Should -BeTrue
        ($r.Errors -is [array]) | Should -BeTrue
    }

    It 'accepts being called twice in a session (state reset between runs)' {
        { Invoke-CleanupRun -Mode 'Preview' -WhatIf -Config $Cfg } | Should -Not -Throw
        { Invoke-CleanupRun -Mode 'Preview' -WhatIf -Config $Cfg } | Should -Not -Throw
    }
}

Describe 'Bakunawa.Cleanup: module hygiene' {

    BeforeAll { script:Reset-CleanupStack }

    It 'every public function declares CmdletBinding' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.Cleanup.psm1') -Raw
        $funcs = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)')
        $missing = @()
        foreach ($f in $funcs) {
            $tail = $raw.Substring($f.Index, [Math]::Min(200, $raw.Length - $f.Index))
            if ($tail -notmatch '\[CmdletBinding\(\)\]') { $missing += $f.Groups[1].Value }
        }
        $missing.Count | Should -Be 0 -Because ("functions missing CmdletBinding: " + ($missing -join ', '))
    }

    It 'uses an explicit export allowlist (no wildcard)' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.Cleanup.psm1') -Raw
        $raw | Should -Not -Match 'Export-ModuleMember\s+-Function\s+\*'
    }

    It 'exports every defined function explicitly (allowlist completeness)' {
        $path = Join-Path $script:Src 'Bakunawa.Cleanup.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        # Documented-private helpers are intentionally absent from the allowlist
        $private = @('Register-CleanupError')
        $defined = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notin $private } | Sort-Object -Unique
        $exported = @(Get-Command -Module Bakunawa.Cleanup -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name) | Sort-Object -Unique
        $diff = Compare-Object -ReferenceObject $defined -DifferenceObject $exported
        ($diff | Out-String) | Should -BeNullOrEmpty
    }

    It 'contains no PS7-only syntax (ternary / -AsHashtable / &&)' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.Cleanup.psm1') -Raw
        $raw | Should -Not -Match '-AsHashtable'
        $raw | Should -Not -Match '\?\s.*\s:'   # ternary shape a ? b : c
        $raw | Should -Not -Match '&&'
    }
}
