# Bakunawa.UI.psm1 -- Terminal rendering engine

if ($null -eq $script:TotalSteps) { $script:TotalSteps = 0 }
if ($null -eq $script:StepIndex)  { $script:StepIndex = 0 }

# NOTE: $script:LogFilePath is owned by THIS module. Set it only via Initialize-UiLogging -
# assigning it from outside (e.g. Bakunawa.ps1 script scope) silently does nothing.

function Initialize-UiLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
    )
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $script:LogFilePath = $full
        return $full
    } catch {
        throw "Initialize-UiLogging failed: $($_.Exception.Message)"
    }
}

function Test-VT100Supported {
    [CmdletBinding()]
    param()
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Get-ModeColor {
    [CmdletBinding()]
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE','SCAN')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'CMD'  { 'DarkGray' }
        'STEP' { 'Cyan' }
        'SIZE' { 'Magenta' }
        'SCAN' { 'Cyan' }
        default{ 'Gray' }
    }
    # Minimal console line: no timestamp, no glyph. Full detail goes to the file log.
    Write-Host "  $Message" -ForegroundColor $color
    if ($script:LogFilePath) {
        $line = "[$ts][$Level] $Message"
        try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 } catch {}
    }
}

function Write-CommandLog {
    [CmdletBinding()]
    param([string]$Verb,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Write-CenteredLine {
    [CmdletBinding()]
    param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-SectionHeader {
    [CmdletBinding()]
    param([string]$Title,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $useVT = Test-VT100Supported
    if ($useVT) {
        $boxH = [char]0x2500
        $line = $boxH.ToString() * [Math]::Max(0, $cw - 4)
        Write-Host (([char]0x250C).ToString()+"- $Title $line") -ForegroundColor $ForegroundColor
    } else {
        $prefix = "-- $Title "
        $line = $prefix + ('-' * [Math]::Max(0, $cw - $prefix.Length))
        Write-Host (Get-DisplayText $line $cw) -ForegroundColor $ForegroundColor
    }
}

function Write-Panel {
    [CmdletBinding()]
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth; $aw = [Math]::Max(20,$cw-4); $mxl=0
    foreach($l in $Lines){if($l.Length -gt $mxl){$mxl=$l.Length}}
    $pw = [Math]::Min($aw,[Math]::Max($MinWidth,$mxl+4))
    $pw = [Math]::Min($pw,$MaxWidth); $pw = [Math]::Min($pw,$cw)
    $iw = [Math]::Max(1,$pw-4); $pad = [Math]::Max(0,[int](($cw-$pw)/2))
    $lp = ' '*$pad
    $useVT = Test-VT100Supported
    # Use White for borders instead of BorderColor parameter
    $actualBorderColor = 'White'
    if ($useVT) {
        $boxH = [char]0x2550; $boxV = [char]0x2551
        $boxTL = [char]0x2554; $boxTR = [char]0x2557
        $boxBL = [char]0x255A; $boxBR = [char]0x255D
        Write-Host ($lp+$boxTL+($boxH.ToString()*($pw-2))+$boxTR) -ForegroundColor $actualBorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+$boxV+' '+$rl+' '+$boxV) -ForegroundColor $actualBorderColor
        }
        Write-Host ($lp+$boxBL+($boxH.ToString()*($pw-2))+$boxBR) -ForegroundColor $actualBorderColor
    } else {
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $actualBorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+'| '+$rl+' |') -ForegroundColor $actualBorderColor
        }
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $actualBorderColor
    }
}

function Show-AppLogo {
    [CmdletBinding()]
    param()
    $logo = @(
        '▀█████████▄     ▄████████    ▄█   ▄█▄ ███    █▄  ███▄▄▄▄      ▄████████  ▄█     █▄     ▄████████'
        ' ███    ███   ███    ███   ███ ▄███▀ ███    ███ ███▀▀▀██▄   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███▐██▀   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ▄███▄▄▄██▀    ███    ███  ▄█████▀    ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        '▀▀███▀▀▀██▄  ▀███████████ ▀▀█████▄    ███    ███ ███   ███ ▀███████████ ███     ███ ▀███████████'
        ' ███    ██▄   ███    ███   ███▐██▄   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███ ▀███▄ ███    ███ ███   ███   ███    ███ ███ ▄█▄ ███   ███    ███'
        ' ▄█████████▀    ███    █▀    ███   ▀█▀ ████████▀   ▀█   █▀    ███    █▀   ▀███▀███▀    ███    █▀ '
        '                            ▀                                                                   '
        '                     D E V O U R   Y O U R   D I G I T A L   W A S T E'
    )
    for ($index = 0; $index -lt $logo.Count; $index++) {
        Write-CenteredLine $logo[$index] 'White'
    }
}

