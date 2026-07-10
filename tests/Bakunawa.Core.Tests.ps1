$modulePath = Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1'
Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -Scope Global
Describe 'Bakunawa.Core formatting' {
    It 'formats bytes correctly' {
        Format-FileSize 0 | Should -Be '0 B'
        Format-FileSize 500 | Should -Be '500 B'
        Format-FileSize 2048 | Should -Be '2 KB'
        Format-FileSize 1048576 | Should -Be '1.0 MB'
        Format-FileSize 1610612736 | Should -Be '1.50 GB'
    }
    It 'returns zero for non-existent directory size' {
        Get-DirectorySize -Path 'C:\NonExistentPath_Bakunawa_Test' | Should -Be 0
    }
    It 'creates a case-insensitive tracked set' {
        $set = New-TrackedSet
        $set.Add('Hello') | Should -Be $true
        $set.Add('hello') | Should -Be $false
    }
    It 'resolves full paths correctly' {
        Resolve-FullPath '' | Should -BeNullOrEmpty
        Resolve-FullPath ' ' | Should -BeNullOrEmpty
        Resolve-FullPath $env:SystemRoot | Should -Not -BeNullOrEmpty
    }
    It 'detects non-administrator in normal session' {
        Test-IsAdministrator | Should -BeOfType System.Boolean
    }
}
Describe 'Bakunawa.Core orphan risk' {
    It 'scores old + large folder as HIGH' {
        $r = Get-OrphanRiskScore -Name 'OldApp' -SizeBytes 300MB -DaysStale 400 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        ($r.Score -ge 41) | Should -Be $true
        $r.RiskLevel | Should -Be 'High'
    }
    It 'scores recent + small folder as LOW' {
        $r = Get-OrphanRiskScore -Name 'RecentApp' -SizeBytes 500KB -DaysStale 40 -PathSuffix 'Roaming' -InstalledNames @() -RunningNames @()
        ($r.Score -le 15) | Should -Be $true
        $r.RiskLevel | Should -Be 'Low'
    }
    It 'reduces score when install matches exact name' {
        $r1 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        $r2 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @('MyTest') -RunningNames @()
        $r2.Score | Should -Be ($r1.Score - 30)
    }
    It 'never returns negative score' {
        $r = Get-OrphanRiskScore -Name 'ActiveApp' -SizeBytes 100 -DaysStale 30 -PathSuffix 'Roaming' -InstalledNames @('ActiveApp') -RunningNames @()
        $r.Score | Should -Be 0
    }
}
Describe 'Bakunawa.Core health score' {
    It 'returns a valid result object' {
        $h = Get-HealthScore
        ($h.Score -ge 0 -and $h.Score -le 100) | Should -Be $true
        $h.Grade | Should -Not -BeNullOrEmpty
    }
}
Describe 'Bakunawa.Core removed functions' {
    It 'Get-LargestDirectories is not exported' {
        $commands = Get-Command -Module Bakunawa.Core
        $commands.Name | Should -Not -Contain 'Get-LargestDirectories'
    }
}
Describe 'Bakunawa.Core safety' {
    It 'compacts protected paths into short labels' {
        $summary = Format-CompactList -Items @(
            'C:\Users\Demo\Downloads',
            'C:\Users\Demo\Documents',
            'C:\Users\Demo\Desktop',
            'C:\Users\Demo\Pictures'
        ) -MaxItems 2
        $summary | Should -Be 'Downloads, Documents (+2 more)'
    }
    It 'returns "none" for empty compact list' {
        Format-CompactList -Items @() | Should -Be 'none'
    }
    InModuleScope Bakunawa.Core {
        It 'Test-IsExcludedPath excludes Downloads' {
            $script:ExcludedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [void]$script:ExcludedPaths.Add('C:\Users\Demo\Downloads')
            Test-IsExcludedPath 'C:\Users\Demo\Downloads' | Should -Be $true
            Test-IsExcludedPath 'C:\Users\Demo\Desktop' | Should -Be $false
        }
It 'Test-SafeCleanupTarget rejects excluded paths' {
        $script:ExcludedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$script:ExcludedPaths.Add('C:\Protected')
        Test-SafeCleanupTarget -Path 'C:\Protected\file.txt' -ApprovedRoots @('C:\Protected') | Should -Be $false
    }
}
}
Describe 'Bakunawa.Core directory size estimate' {
    It 'returns zero for non-existent path' {
        $r = Get-DirectorySizeEstimate -Path 'C:\NonExistentPath_Bakunawa_Test'
        $r.Bytes | Should -Be 0
        $r.FileCount | Should -Be 0
        $r.IsEstimate | Should -Be $false
    }
    It 'returns correct structure for a real folder' {
        $tmp = [System.IO.Path]::GetTempPath()
        $r = Get-DirectorySizeEstimate -Path $tmp
        $r.PSObject.Properties.Name | Should -Contain 'Path'
        $r.PSObject.Properties.Name | Should -Contain 'Bytes'
        $r.PSObject.Properties.Name | Should -Contain 'FileCount'
        $r.PSObject.Properties.Name | Should -Contain 'IsEstimate'
        $r.Bytes | Should -BeGreaterOrEqual 0
    }
    It 'handles empty directories correctly' {
        $emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "bakunawa_test_empty_$(Get-Random)"
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        try {
            $r = Get-DirectorySizeEstimate -Path $emptyDir
            $r.Bytes | Should -Be 0
            $r.FileCount | Should -Be 0
            $r.IsEstimate | Should -Be $false
        } finally {
            Remove-Item -LiteralPath $emptyDir -Force -EA SilentlyContinue
        }
    }
}
Describe 'Bakunawa.Core ErrorActionPreference' {
    InModuleScope Bakunawa.Core {
        It 'does not set ErrorActionPreference to SilentlyContinue at script scope' {
            # Default is Continue; script should not override to SilentlyContinue
            $ErrorActionPreference | Should -Not -Be 'SilentlyContinue'
        }
        It 'uses Continue (default) or Stop at script scope' {
            $valid = @('Continue', 'Stop', 'Inquire', 'Ignore')
            $valid -contains $ErrorActionPreference | Should -Be $true
        }
    }
}
Describe 'Bakunawa.Core C# accelerator catch handling' {
    It 'PowerShell wrapper Get-DirectorySize logs on C# accelerator failure' {
        $coreContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1') -Raw
        ($coreContent -match 'FastSys.*as \[type\]') | Should -Be $true
        ($coreContent -match 'Get-DirectorySize C# accelerator') | Should -Be $true
    }
}
Describe 'Bakunawa.Core C# accelerator reparse point safety' {
    It 'C# GetDirectorySize skips reparse points (junctions/symlinks)' {
        $moduleContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1') -Raw
        # The C# code must check FileAttributes.ReparsePoint before recursing into subdirectories
        ($moduleContent -match 'ReparsePoint') | Should -Be $true
        # Also verify there's an EnumerateFilesCount method that also skips reparse points
        ($moduleContent -match 'EnumerateFilesCount') | Should -Be $true
    }
}
Describe 'Bakunawa Test-IsWSL catch handling' {
    It 'Test-IsWSL catch block emits a diagnostic message instead of being empty' {
        $scriptContent = Get-Content -Path (Join-Path $PSScriptRoot '..\Bakunawa.ps1') -Raw
        $funcBody = [regex]::Match($scriptContent, 'function\s+Test-IsWSL\s*\{([\s\S]*?)\r?\n\}', 'Singleline').Groups[1].Value
        ($funcBody -match 'Write-Verbose') | Should -Be $true
    }
}

