. $PSScriptRoot\..\Bakunawa.ps1 -SkipBootstrap

Describe 'Bakunawa formatting helpers' {
    It 'builds an ASCII-only progress bar' {
        $bar = New-AsciiBar -Value 3 -Total 10 -Width 10

        $bar | Should -Match '^\[[#\.]{10}\] 30%$'
        $bar.ToCharArray() | Where-Object { [int][char]$_ -gt 127 } | Should -BeNullOrEmpty
    }

    It 'handles zero-total progress bar gracefully' {
        $bar = New-AsciiBar -Value 0 -Total 0 -Width 10
        $bar | Should -Match '\[\.{10}\] 0%'
    }

    It 'clamps progress bar value to total' {
        $bar = New-AsciiBar -Value 20 -Total 10 -Width 10
        $bar | Should -Match '\[#{10}\] 100%'
    }

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

    It 'returns a compact block-font logo' {
        $logo = Get-AppLogoLines

        $logo.Count | Should -BeLessThan 13
        ($logo | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessThan 80
    }
}

Describe 'Bakunawa utility functions' {
    It 'formats bytes correctly' {
        Format-FileSize 0 | Should -Be '0 B'
        Format-FileSize 500 | Should -Be '500 B'
        Format-FileSize 2048 | Should -Be '2 KB'
        Format-FileSize 1048576 | Should -Be '1.0 MB'
        Format-FileSize 1610612736 | Should -Be '1.50 GB'
    }

    It 'returns zero for non-existent directory size' {
        $result = Get-DirectorySize -Path 'C:\NonExistentPath_SystemCleaner_Test'
        $result | Should -Be 0
    }

    It 'creates a case-insensitive tracked set' {
        $set = New-TrackedSet
        $set.Add('Hello') | Should -Be $true
        $set.Add('hello') | Should -Be $false
    }

    It 'resolves full paths correctly' {
        Resolve-FullPath '' | Should -BeNullOrEmpty
        Resolve-FullPath ' ' | Should -BeNullOrEmpty
        $resolved = Resolve-FullPath $env:SystemRoot
        $resolved | Should -Not -BeNullOrEmpty
    }

    It 'returns console width within bounds' {
        $w = Get-ConsoleWidth
        $w | Should -BeGreaterThan 59
    }

    It 'truncates display text properly' {
        Get-DisplayText -Text 'Hello World' -MaxWidth 5 | Should -Be 'He...'
        Get-DisplayText -Text 'Hello World' -MaxWidth 20 | Should -Be 'Hello World'
        Get-DisplayText -Text '' -MaxWidth 10 | Should -Be ''
    }

    It 'detects non-administrator in normal session' {
        $result = Test-IsAdministrator
        $result | Should -BeOfType System.Boolean
    }
}

Describe 'Bakunawa mode colors' {
    It 'returns expected color for each mode' {
        Get-ModeColor 'Standard'   | Should -Be 'Green'
        Get-ModeColor 'Aggressive' | Should -Be 'Yellow'
        Get-ModeColor 'Preview'    | Should -Be 'DarkGray'
        Get-ModeColor 'Menu'       | Should -Be 'DarkCyan'
        Get-ModeColor 'Unknown'    | Should -Be 'DarkCyan'
    }
}

Describe 'Bakunawa tracking and safety' {
    It 'New-TrackedSet is case-insensitive' {
        $set = New-TrackedSet
        $set.Add('TESTPATH')  | Should -Be $true
        $set.Add('testpath')  | Should -Be $false
        $set.Add('TestPath')  | Should -Be $false
    }

    It 'Get-PathLabel extracts leaf name' {
        Get-PathLabel 'C:\Users\TestUser\Downloads' | Should -Be 'Downloads'
        Get-PathLabel (Resolve-FullPath $env:SystemRoot) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PathLabel returns null for empty' {
        Get-PathLabel '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-OrphanRiskScore' {
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

    It 'reduces score on partial name match' {
        $r = Get-OrphanRiskScore -Name 'BraveSoftware' -SizeBytes 2GB -DaysStale 57 -PathSuffix 'Local' -InstalledNames @('Brave') -RunningNames @()
        $r.InstallSig | Should -Be -10
    }

    It 'scores path Local higher than Roaming' {
        $r1 = Get-OrphanRiskScore -Name 'Test' -SizeBytes 0 -DaysStale 30 -PathSuffix 'Local' -InstalledNames @() -RunningNames @()
        $r2 = Get-OrphanRiskScore -Name 'Test' -SizeBytes 0 -DaysStale 30 -PathSuffix 'Roaming' -InstalledNames @() -RunningNames @()
        $r1.PathTrust | Should -Be 3
        $r2.PathTrust | Should -Be 0
    }

    It 'scores ProgramData highest path trust' {
        $r = Get-OrphanRiskScore -Name 'Test' -SizeBytes 0 -DaysStale 30 -PathSuffix 'ProgramData' -InstalledNames @() -RunningNames @()
        $r.PathTrust | Should -Be 5
    }

    It 'never returns negative score' {
        $r = Get-OrphanRiskScore -Name 'ActiveApp' -SizeBytes 100 -DaysStale 30 -PathSuffix 'Roaming' -InstalledNames @('ActiveApp') -RunningNames @()
        $r.Score | Should -Be 0
    }
}

Describe 'Get-HealthScore' {
    It 'returns a valid result object' {
        $h = Get-HealthScore
        ($h.Score -ge 0 -and $h.Score -le 100) | Should -Be $true
        $h.Grade | Should -Not -BeNullOrEmpty
    }

    It 'caches and returns same score within 30s' {
        $h1 = Get-HealthScore
        $h2 = Get-HealthScore
        $h1.Score | Should -Be $h2.Score
    }
}
