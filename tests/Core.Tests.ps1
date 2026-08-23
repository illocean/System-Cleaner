#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.Core.psm1
Contract locked by deepwork Phase 2:
  - Path resolution never throws on hostile input (null/empty/invalid chars)
  - Exclusion choke point: exact match AND descendant-prefix match, case-insensitive
  - Safe-target checks: roots themselves are NOT safe unless -AllowRoot
  - Real filesystem via $TestDrive (integration, no fs mocks)
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1'
    function script:Reset-CoreModule {
        Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue
    }
    script:Reset-CoreModule
}

Describe 'Bakunawa.Core: path resolution' {

    It 'Resolve-FullPath returns null for null/empty/whitespace input (never throws)' {
        foreach ($bad in @($null, '', '   ')) {
            Resolve-FullPath -Path $bad | Should -BeNullOrEmpty
        }
    }

    It 'Resolve-FullPath normalizes relative paths against the process location' {
        $r = Resolve-FullPath -Path '.'
        $r | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
    }

    It 'Resolve-FullPath collapses dot segments and trailing slashes' {
        $base = Resolve-FullPath -Path $TestDrive
        $r = Resolve-FullPath -Path (Join-Path $base 'sub\..\sub2\')
        $r | Should -Be (Join-Path $base 'sub2')
    }

    It 'Resolve-FullPath works for nonexistent paths (pure string normalization)' {
        $r = Resolve-FullPath -Path (Join-Path $TestDrive 'does-not-exist-xyz')
        $r | Should -Not -BeNullOrEmpty
    }

    It 'Resolve-RealPath returns null-safe results for missing paths' {
        Resolve-RealPath -Path '' | Should -BeNullOrEmpty
    }

    It 'Resolve-RealPath resolves an existing directory to itself when not a link' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Resolve-RealPath -Path $dir | Should -Be (($dir -replace '/','\').TrimEnd('\'))
    }

    It 'Join-EnvPath builds USERPROFILE-rooted paths that exist-check cleanly' {
        $p = Join-EnvPath -Name 'USERPROFILE' -ChildPath 'Desktop'
        $p | Should -Not -BeNullOrEmpty
        $p.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
    }

    It 'Get-EnvPath resolves TEMP to an existing container' {
        $t = Get-EnvPath -Name 'TEMP'
        $t | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $t -PathType Container | Should -BeTrue
    }
}

Describe 'Bakunawa.Core: exclusion choke point' {

    BeforeAll {
        script:Reset-CoreModule
        # Real excluded tree inside TestDrive
        $script:ExRoot  = Join-Path $TestDrive 'excluded-area'
        $script:ExChild = Join-Path $ExRoot 'deep\nested'
        New-Item -ItemType Directory -Path $ExChild -Force | Out-Null
        $script:FreeArea = Join-Path $TestDrive 'free-area'
        New-Item -ItemType Directory -Path $FreeArea | Out-Null

        # Explicit state contract: module state is set ONLY via the initializer
        $null = Initialize-CoreSafetyState -ExtraExcludePath @($ExRoot)
    }

    It 'Test-IsExcludedPath: exact excluded root matches' {
        Test-IsExcludedPath -Path $ExRoot | Should -BeTrue
    }

    It 'Test-IsExcludedPath: any descendant matches via prefix' {
        Test-IsExcludedPath -Path $ExChild | Should -BeTrue
    }

    It 'Test-IsExcludedPath is case-insensitive' {
        Test-IsExcludedPath -Path ($ExRoot.ToUpperInvariant()) | Should -BeTrue
    }

    It 'Test-IsExcludedPath: sibling prefix must NOT match (no partial-segment leaks)' {
        # 'excluded-area-evil' shares a prefix string but not a path segment
        $sibling = $ExRoot + '-evil'
        Test-IsExcludedPath -Path $sibling | Should -BeFalse
    }

    It 'Test-IsExcludedPath: non-excluded area is false' {
        Test-IsExcludedPath -Path $FreeArea | Should -BeFalse
    }

    It 'Test-IsExcludedPath: standard user folders are hard-excluded by default' {
        Test-IsExcludedPath -Path (Join-Path $env:USERPROFILE 'Documents') | Should -BeTrue
    }

    It 'Test-IsExcludedPath tolerates null/empty input without throwing' {
        Test-IsExcludedPath -Path ''   | Should -BeFalse
        Test-IsExcludedPath -Path $null | Should -BeFalse
    }
}

Describe 'Bakunawa.Core: safe cleanup target checks' {

    BeforeAll {
        script:Reset-CoreModule
        $script:ApprovedRoot = Join-Path $TestDrive 'approved'
        $script:Inside       = Join-Path $ApprovedRoot 'cache-dir'
        New-Item -ItemType Directory -Path $Inside -Force | Out-Null
    }

    It 'Paths under an approved root are safe' {
        Test-SafeCleanupTarget -Path $Inside -ApprovedRoots @($ApprovedRoot) | Should -BeTrue
    }

    It 'The approved root ITSELF is not safe unless -AllowRoot' {
        Test-SafeCleanupTarget -Path $ApprovedRoot -ApprovedRoots @($ApprovedRoot) | Should -BeFalse
        Test-SafeCleanupTarget -Path $ApprovedRoot -ApprovedRoots @($ApprovedRoot) -AllowRoot | Should -BeTrue
    }

    It 'Paths outside all approved roots are unsafe' {
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Test-SafeCleanupTarget -Path $outside -ApprovedRoots @($ApprovedRoot) | Should -BeFalse
    }

    It 'Root-boundary prefix cannot leak (rootX vs root)' {
        $twin = $ApprovedRoot + 'x'
        New-Item -ItemType Directory -Path $twin -Force | Out-Null
        Test-SafeCleanupTarget -Path $twin -ApprovedRoots @($ApprovedRoot) | Should -BeFalse
    }

    It 'Excluded paths are rejected even inside approved roots (choke point precedence)' {
        $null = Initialize-CoreSafetyState -ExtraExcludePath @($Inside)
        try {
            Test-SafeCleanupTarget -Path $Inside -ApprovedRoots @($ApprovedRoot) | Should -BeFalse
        } finally {
            $null = Initialize-CoreSafetyState
        }
    }

    It 'Handles empty approved-roots list by falling back to defaults without throwing' {
        { Test-SafeCleanupTarget -Path $Inside -ApprovedRoots @() } | Should -Not -Throw
    }
}

Describe 'Bakunawa.Core: sizing and formatting' {

    BeforeAll { script:Reset-CoreModule }

    It 'Get-DirectorySize sums real file bytes in a temp tree' {
        $dir = Join-Path $TestDrive ('sized-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'a.bin') -Value ('x' * 1000)
        Set-Content -LiteralPath (Join-Path $dir 'b.bin') -Value ('y' * 500)
        # Expected derived from actual on-disk sizes (encoding-independent)
        $expected = (Get-ChildItem -LiteralPath $dir -File | Measure-Object -Property Length -Sum).Sum
        Get-DirectorySize -Path $dir | Should -Be $expected
    }

    It 'Get-DirectorySize returns 0 for missing path (collect-and-continue)' {
        Get-DirectorySize -Path (Join-Path $TestDrive 'missing-xyz') | Should -Be 0
    }

    It 'Format-FileSize renders human units across boundaries' {
        Format-FileSize -Bytes 512            | Should -Match 'B$'
        Format-FileSize -Bytes 5MB            | Should -Match 'MB$'
        Format-FileSize -Bytes 3GB            | Should -Match 'GB$'
    }

    It 'Format-FileSize handles zero and negative without throwing' {
        { Format-FileSize -Bytes 0 }  | Should -Not -Throw
        { Format-FileSize -Bytes -5 } | Should -Not -Throw
    }
}

Describe 'Bakunawa.Core: module hygiene' {

    It 'exports exactly one Get-SystemLocations (duplicate-definition regression)' {
        script:Reset-CoreModule
        (@(Get-Command -Module Bakunawa.Core -Name 'Get-SystemLocations' -ErrorAction SilentlyContinue)).Count |
            Should -Be 1
    }

    It 'uses an explicit export allowlist (no wildcard Export-ModuleMember regression)' {
        $raw = Get-Content -LiteralPath $script:ModulePath -Raw
        $raw | Should -Not -Match 'Export-ModuleMember\s+-Function\s+\*'
    }

    It 'every public function declares CmdletBinding' {
        $raw = Get-Content -LiteralPath $script:ModulePath -Raw
        $funcs = [regex]::Matches($raw, '(?m)^function\s+([A-Za-z0-9-]+)')
        $missing = @()
        foreach ($f in $funcs) {
            $tail = $raw.Substring($f.Index, [Math]::Min(200, $raw.Length - $f.Index))
            if ($tail -notmatch '\[CmdletBinding\(\)\]') { $missing += $f.Groups[1].Value }
        }
        $missing.Count | Should -Be 0 -Because ("functions missing CmdletBinding: " + ($missing -join ', '))
    }
}