# ── GLYPHS ──
# Monochrome glyph helpers for headers and status lines. The serpent animation
# engine was removed with the minimal-UI redesign; these survive because live
# rendering still uses them.

function Get-ThemedGlyph {
    [CmdletBinding()]
    param([ValidateSet('Step','Ok','Warn','Err','Cmd','Scan','Size','Info','Serp','Flame')][string]$Kind)
    if (Test-VT100Supported) {
        switch ($Kind) {
            'Step'  { return [char]0x25C8 }   # ◈
            'Ok'    { return [char]0x2714 }   # ✔
            'Warn'  { return [char]0x26A0 }   # ⚠
            'Err'   { return [char]0x2718 }   # ✘
            'Cmd'   { return [char]0x2023 }   # ‣
            'Scan'  { return [char]0x25CE }   # ◎
            'Size'  { return [char]0x25D8 }   # ◘
            'Info'  { return [char]0x25CB }   # ○
            'Serp'  { return '~' }
            'Flame' { return '^' }
            default { return [char]0x25CF }   # ●
        }
    }
    switch ($Kind) {
        'Step'  { return '>>' }
        'Ok'    { return '[+]' }
        'Warn'  { return '[!]' }
        'Err'   { return '[X]' }
        'Cmd'   { return '>' }
        'Scan'  { return '[S]' }
        'Size'  { return 'vv' }
        'Info'  { return '[i]' }
        'Serp'  { return '~' }
        'Flame' { return '*' }
        default { return '#' }
    }
}

function Get-MoonPhaseGlyph {
    [CmdletBinding()]
    param([int]$Percent)
    if (Test-VT100Supported) {
        # Monochrome geometric circles (no emoji): new -> crescent -> half -> gibbous -> full
        $moon = @(
            [char]0x25CB,  # ○
            [char]0x25D0,  # ◐
            [char]0x25D2,  # ◒
            [char]0x25D5,  # ◕
            [char]0x25CF   # ●
        )
        $idx = [Math]::Min(4, [Math]::Max(0, [int]($Percent / 25)))
        return $moon[$idx]
    }
    $ascii = @('o','O','@','*')
    $idx = [Math]::Min(3, [Math]::Max(0, [int]($Percent / 34)))
    return $ascii[$idx]
}

function Start-Step {
    [CmdletBinding()]
    param([string]$Name, [int]$Total = 0)
    $script:StepIndex++
    if ($Total -gt 0) { $script:TotalSteps = $Total }
    elseif (-not $script:TotalSteps -or $script:TotalSteps -le 0) { $script:TotalSteps = $script:StepIndex }
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    Write-Host ("{0} {1}" -f $stepTag, $Name) -ForegroundColor Cyan
    $script:ActiveStepName = $Name; $script:ActiveStepPct = 0
    $Host.UI.RawUI.WindowTitle = "Bakunawa $($script:StepIndex)/$($script:TotalSteps) $Name"
}

function Finish-Step {
    [CmdletBinding()]
    param([string]$Summary)
    $script:ActiveStepName = $null
    if ($Summary) {
        Write-Host ("  -> {0}" -f $Summary) -ForegroundColor DarkGray
    }
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'Bakunawa' -Completed -Id 1
        $Host.UI.RawUI.WindowTitle = 'Bakunawa - done'
    }
}

