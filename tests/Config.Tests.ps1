#Requires -Modules Pester
<#
Pester v5 integration tests for Bakunawa.Config.psm1
Contract locked by deepwork Phase 1:
  - PS 5.1 compatible (NO -AsHashtable, NO ternary)
  - Uninitialized module never throws -> returns defaults
  - Real config files on disk MUST load and merge (regression for -AsHashtable bug)
  - Collect-errors-and-continue: invalid files degrade to defaults with warning, never throw
  - Validation gates: Set-UserConfig throws on schema violation
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Config.psm1'
    # Fresh module instance per test: resets $script:ConfigPath/$script:CurrentConfig cache
    function script:Reset-ConfigModule {
        Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue
    }
}

Describe 'Bakunawa.Config: initialization and defaults' {

    BeforeEach { script:Reset-ConfigModule }

    It 'initializes with an explicit path without output or error' {
        { Initialize-ConfigModule -ConfigPath (Join-Path $TestDrive 'cfg.json') } | Should -Not -Throw
    }

    It 'initializes with no path (falls back to APPDATA default) without throwing' {
        { Initialize-ConfigModule } | Should -Not -Throw
    }

    It 'Get-DefaultConfig returns a hashtable with all required top-level keys' {
        $d = Get-DefaultConfig
        $d | Should -BeOfType [hashtable]
        foreach ($key in 'version','cleanupMode','exclusions','taskCategories','riskTiers') {
            $d.ContainsKey($key) | Should -BeTrue -Because "required key '$key' missing"
        }
    }

    It 'Get-UserConfig before Initialize returns defaults and does NOT throw (empty LiteralPath regression)' {
        { $c = Get-UserConfig } | Should -Not -Throw
        Get-UserConfig | Should -BeOfType [hashtable]
    }
}

Describe 'Bakunawa.Config: loading real config files (integration)' {

    BeforeEach {
        script:Reset-ConfigModule
        $script:CfgFile = Join-Path $TestDrive 'config.json'
    }

    It 'loads a valid config file from disk and merges user values over defaults' {
        # Minimal valid schema: version + required objects
        $user = @{
            version     = '2.0'
            cleanupMode = @{ defaultMode = 'Aggressive'; dryRun = $true }
            exclusions  = @{ hardExcluded = @('USERPROFILE:Desktop'); userCustomExclusions = @('C:\KeepMe') }
            taskCategories = @{
                'System Caches' = @{ enabled = $false; riskTier = 'Safe'; description = 'x' }
            }
            riskTiers = @{
                'Safe' = @{ requiresConfirmation = $false; requiresPreview = $false; description = 'd' }
            }
        }
        $json = $user | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $script:CfgFile -Value $json -Encoding UTF8

        Initialize-ConfigModule -ConfigPath $script:CfgFile
        $loaded = Get-UserConfig

        # User overrides win...
        $loaded.cleanupMode.defaultMode   | Should -Be 'Aggressive'
        $loaded.exclusions.userCustomExclusions | Should -Contain 'C:\KeepMe'
        $loaded.taskCategories['System Caches'].enabled | Should -BeFalse
        # ...defaults fill gaps the user file did not define
        $loaded.riskTiers.ContainsKey('Moderate') | Should -BeTrue
        $loaded.behaviorSettings.quarantineBeforeDelete | Should -Not -BeNullOrEmpty
    }

    It 'degrades to defaults (with warning, no throw) for corrupt JSON - collect-and-continue' {
        Set-Content -LiteralPath $script:CfgFile -Value '{ this is not json' -Encoding UTF8
        Initialize-ConfigModule -ConfigPath $script:CfgFile
        # Direct call (no braces): a throw fails the test naturally; wv stays in It scope
        $script:Loaded = Get-UserConfig -WarningVariable wv -WarningAction SilentlyContinue
        $script:Loaded | Should -BeOfType [hashtable]
        @($wv).Count | Should -BeGreaterThan 0 -Because 'corrupt file must warn, not fail silently'
    }

    It 'degrades to defaults for schema-invalid config (missing riskTiers)' {
        $bad = @{ version = '1.0'; cleanupMode = @{}; exclusions = @{}; taskCategories = @{} }
        Set-Content -LiteralPath $script:CfgFile -Value ($bad | ConvertTo-Json -Depth 5) -Encoding UTF8
        Initialize-ConfigModule -ConfigPath $script:CfgFile
        $script:Loaded = Get-UserConfig -WarningVariable wv -WarningAction SilentlyContinue
        @($wv).Count | Should -BeGreaterThan 0
    }

    It 'returns defaults when config file does not exist' {
        Initialize-ConfigModule -ConfigPath (Join-Path $TestDrive 'never-written.json')
        Get-UserConfig | Should -BeOfType [hashtable]
    }

    It '-UseDefault bypasses cache and file entirely' {
        Set-Content -LiteralPath $script:CfgFile -Value '{"version":"9.9"}' -Encoding UTF8
        Initialize-ConfigModule -ConfigPath $script:CfgFile
        $c = Get-UserConfig -UseDefault
        $c.version | Should -Be '1.0' -Because 'defaults, not the 9.9 file, must win with -UseDefault'
    }

    It 'preserves empty and nested arrays from JSON through the load path (converter regression)' {
        $user = @{
            version     = '1.0'
            cleanupMode = @{}
            exclusions  = @{
                hardExcluded          = @()                                  # empty array
                userCustomExclusions  = @('C:\One', 'C:\Two')                # multi-element
            }
            taskCategories = @{
                'T' = @{ enabled = $true; riskTier = 'Safe'; tags = @('only-one') }  # single-element nested
            }
            riskTiers = @{ 'Safe' = @{ requiresConfirmation = $false; requiresPreview = $true } }
        }
        Set-Content -LiteralPath $script:CfgFile -Value ($user | ConvertTo-Json -Depth 10) -Encoding UTF8
        Initialize-ConfigModule -ConfigPath $script:CfgFile
        $loaded = Get-UserConfig

        # NOTE: never PIPE possibly-empty arrays into Should (empty pipeline reads as $null);
        # assert via variable reference instead.
        ($loaded.exclusions.hardExcluded -is [Object[]]) | Should -BeTrue -Because 'empty array must survive conversion'
        @($loaded.exclusions.hardExcluded).Count | Should -Be 0
        @($loaded.exclusions.userCustomExclusions).Count | Should -Be 2
        @($loaded.taskCategories['T'].tags).Count | Should -Be 1 -Because 'single-element arrays must not unwrap to scalars'
    }

    It 'Export-ConfigTemplate writes a readable defaults file' {
        $tpl = Join-Path $TestDrive 'template.json'
        Export-ConfigTemplate -OutputPath $tpl
        Test-Path -LiteralPath $tpl | Should -BeTrue
        $parsed = Get-Content -LiteralPath $tpl -Raw | ConvertFrom-Json
        $parsed.version | Should -Match '^\d+\.\d+$'
    }
}

