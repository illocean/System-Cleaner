# Bakunawa.UI.psm1 — Terminal rendering engine

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
        'CMD'  { '  >  ', 'DarkGray' }
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
    $prefix = "-- $Title "
    $line = $prefix + ('-' * [Math]::Max(0, $cw - $prefix.Length))
    Write-Host (Get-DisplayText $line $cw) -ForegroundColor $ForegroundColor
}

function Write-Panel {
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth; $aw = [Math]::Max(20,$cw-4); $mxl=0
    foreach($l in $Lines){if($l.Length -gt $mxl){$mxl=$l.Length}}
    $pw = [Math]::Min($aw,[Math]::Max($MinWidth,$mxl+4))
    $pw = [Math]::Min($pw,$MaxWidth); $pw = [Math]::Min($pw,$cw)
    $iw = [Math]::Max(1,$pw-4); $pad = [Math]::Max(0,[int](($cw-$pw)/2))
    $lp = ' '*$pad; $bdr = '+'+('-'*($pw-2))+'+'
    Write-Host ($lp+$bdr) -ForegroundColor $BorderColor
    foreach($l in $Lines){
        $rl = (Get-DisplayText $l $iw).PadRight($iw)
        Write-Host ($lp+'| '+$rl+' |') -ForegroundColor $TextColor
    }
    Write-Host ($lp+$bdr) -ForegroundColor $BorderColor
}