function Show-Header {
    [CmdletBinding()]
    param()
    if (-not $script:CurrentModeName) { $script:CurrentModeName = 'Menu' }
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    $modeColor = Get-ModeColor $script:CurrentModeName
    $free = Get-FreeSpaceInfo
    $ml = if($script:CurrentModeName -eq 'Menu'){'INTERACTIVE'}else{$script:CurrentModeName.ToUpperInvariant()}
    $lr = if($script:LastRunSummary){"$($script:LastRunSummary.Mode) | $($script:LastRunSummary.DurationSeconds)s | $(Format-FileSize $script:LastRunSummary.TotalFreed)"}else{'none yet'}
    $protected = Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3
    $runBar = if($script:CurrentModeName -eq 'Menu'){'[..................] idle'}else{New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 18}
    $healthLine = 'Health     : not available'
    try {
        $h = Get-HealthScore -Fast
        $barChar = if (Test-VT100Supported) { [char]0x2588 } else { '#' }
        $filled = [math]::Floor($h.Score / 10)
        $hb = "$($barChar.ToString() * $filled)$('.' * (10 - $filled))"
        $healthLine = "Health     : $hb $($h.Score)/100 $($h.Grade)"
    } catch {}
    Write-Panel @(
        "Mode       : $ml"
        "Free       : $($free.MB) MB ($($free.GB) GB)"
        "Protected  : $protected"
        $healthLine
        "Last run   : $lr"
        "Run bar    : $runBar"
    ) -BorderColor $modeColor -TextColor 'White' -MinWidth 62 -MaxWidth 92
    Write-Host ''
}