Describe 'Bakunawa.Config: schema validation' {

    BeforeEach { script:Reset-ConfigModule }

    It 'accepts a minimal valid config' {
        $ok = @{
            version = '1.0'; cleanupMode = @{}; exclusions = @{}
            taskCategories = @{ 'T' = @{ enabled = $true; riskTier = 'Safe' } }
            riskTiers = @{ 'Safe' = @{ requiresConfirmation = $false; requiresPreview = $true } }
        }
        $r = Test-ConfigSchema -Config $ok
        $r.IsValid | Should -BeTrue
        # NOTE: Should -BeEmpty is broken on PS 5.1 + Pester 5.8 (parameter-set error)
        @($r.Errors).Count | Should -Be 0
    }

    It 'rejects missing required top-level keys and reports each' {
        $r = Test-ConfigSchema -Config @{ version = '1.0' }
        $r.IsValid | Should -BeFalse
        foreach ($missing in 'cleanupMode','exclusions','taskCategories','riskTiers') {
            ($r.Errors -join ' ') | Should -Match $missing
        }
    }

    It 'rejects malformed version string' {
        $bad = @{
            version = 'one.point.zero'; cleanupMode = @{}; exclusions = @{}
            taskCategories = @{}; riskTiers = @{}
        }
        (Test-ConfigSchema -Config $bad).IsValid | Should -BeFalse
    }

    It 'rejects task referencing an undefined riskTier' {
        $bad = @{
            version = '1.0'; cleanupMode = @{}; exclusions = @{}
            taskCategories = @{ 'T' = @{ enabled = $true; riskTier = 'NonexistentTier' } }
            riskTiers = @{ 'Safe' = @{ requiresConfirmation = $false; requiresPreview = $true } }
        }
        (Test-ConfigSchema -Config $bad).IsValid | Should -BeFalse
    }

    It 'handles null/empty hashtable input without throwing (boundary)' {
        { Test-ConfigSchema -Config @{} } | Should -Not -Throw
        (Test-ConfigSchema -Config @{}).IsValid | Should -BeFalse
    }
}