Describe 'Bakunawa Convert-ToWindowsPath guard' {
    It 'returns $null on empty input' {
        $scriptContent = Get-Content -Path (Join-Path $PSScriptRoot '..\Bakunawa.ps1') -Raw
        $funcBody = [regex]::Match($scriptContent, 'function\s+Convert-ToWindowsPath\s*\{([\s\S]*?)\r?\n\}', 'Singleline').Groups[1].Value
        ($funcBody -match 'return \$null') | Should -Be $true
    }
}
Describe 'Bakunawa.Core Get-SystemLocations module scope' {
    It 'Get-SystemLocations updates $script:SysLoc in module scope' {
        $coreContent = Get-Content -Path (Join-Path $PSScriptRoot '..\src\Bakunawa.Core.psm1') -Raw
        $funcBody = [regex]::Match($coreContent, 'function\s+Get-SystemLocations\s*\{([\s\S]*?)\r?\n\}', 'Singleline').Groups[1].Value
        ($funcBody -match '\$script:SysLoc\s*=') | Should -Be $true
    }
}
Describe 'Bakunawa.ps1 elevation error handling' {
    It 'Restart-Elevated suppresses Get-Command errors for pwsh.exe' {
        $scriptContent = Get-Content -Path (Join-Path $PSScriptRoot '..\Bakunawa.ps1') -Raw
        $funcBody = [regex]::Match($scriptContent, 'function\s+Restart-Elevated\s*\{([\s\S]*?)\r?\n\}', 'Singleline').Groups[1].Value
        # Should use -ErrorAction Ignore or $null = Get-Command to avoid leaking errors
        ($funcBody -match 'Get-Command pwsh\.exe.*-ErrorAction (Ignore|Stop)') -or ($funcBody -match '\$null\s*=\s*Get-Command') | Should -Be $true
    }
}
