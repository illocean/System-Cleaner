# Bakunawa.UI.psm1 -- Terminal rendering engine

if (-not $script:SpinnerFrames) { $script:SpinnerFrames = @('|','/','-','\') }
if (-not $script:SpinnerIndex) { $script:SpinnerIndex = 0 }

function Test-VT100Supported {
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Get-ModeColor {
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix, $color = switch($Level) {
        'OK'   { ' [+] ', 'Green' }
        'WARN' { ' [!] ', 'Yellow' }
        'ERR'  { ' [X] ', 'Red' }
        'CMD'  { ' > ', 'DarkGray' }
        'STEP' { ' >> ', 'Cyan' }
        'SIZE' { ' vv ', 'Magenta' }
        default{ ' [i] ', 'Gray' }
    }
    Write-Host "[$ts]$prefix $Message" -ForegroundColor $color
    if ($script:LogFilePath) {
        $line = "[$ts][$Level] $Message"
        try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -EA SilentlyContinue } catch {}
    }
}

function Write-CommandLog {
    param([string]$Verb,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

function Write-CenteredLine {
    param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-SectionHeader {
    param([string]$Title,[string]$ForegroundColor='Cyan')
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
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth; $aw = [Math]::Max(20,$cw-4); $mxl=0
    foreach($l in $Lines){if($l.Length -gt $mxl){$mxl=$l.Length}}
    $pw = [Math]::Min($aw,[Math]::Max($MinWidth,$mxl+4))
    $pw = [Math]::Min($pw,$MaxWidth); $pw = [Math]::Min($pw,$cw)
    $iw = [Math]::Max(1,$pw-4); $pad = [Math]::Max(0,[int](($cw-$pw)/2))
    $lp = ' '*$pad
    $useVT = Test-VT100Supported
    if ($useVT) {
        $boxH = [char]0x2550; $boxV = [char]0x2551
        $boxTL = [char]0x2554; $boxTR = [char]0x2557
        $boxBL = [char]0x255A; $boxBR = [char]0x255D
        Write-Host ($lp+$boxTL+($boxH.ToString()*($pw-2))+$boxTR) -ForegroundColor $BorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+$boxV+' '+$rl+' '+$boxV) -ForegroundColor $TextColor
        }
        Write-Host ($lp+$boxBL+($boxH.ToString()*($pw-2))+$boxBR) -ForegroundColor $BorderColor
    } else {
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $BorderColor
        foreach($l in $Lines){
            $rl = (Get-DisplayText $l $iw).PadRight($iw)
            Write-Host ($lp+'| '+$rl+' |') -ForegroundColor $TextColor
        }
        Write-Host ($lp+'+'+('-'*($pw-2))+'+') -ForegroundColor $BorderColor
    }
}

function Show-AppLogo {
    $logo = @(
        ' .------------------------------------------------------------. '
        ' |   ____        _           _                                | '
        ' |  | _ \      | |         | |                               | '
        ' |  | |_) | __ _| | ____ _  | |__   __ _ _ __  _   _ ___      | '
        ' |  |  _ < / _` | |/ / _` | | `_ \ / _` | `_ \| | | / __|     | '
        ' |  | |_) | (_| |   < (_| | | |_) | (_| | |_) | |_| \__ \     | '
        ' |  |____/ \__,_|_|\_\__,_| |_.__/ \__,_| .__/ \__,_|___/     | '
        ' |                                       | |                  | '
        ' |    B A K U N A W A   v3              |_|   Devour Waste    | '
        ' `------------------------------------------------------------` '
    )
    $colors = @('DarkCyan','Cyan','Cyan','White','Cyan','DarkCyan')
    for ($index = 0; $index -lt $logo.Count; $index++) {
        $color = $colors[[Math]::Min($index, $colors.Count - 1)]
        Write-CenteredLine $logo[$index] $color
    }
    Write-CenteredLine 'Bakunawa -- Devour Your Digital Waste' 'DarkGray'
}

function Start-Step {
    param([string]$Name)
    $script:StepIndex++
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    $stepBar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 12
    Write-Log "$stepTag $stepBar $Name" 'STEP'
    if ($script:TotalSteps -gt 0) {
        $pct = [Math]::Max(1,[int](($script:StepIndex / $script:TotalSteps) * 100))
        $script:ActiveStepName = $Name; $script:ActiveStepPct = $pct
        Update-UiTicker
    }
}

function Finish-Step {
    param([string]$Summary)
    Write-Log $Summary 'OK'
    $script:ActiveStepName = $null
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'Bakunawa devours digital waste...' -Completed -Id 1
        $Host.UI.RawUI.WindowTitle = 'Bakunawa v3 -- Sweep Complete'
    }
}

function Update-UiTicker {
    param([string]$CurrentOperation)
    if (-not $script:ActiveStepName -or $script:TotalSteps -le 0) { return }
    $frame = $script:SpinnerFrames[$script:SpinnerIndex % $script:SpinnerFrames.Count]
    $script:SpinnerIndex++
    $op = if ([string]::IsNullOrWhiteSpace($CurrentOperation)) { $script:ActiveStepName } else { $CurrentOperation }
    $bar = New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 10
    $status = "[${frame}] $bar $op"
    Write-Progress -Activity 'Bakunawa devouring digital waste...' -Status $status -PercentComplete $script:ActiveStepPct -Id 1
    $Host.UI.RawUI.WindowTitle = "Bakunawa v3 $frame $($script:StepIndex)/$($script:TotalSteps) $($script:ActiveStepName)"
}

function Show-Header {
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    $modeColor = Get-ModeColor $script:CurrentModeName
    $free = Get-FreeSpaceInfo
    $ml = if($script:CurrentModeName -eq 'Menu'){'INTERACTIVE'}else{$script:CurrentModeName.ToUpperInvariant()}
    $lr = if($script:LastRunSummary){"$($script:LastRunSummary.Mode) | $($script:LastRunSummary.DurationSeconds)s | $(Format-FileSize $script:LastRunSummary.TotalFreed)"}else{'none yet'}
    $protected = Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3
    $runBar = if($script:CurrentModeName -eq 'Menu'){'[..................] idle'}else{New-AsciiBar -Value $script:StepIndex -Total $script:TotalSteps -Width 18}
    $healthLine = 'Health     : not available'
    try {
        $h = Get-HealthScore
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

function Show-Menu {
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
        $choice = (Read-Host 'Selection').Trim().ToUpperInvariant()
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

Export-ModuleMember -Function Test-VT100Supported, Get-ModeColor, Write-Log, Write-CommandLog, Write-CenteredLine, Write-SectionHeader, Write-Panel, Show-AppLogo, Start-Step, Finish-Step, Update-UiTicker, Show-Header, Show-Menu, Show-RunSummary