function Show-CleanupPotential {
    [CmdletBinding()]
    param([ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard')
    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    $potential = @(Get-CleanupPotential -Mode $effectiveMode)
    if (-not $potential -or $potential.Count -eq 0) {
        Write-Log 'No cleanup potential data available.' 'WARN'
        return
    }
    Write-SectionHeader 'Cleanup Potential'
    Write-Host ("  {0,-22} {1,12} {2,8}" -f 'Task', 'Size', 'Targets') -ForegroundColor Cyan
    foreach ($item in $potential) {
        Write-Host ("  {0,-22} {1,12} {2,8}" -f $item.Task, (Format-FileSize $item.EstimatedBytes), $item.FileCount) -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Show-Menu {
    [CmdletBinding()]
    param()
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        $runningApps = @()
        if ($script:RunningProcesses) {
            $checkNames = @('chrome','msedge','brave','firefox','discord','slack','teams','spotify','Code')
            $runningApps = $checkNames | Where-Object { $script:RunningProcesses.Contains($_) } | ForEach-Object {
                $label = switch ($_) {
                    'chrome' { 'Chrome' }; 'msedge' { 'Edge' }; 'brave' { 'Brave' }; 'firefox' { 'Firefox' }
                    'discord' { 'Discord' }; 'slack' { 'Slack' }; 'teams' { 'Teams' }; 'spotify' { 'Spotify' }
                    'Code' { 'VS Code' }; default { $_ }
                }
                $label
            }
        }
        $menuLines = [System.Collections.Generic.List[string]]::new()
        [void]$menuLines.Add('MAIN MENU'); [void]$menuLines.Add('')
        [void]$menuLines.Add('[1] Standard    temp, browsers, apps, orphans')
        [void]$menuLines.Add('[2] Aggressive  + DISM + event logs + prefetch')
        [void]$menuLines.Add('[3] Preview     dry run -- see plan only')
        [void]$menuLines.Add('[4] Orphans     interactive orphan review')
        [void]$menuLines.Add('[5] Health      detailed system health report')
        [void]$menuLines.Add('')
        [void]$menuLines.Add('Busy browsers and selected apps are skipped for safety.')
        [void]$menuLines.Add('[Q] Quit')
        if ($runningApps.Count -gt 0) {
            [void]$menuLines.Add('')
            [void]$menuLines.Add("Running -- skipped: $($runningApps -join ', ')")
        }
        Write-Panel @($menuLines) -BorderColor 'Cyan' -TextColor 'White' -MinWidth 64 -MaxWidth 88
        Write-Host ''
        Write-CenteredLine 'Choose a mode and press Enter.' 'DarkGray'
        Write-Host ''
        $choice = Read-Host 'Selection'
if (-not $choice) { continue }
$choice = $choice.Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { Invoke-CleanupRun 'Standard';   Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '2' { Invoke-CleanupRun 'Aggressive'; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '3' { Invoke-CleanupRun 'Preview';    Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '4' { Show-Header; $script:IsPreview=$false; Start-Step 'Orphan folder scan'; $o=Find-OrphanFolders -InteractiveDelete; Finish-Step "Orphan check complete"; Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]') }
            '5' { Show-HealthDetail; [void](Read-Host '[Press Enter to return to Menu]') }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-RunSummary {
    [CmdletBinding()]
    param(
        [string]$Mode, [double]$Duration, $StartSpace, $EndSpace,
        [hashtable]$Steps, [switch]$Aggressive, [int]$LogsCl
    )
    $summaryColor = Get-ModeColor $Mode
    $sumLines = @(
        "Run summary  : $($Mode.ToUpper())"
        "Finished     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Duration     : ${Duration}s"
        "Before       : $($StartSpace.MB) MB ($($StartSpace.GB) GB)"
        "After        : $($EndSpace.MB) MB ($($EndSpace.GB) GB)"
        "Measured     : $(Format-FileSize ([Math]::Max(0, $script:BytesFreed)))"
        "Observed     : $($EndSpace.MB - $StartSpace.MB) MB ($([math]::Round(($EndSpace.MB - $StartSpace.MB)/1024,2)) GB)"
    )
    Write-Host ''
    Write-Panel $sumLines -BorderColor $summaryColor -TextColor 'White' -MinWidth 58 -MaxWidth 86
    Write-Host ''
    if ($script:CategorySizes.Count -gt 0) {
        Write-SectionHeader 'Category Breakdown'
        $script:CategorySizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("  {0,-22} {1,12}" -f $_.Key, (Format-FileSize $_.Value)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-SectionHeader 'Impact'
    Write-Host ("  {0,-16} {1}" -f 'System caches', $Steps.s1) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Browsers', "$($Steps.s2) Chromium | $($Steps.s3) Firefox") -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'App caches', $Steps.s4) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Dev caches', $Steps.s5) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'GPU/Shell', $Steps.s6) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Log files', $Steps.s8) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Empty folders', $Steps.emptyRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Stale junk', $Steps.staleRm) -ForegroundColor DarkGray
    Write-Host ("  {0,-16} {1}" -f 'Orphans', $Steps.orphans) -ForegroundColor $(if($Steps.orphans -gt 0){'Yellow'}else{'DarkGray'})
    if ($script:SkippedItems.Count -gt 0) {
        Write-Host ''; Write-SectionHeader 'Safety Skips'
        $script:SkippedItems | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    if ($script:IsPreview) { Write-Log 'PREVIEW mode. Nothing was deleted.' 'WARN' }
    elseif ($script:IsAggressive) { Write-Log 'Aggressive mode completed with extras.' 'WARN' }
}

function Show-OrphanScanResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ScanResult
    )
    if (-not $ScanResult -or -not $ScanResult.Findings) { return }

    Write-SectionHeader 'Orphan Scan Results'
    $findings = $ScanResult.Findings

    # Group by tier
    $tier1 = $findings | Where-Object { $_.Tier -eq 'Tier1' }
    $tier2 = $findings | Where-Object { $_.Tier -eq 'Tier2' }
    $tier3 = $findings | Where-Object { $_.Tier -eq 'Tier3' }

    if ($tier1.Count -gt 0) {
        Write-Host '  TIER 1 - Safe Auto-Clean (Quarantined):' -ForegroundColor Green
        $totalSize = ($tier1 | Measure-Object -Property Size -Sum).Sum
        Write-Host ("    {0,-50} {1,12}" -f 'Total items:', $tier1.Count) -ForegroundColor DarkGray
        Write-Host ("    {0,-50} {1,12}" -f 'Total size:', (Format-FileSize $totalSize)) -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($tier2.Count -gt 0) {
        Write-Host '  TIER 2 - Review Required:' -ForegroundColor Yellow
        $totalSize = ($tier2 | Measure-Object -Property Size -Sum).Sum
        Write-Host ("    {0,-50} {1,12}" -f 'Total items:', $tier2.Count) -ForegroundColor DarkGray
        Write-Host ("    {0,-50} {1,12}" -f 'Total size:', (Format-FileSize $totalSize)) -ForegroundColor DarkGray
        
        $tier2 | Sort-Object { if ($_.RiskScore) { $_.RiskScore } else { 0 } } -Descending | Select-Object -First 10 | ForEach-Object {
            $riskColor = if ($_.RiskLevel -eq 'High') { 'Red' } elseif ($_.RiskLevel -eq 'Medium') { 'Yellow' } else { 'Green' }
            $path = Get-DisplayText $_.Path 45
            Write-Host ("    {0,-45} {1,10}  [{2}]" -f $path, (Format-FileSize $_.Size), $_.RiskLevel) -ForegroundColor $riskColor
        }
        if ($tier2.Count -gt 10) { Write-Host ("    ... and $($tier2.Count - 10) more") -ForegroundColor DarkGray }
        Write-Host ''
    }

    if ($tier3.Count -gt 0) {
        Write-Host '  TIER 3 - Report Only (Manual Action Required):' -ForegroundColor Red
        $tier3 | Group-Object Tier | ForEach-Object {
            Write-Host ("    {0,-45} {1,5}" -f $_.Name, $_.Count) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
}

function Show-QuarantineSummary {
    [CmdletBinding()]
    param()
    $items = Get-QuarantineInventory
    if (-not $items -or $items.Count -eq 0) {
        Write-Log 'Quarantine is empty.' 'INFO'
        return
    }

    Write-SectionHeader 'Quarantine Summary'
    $totalSize = ($items | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host ("  Total items: $($items.Count)") -ForegroundColor DarkGray
    Write-Host ("  Total size:  $(Format-FileSize $totalSize)") -ForegroundColor DarkGray
    Write-Host ''

    Write-Host '  Recent items:' -ForegroundColor Cyan
    $items | Select-Object -First 10 | ForEach-Object {
        $age = [Math]::Round(((Get-Date) - [DateTime]::Parse($_.Timestamp)).TotalDays, 1)
        $path = Get-DisplayText $_.OriginalPath 45
        $tierColor = if ($_.Tier -eq 'Tier1') { 'Green' } elseif ($_.Tier -eq 'Tier2') { 'Yellow' } else { 'Red' }
        Write-Host ("    {0,-45} {1,10}  [{2}]  {3}d ago" -f $path, (Format-FileSize $_.SizeBytes), $_.Tier, $age) -ForegroundColor $tierColor
    }
    if ($items.Count -gt 10) { Write-Host ("    ... and $($items.Count - 10) more") -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  Commands:' -ForegroundColor Cyan
    Write-Host '    Restore-Item <QuarantineId>           # Restore specific item' -ForegroundColor DarkGray
    Write-Host '    Clear-ExpiredQuarantine -RetentionDays 30  # Purge old items' -ForegroundColor DarkGray
    Write-Host '    Get-QuarantineInventory              # Full list' -ForegroundColor DarkGray
}


function Show-HealthDetail {
    [CmdletBinding()]
    param()
    $cfg = Get-UserConfig -UseDefault
    $health = Get-HealthScore
    
    Write-Host ''
    Write-SectionHeader 'System Health Details'
    Write-Host "  Health Score     : $($health.Score)/100 - $($health.Status)"
    Write-Host "  Reclaimable      : $(Format-FileSize $health.ReclaimableBytes)"
    Write-Host "  Protected Paths  : $($cfg.exclusions.hardExcluded.Count + $cfg.exclusions.userCustomExclusions.Count)"
    Write-Host "  Last Cleanup     : $(if ($health.LastRun) { $health.LastRun } else { 'Never' })"
    Write-Host ''
}

Export-ModuleMember -Function @(
    'Initialize-UiLogging',
    'Write-Log',
    'Write-CommandLog',
    'Write-CenteredLine',
    'Write-SectionHeader',
    'Write-Panel',
    'Show-AppLogo',
    'Get-ThemedGlyph',
    'Get-MoonPhaseGlyph',
    'Start-Step',
    'Finish-Step',
    'Show-Header',
    'Show-CleanupPotential',
    'Show-Menu',
    'Show-RunSummary',
    'Show-OrphanScanResults',
    'Show-QuarantineSummary',
    'Show-HealthDetail',
    'Test-VT100Supported',
    'Get-ModeColor'
)
