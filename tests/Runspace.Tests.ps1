#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.Runspace.psm1
Contract locked by deepwork Phase 4:
  - Invoke-Parallel: mapping correctness, empty/single boundaries, per-item fault isolation
    (a throwing item must not abort the batch - collect-and-continue)
  - Throttle limit is a positive int; pool close is idempotent
#>

BeforeAll {
    $script:Src = Join-Path $PSScriptRoot '..\src'
    function script:Reset-RunspaceStack {
        Remove-Module Bakunawa.Runspace -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Config   -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Remove-Module Bakunawa.Core     -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Core.psm1')    -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Config.psm1')  -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $script:Src 'Bakunawa.Runspace.psm1') -Force -WarningAction SilentlyContinue
    }
}

Describe 'Bakunawa.Runspace: Invoke-Parallel' {

    BeforeAll { script:Reset-RunspaceStack }

    It 'maps items through the scriptblock correctly (happy path)' {
        $items = 1..20
        $results = Invoke-Parallel -Items $items -ScriptBlock { param($i) $i * 2 }
        @($results).Count | Should -Be 20
        ($results | Sort-Object) | Should -Be (2..40 | Where-Object { $_ % 2 -eq 0 })
    }

    It 'empty item array returns nothing (PowerShell empty-output contract)' {
        $r = Invoke-Parallel -Items @() -ScriptBlock { param($i) $i }
        # NOTE: `return @()` emits no pipeline output; assert idiomatically, not by Count
        $r | Should -BeNullOrEmpty
    }

    It 'single item works (boundary)' {
        $r = Invoke-Parallel -Items @(5) -ScriptBlock { param($i) $i + 1 }
        @($r).Count | Should -Be 1
        $r[0] | Should -Be 6
    }

    It 'explicit ThrottleLimit=1 still completes all items' {
        $r = Invoke-Parallel -Items (1..8) -ScriptBlock { param($i) $i } -ThrottleLimit 1
        @($r).Count | Should -Be 8
    }

    It 'fault isolation: throwing items do not abort the batch (collect semantics)' {
        $items = 1..6
        $results = Invoke-Parallel -Items $items -ScriptBlock {
            param($i)
            if ($i -eq 3 -or $i -eq 5) { throw "planned failure $i" }
            $i * 10
        }
        @($results).Count | Should -Be 4 -Because 'failing items are skipped, survivors returned'
        $results | Should -Contain 10
        $results | Should -Contain 60
    }
}

Describe 'Bakunawa.Runspace: pool lifecycle' {

    BeforeAll { script:Reset-RunspaceStack }

    It 'Get-RunspaceThrottleLimit returns a positive int' {
        $t = Get-RunspaceThrottleLimit
        $t | Should -BeOfType [int]
        $t | Should -BeGreaterOrEqual 1
    }

    It 'Close-RunspacePool is idempotent and safe when never opened' {
        { Close-RunspacePool } | Should -Not -Throw
        { Close-RunspacePool } | Should -Not -Throw
    }

    It 'Initialize-RunspacePool twice returns a usable pool without error' {
        $p1 = Initialize-RunspacePool
        $p2 = Initialize-RunspacePool
        $p1 | Should -Not -BeNullOrEmpty
        $p2 | Should -Not -BeNullOrEmpty
        Close-RunspacePool
    }
}

Describe 'Bakunawa.Runspace: module hygiene' {

    BeforeAll { script:Reset-RunspaceStack }

    It 'every public function declares CmdletBinding' {
        $raw = Get-Content -LiteralPath (Join-Path $script:Src 'Bakunawa.Runspace.psm1') -Raw
        $funcs = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)')
        $missing = @()
        foreach ($f in $funcs) {
            $tail = $raw.Substring($f.Index, [Math]::Min(200, $raw.Length - $f.Index))
            if ($tail -notmatch '\[CmdletBinding\(\)\]') { $missing += $f.Groups[1].Value }
        }
        $missing.Count | Should -Be 0 -Because ("missing CB: " + ($missing -join ', '))
    }

    It 'explicit allowlist covers every defined function; no PS7 syntax' {
        $path = Join-Path $script:Src 'Bakunawa.Runspace.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'Export-ModuleMember\s+-Function\s+\*'
        $raw | Should -Not -Match '-AsHashtable'
        $defined = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $exported = @(Get-Command -Module Bakunawa.Runspace -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name) | Sort-Object -Unique
        (Compare-Object $defined $exported | Out-String) | Should -BeNullOrEmpty
    }
}