Describe 'Bakunawa.Config: persistence round-trip' {

    BeforeEach {
        script:Reset-ConfigModule
        $script:CfgFile = Join-Path $TestDrive 'roundtrip.json'
        Initialize-ConfigModule -ConfigPath $script:CfgFile
    }

    It 'Set-UserConfig writes a file that Get-UserConfig reads back with equal values' {
        $cfg = Get-UserConfig -UseDefault
        $cfg.cleanupMode.defaultMode = 'Aggressive'
        Set-UserConfig -Config $cfg | Should -BeTrue
        Test-Path -LiteralPath $script:CfgFile | Should -BeTrue

        Remove-Module Bakunawa.Config -WarningAction SilentlyContinue   # clear cache
        Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue
        Initialize-ConfigModule -ConfigPath $script:CfgFile
        (Get-UserConfig).cleanupMode.defaultMode | Should -Be 'Aggressive'
    }

    It 'Set-UserConfig backs up an existing file when -Force is absent' {
        Set-Content -LiteralPath $script:CfgFile -Value '{"version":"1.0"}' -Encoding UTF8
        $cfg = Get-UserConfig -UseDefault
        Set-UserConfig -Config $cfg
        Test-Path -LiteralPath "$script:CfgFile.backup" | Should -BeTrue
    }

    It 'Set-UserConfig THROWS on schema-invalid config (validation gate)' {
        $invalid = @{ version = 'not.a.version' }
        { Set-UserConfig -Config $invalid } | Should -Throw
    }

    It 'Reset-UserConfig recreates defaults at the configured path' {
        Reset-UserConfig -Force
        Test-Path -LiteralPath $script:CfgFile | Should -BeTrue
    }
}

Describe 'Bakunawa.Config: exclusion and task helpers' {

    BeforeAll { script:Reset-ConfigModule }

    BeforeEach {
        $script:Base = Get-DefaultConfig
        $script:Base.exclusions.userCustomExclusions = @()
    }

    It 'Add-CustomExclusion appends without duplicates (non-persistent)' {
        $c = Add-CustomExclusion -Path 'C:\A' -Config $script:Base
        $c = Add-CustomExclusion -Path 'C:\A' -Config $c
        @($c.exclusions.userCustomExclusions | Where-Object { $_ -eq 'C:\A' }).Count | Should -Be 1
    }

    It 'Remove-CustomExclusion removes only the named path' {
        $script:Base.exclusions.userCustomExclusions = @('C:\A', 'C:\B')
        $c = Remove-CustomExclusion -Path 'C:\A' -Config $script:Base
        $c.exclusions.userCustomExclusions | Should -Not -Contain 'C:\A'
        $c.exclusions.userCustomExclusions | Should -Contain 'C:\B'
    }

    It 'Get-CustomExclusions combines hard-excluded and user lists' {
        $script:Base.exclusions.hardExcluded = @('H1')
        $script:Base.exclusions.userCustomExclusions = @('U1')
        $e = Get-CustomExclusions -Config $script:Base
        $e | Should -Contain 'H1'
        $e | Should -Contain 'U1'
    }

    It 'Set-TaskEnabled flips the flag; unknown task THROWS' {
        $c = Set-TaskEnabled -TaskName 'System Caches' -Enabled $false -Config $script:Base
        $c.taskCategories['System Caches'].enabled | Should -BeFalse
        { Set-TaskEnabled -TaskName 'No Such Task' -Enabled $true -Config $script:Base } | Should -Throw
    }

    It 'Get-EnabledTasks returns only enabled task names' {
        $script:Base.taskCategories['System Caches'].enabled = $true
        $script:Base.taskCategories['Recycle Bin'].enabled  = $false
        $enabled = Get-EnabledTasks -Config $script:Base
        $enabled | Should -Contain 'System Caches'
        $enabled | Should -Not -Contain 'Recycle Bin'
    }

    It 'Get-TasksByRiskTier filters correctly and validates its parameter' {
        $t = Get-TasksByRiskTier -Config $script:Base -RiskTier 'Confirm'
        $t | Should -Contain 'Recycle Bin'
        { Get-TasksByRiskTier -Config $script:Base -RiskTier 'Bogus' } | Should -Throw
    }

    It 'helpers tolerate $null pipeline input without corrupting state (boundary)' {
        { $null = $null | Add-CustomExclusion -Path 'C:\X' -ErrorAction Stop } | Should -Throw `
            -Because 'a null -Config must be rejected explicitly, not silently mutated'
    }
}

Describe 'Bakunawa.Config: merge semantics' {

    BeforeAll { script:Reset-ConfigModule }

    It 'Merge-ConfigWithDefaults: nested user keys override, absent keys inherit' {
        $defaults = @{
            top = 'keep'
            nested = @{ a = 1; b = 2 }
        }
        $user = @{ nested = @{ b = 99 } }
        $m = Merge-ConfigWithDefaults -UserConfig $user -DefaultConfig $defaults
        $m.top       | Should -Be 'keep'
        $m.nested.a  | Should -Be 1
        $m.nested.b  | Should -Be 99
    }

    It 'Merge-ConfigWithDefaults accepts empty user config (boundary)' {
        $defaults = @{ top = 'keep'; nested = @{ a = 1 } }
        $m = Merge-ConfigWithDefaults -UserConfig @{} -DefaultConfig $defaults
        $m.top | Should -Be 'keep'
        $m.nested.a | Should -Be 1
    }
}