function Show-AppLogo {
    $logo = @(
        '██████╗  █████╗ ██╗  ██╗██╗   ██╗███╗   ██╗ █████╗ ██╗    ██╗ █████╗ '
        '██╔══██╗██╔══██╗██║ ██╔╝██║   ██║████╗  ██║██╔══██╗██║    ██║██╔══██╗'
        '██████╔╝███████║█████╔╝ ██║   ██║██╔██╗ ██║███████║██║ █╗ ██║███████║'
        '██╔══██╗██╔══██║██╔═██╗ ██║   ██║██║╚██╗██║██╔══██║██║███╗██║██╔══██║'
        '██████╔╝██║  ██║██║  ██╗╚██████╔╝██║ ╚████║██║  ██║╚███╔███╔╝██║  ██║'
        '╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝  ╚═╝'
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
        $script:LastUiMs = -999999
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
    $nowMs = [long]([System.Diagnostics.Stopwatch]::GetTimestamp() / 10000)
    if (($nowMs - $script:LastUiMs) -lt $script:UiTickMs) { return }
    $script:LastUiMs = $nowMs
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
        $filled = [math]::Floor($h.Score / 10)
        $hb = ('#' * $filled) + ('.' * (10 - $filled))
        $healthLine = "Health     : [$hb] $($h.Score)/100 $($h.Grade)"
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
                switch ($_) {
                    'chrome' { 'Chrome' }; 'msedge' { 'Edge' }; 'brave' { 'Brave' }; 'firefox' { 'Firefox' }
                    'discord' { 'Discord' }; 'slack' { 'Slack' }; 'teams' { 'Teams' }; 'spotify' { 'Spotify' }
                    'Code' { 'VS Code' }; default { $_ }
                }
            }
        }
        $menuLines = [System.Collections.Generic.List[string]]::new()
        [void]$menuLines.Add('MAIN MENU'); [void]$menuLines.Add('')
        [void]$menuLines.Add('[1] Standard    temp, browsers, apps, dev caches, GPU, orphans, unused files')
        [void]$menuLines.Add('[2] Aggressive  standard + DISM + event logs + prefetch')
        [void]$menuLines.Add('[3] Preview     show the cleanup plan only')
        [void]$menuLines.Add('[4] Scan        orphan folders + unused files across C:')
        [void]$menuLines.Add('[5] Health      system health dashboard with details')
        [void]$menuLines.Add('[6] Disk Usage  analyze largest space consumers on system drive')
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
            '4' {
                try {
                    Show-Header; $script:IsPreview=$false
                    Start-Step 'Orphan + unused scan'
                    $o = Find-OrphanFolders -InteractiveDelete
                    $u = Find-UnusedFiles -InteractiveDelete
                    Finish-Step "Scan complete: $o orphans, $u unused files"
                } catch {
                    Write-Host "Scan failed: $_" -ForegroundColor Red
                    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                }
                Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]')
            }
            '5' { Show-HealthDetail; [void](Read-Host '[Press Enter to return to Menu]') }
            '6' {
                try {
                    Show-Header
                    Write-Host ''
                    Write-CenteredLine '=== Disk Usage Analyzer ===' 'Cyan'
                    Write-Host ''
                    $dirs = Get-LargestDirectories
                    if ($dirs.Count -eq 0) {
                        Write-Host 'No directories found above 10 MB threshold.' -ForegroundColor Yellow
                    } else {
                        Write-Host ('{0,-10} {1,-60} {2}' -f 'Size', 'Path', 'Last Modified') -ForegroundColor Cyan
                        Write-Host ('{0,-10} {1,-60} {2}' -f ('-'*8), ('-'*58), ('-'*19))
                        foreach ($d in $dirs) {
                            Write-Host ('{0,-10} {1,-60} {2}' -f $d.SizeText, $d.Path, $d.LastWrite.ToString('yyyy-MM-dd'))
                        }
                    }
                } catch {
                    Write-Host "Disk Usage scan failed: $_" -ForegroundColor Red
                }
                Write-Host ''; [void](Read-Host '[Press Enter to return to Menu]')
            }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-HealthDetail {
    try {
        $h = Get-HealthScore
        Clear-Host
        Write-Host ''
        Write-CenteredLine '==================== System Health Report ====================' $h.GradeColor
        Write-Host ''
        Write-Panel @(
            "Score : $($h.Score)/100 $($h.Grade)"
            ''
            "Disk Pressure   : $($h.DiskScore)/30  ($($h.DiskPct)% free)"
            "Temp/Cache      : $($h.TempScore)/25  ($($h.TempMB) MB)"
            "Browser Cache   : $($h.BrowserScore)/20 ($($h.BrowserAge)d oldest)"
            "Orphan Risk     : $($h.OrphanScore)/25 $(if($h.OrphanInfo){'('+$h.OrphanInfo.HighCount+' high, '+$h.OrphanInfo.MedCount+' medium)'}else{'(no orphan data yet)'})"
        ) -BorderColor $h.GradeColor -TextColor 'White' -MinWidth 60 -MaxWidth 88
        Write-Host ''
        Write-Log 'Next full evaluation in 30 seconds.' 'INFO'
        Write-Host ''
    } catch {
        Write-Host "Health check failed: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
}

function Show-RunSummary {
    param(
        [string]$Mode, [double]$Duration, $StartSpace, $EndSpace,
        [hashtable]$StepCounts = @{}
    )
    $summaryColor = Get-ModeColor $Mode
    $freedFormatted = Format-FileSize ([Math]::Max(0, $script:BytesFreed))
    $freedMB = if ($StartSpace) { $EndSpace.MB - $StartSpace.MB } else { 0 }
    $freedGB = [math]::Round($freedMB / 1024, 2)
    $pipelineBar = New-AsciiBar -Value $script:TotalSteps -Total $script:TotalSteps -Width 18
    $sumLines = @(
        "Run summary  : $($Mode.ToUpper())"
        "Pipeline     : $pipelineBar"
        "Finished     : $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
        "Duration     : $([math]::Round($Duration, 1))s"
        "Before       : $($StartSpace.MB) MB ($($StartSpace.GB) GB)"
        "After        : $($EndSpace.MB) MB ($($EndSpace.GB) GB)"
        "Measured     : $freedFormatted"
        "Observed     : $freedMB MB ($freedGB GB)"
    )
    Write-Host ''
    Write-Panel $sumLines -BorderColor $summaryColor -TextColor 'White' -MinWidth 58 -MaxWidth 86
    Write-Host ''

    # Category breakdown
    if ($script:CategorySizes.Count -gt 0) {
        Write-SectionHeader 'Category Breakdown'
        $script:CategorySizes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-Host ("  {0,-22} {1,12}" -f $_.Key, (Format-FileSize $_.Value)) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    # Impact section with per-step counts
    if ($StepCounts.Count -gt 0) {
        Write-SectionHeader 'Impact'
        foreach ($key in @('System caches','Browsers','App caches','Dev caches','Game caches','Cloud sync','Creative apps','Productivity','DevOps tools','GPU/Shell','Log files','Empty folders','Stale junk','Unused files','Orphans','Recycle Bin','Prefetch','DISM','Event logs','Font cache')) {
            if ($StepCounts.ContainsKey($key)) {
                $val = $StepCounts[$key]
                $color = if ($key -eq 'Orphans' -and $val -gt 0) { 'Yellow' } else { 'DarkGray' }
                Write-Host ("  {0,-16} {1}" -f $key, $val) -ForegroundColor $color
            }
        }
        Write-Host ''
    }

    # Errors summary
    if ($script:Errors.Count -gt 0) {
        Write-SectionHeader 'Errors'
        $script:Errors | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor Red
        }
        Write-Host ''
    }

    # Safety skips
    if ($script:SkippedItems.Count -gt 0) {
        Write-SectionHeader 'Safety Skips'
        $script:SkippedItems | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object {
            Write-Host ("  {0,2}x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    if ($script:IsPreview) { Write-Log 'PREVIEW mode. Nothing was deleted.' 'WARN' }
    elseif ($script:IsAggressive) { Write-Log 'Aggressive mode completed with extras.' 'WARN' }
}

Export-ModuleMember -Function Test-VT100Supported, Get-ModeColor, Write-Log, Write-CenteredLine, Write-SectionHeader, Write-Panel, Show-AppLogo, Start-Step, Finish-Step, Update-UiTicker, Show-Header, Show-Menu, Show-HealthDetail, Show-RunSummary