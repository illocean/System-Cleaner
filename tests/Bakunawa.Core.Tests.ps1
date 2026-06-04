$modulePath = Join-Path $PSScriptRoot '..\Bakunawa.Core.psm1'
Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -Scope Global

Describe 'Bakunawa.Core formatting' {
    It 'formats bytes correctly' {
        Format-FileSize 0 | Should Be '0 B'
        Format-FileSize 500 | Should Be '500 B'
        Format-FileSize 2048 | Should Be '2 KB'
        Format-FileSize 1048576 | Should Be '1.0 MB'
        Format-FileSize 1610612736 | Should Be '1.50 GB'
    }

    It 'returns zero for non-existent directory size' {
        Get-DirectorySize -Path 'C:\NonExistentPath_Bakunawa_Test' | Should Be 0
    }

    It 'creates a case-insensitive tracked set' {
        $set = New-TrackedSet
        $set.Add('Hello') | Should Be $true
        $set.Add('hello') | Should Be $false
    }

    It 'resolves full paths correctly' {
        Resolve-FullPath '' | Should BeNullOrEmpty
        Resolve-FullPath ' ' | Should BeNullOrEmpty
        Resolve-FullPath $env:SystemRoot | Should Not BeNullOrEmpty
    }

    It 'detects non-administrator in normal session' {
        Test-IsAdministrator | Should BeOfType System.Boolean
    }
}

Describe 'Bakunawa.Core orphan risk' {
    It 'scores old + large folder as HIGH' {
        $r = Get-OrphanRiskScore -Name 'OldApp' -SizeBytes 300MB -DaysStale 400 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        ($r.Score -ge 41) | Should Be $true
        $r.RiskLevel | Should Be 'High'
    }

    It 'scores recent + small folder as LOW' {
        $r = Get-OrphanRiskScore -Name 'RecentApp' -SizeBytes 500KB -DaysStale 40 -PathSuffix 'Roaming' -InstalledNames @() -RunningNames @()
        ($r.Score -le 15) | Should Be $true
        $r.RiskLevel | Should Be 'Low'
    }

    It 'reduces score when install matches exact name' {
        $r1 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        $r2 = Get-OrphanRiskScore -Name 'MyTest' -SizeBytes 100MB -DaysStale 200 -PathSuffix 'Local' -InstalledNames @('MyTest') -RunningNames @()
        $r2.Score | Should Be ($r1.Score - 30)
    }

    It 'never returns negative score' {
        $r = Get-OrphanRiskScore -Name 'ActiveApp' -SizeBytes 100 -DaysStale 30 -PathSuffix 'Roaming' -InstalledNames @('ActiveApp') -RunningNames @()
        $r.Score | Should Be 0
    }
}

Describe 'Bakunawa.Core health score' {
    It 'returns a valid result object' {
        $h = Get-HealthScore
        ($h.Score -ge 0 -and $h.Score -le 100) | Should Be $true
        $h.Grade | Should Not BeNullOrEmpty
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
        $summary | Should Be 'Downloads, Documents (+2 more)'
    }

    It 'returns "none" for empty compact list' {
        Format-CompactList -Items @() | Should Be 'none'
    }

    InModuleScope Bakunawa.Core {
        It 'Test-IsExcludedPath excludes Downloads' {
            $script:ExcludedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [void]$script:ExcludedPaths.Add('C:\Users\Demo\Downloads')
            Test-IsExcludedPath 'C:\Users\Demo\Downloads' | Should Be $true
            Test-IsExcludedPath 'C:\Users\Demo\Desktop' | Should Be $false
        }

        It 'Test-SafeCleanupTarget rejects excluded paths' {
            $script:ExcludedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [void]$script:ExcludedPaths.Add('C:\Protected')
            Test-SafeCleanupTarget -Path 'C:\Protected\file.txt' -ApprovedRoots @('C:\Protected') | Should Be $false
        }
    }
}
