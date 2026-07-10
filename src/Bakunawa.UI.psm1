# Bakunawa.UI.psm1 — Terminal rendering engine

function Test-VT100Supported {
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Test-IsWindowsTerminal {
    return [bool]$env:WT_SESSION
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
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE','SCAN')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $prefix, $color = switch($Level) {
        'OK'   { ' [+] ', 'Green' }
        'WARN' { ' [!] ', 'Yellow' }
        'ERR'  { ' [X] ', 'Red' }
        'CMD'  { '  >  ', 'DarkGray' }
    'STEP' { ' >> ', 'Cyan' }
    'SIZE' { ' vv ', 'Magenta' }
    'SCAN' {
    if (-not $script:VerboseScan) { break }
    ' ┊ [SCAN]', 'DarkGray'
    }
    default{ ' [i] ', 'Gray' }
  }
  if ($Level -ne 'SCAN' -or $script:VerboseScan) {
    Write-Host "[$ts]$prefix $Message" -ForegroundColor $color
  }
    if ($script:LogFilePath) {
    $line = "[$ts][$Level] $Message"
    try { Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Warning "Write-Log file write failed: $_" }
}
}

function Write-FileLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Size = 0,
        [string]$Operation = 'SCAN',
        [switch]$IsPreview,
        [datetime]$LastWriteTime = [datetime]::MinValue,
        [int]$Index = 0,
        [int]$Total = 0
    )
    # Safety verdict: excluded path → BLOCKED, modified <7d ago → CAUTION, else → SAFE
    $isExcluded = Test-IsExcludedPath $Path
    if ($isExcluded) {
        $verdict = 'BLOCKED'; $color = 'Red'; $icon = '✗'
    } elseif ($LastWriteTime -ne [datetime]::MinValue -and ((Get-Date) - $LastWriteTime).TotalHours -lt 168) {
        $verdict = 'CAUTION'; $color = 'Yellow'; $icon = '⚠'
    } else {
        $verdict = 'SAFE'; $color = 'Green'; $icon = '✓'
    }

    $ts = Get-Date -Format 'HH:mm:ss'
    $op = $Operation.PadRight(10)

    # Counter string
    $counter = ''
    if ($Total -gt 0) { $counter = "[$Index/$Total] " }

    # Throttle: if total > 50, only show 1 in every N (keep visible output ~50 lines)
    $showLine = $true
    if ($Total -gt 50) {
        $step = [Math]::Ceiling($Total / 50)
        $showLine = ($Index -eq 1) -or ($Index -eq $Total) -or ($Index % $step -eq 0)
    }

    if ($showLine) {
        $verdictStr = $verdict.PadRight(7)
        $cw = Get-ConsoleWidth
        $maxPathLen = [Math]::Max(20, $cw - 38 - $counter.Length)
        $disp = if ($Path.Length -gt $maxPathLen) { '...' + $Path.Substring($Path.Length - $maxPathLen + 3) } else { $Path }

        Write-Host "[$ts] $icon $verdictStr " -ForegroundColor $color -NoNewline
        Write-Host "$op " -ForegroundColor DarkGray -NoNewline
        if ($counter) { Write-Host "$counter" -ForegroundColor DarkCyan -NoNewline }
        Write-Host $disp -ForegroundColor $color
    } elseif ($Index -eq $Total -or ($Total -gt 50 -and $Index % [Math]::Max(1, [Math]::Floor($Total/10)) -eq 0)) {
        # Periodic progress pulse for large sets
        $pct = [Math]::Round($Index / $Total * 100)
        Write-Host "  ... $pct% done ($Index/$Total)" -ForegroundColor DarkGray
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
    $lp = ' '*$pad
    $useBoxDrawing = Test-IsWindowsTerminal
    $topBdr = if ($useBoxDrawing) { '┌'+('─'*($pw-2))+'┐' } else { '+'+('-'*($pw-2))+'+' }
    $sideL = if ($useBoxDrawing) { '│ ' } else { '| ' }
    $sideR = if ($useBoxDrawing) { ' │' } else { ' |' }
    $botBdr = if ($useBoxDrawing) { '└'+('─'*($pw-2))+'┘' } else { '+'+('-'*($pw-2))+'+' }
    Write-Host ($lp+$topBdr) -ForegroundColor $BorderColor
    foreach($l in $Lines){
        $rl = (Get-DisplayText $l $iw).PadRight($iw)
        Write-Host ($lp+$sideL+$rl+$sideR) -ForegroundColor $TextColor
    }
    Write-Host ($lp+$botBdr) -ForegroundColor $BorderColor
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
    $freedStr = if ($script:BytesFreed -gt 0) { " | $(Format-FileSize $script:BytesFreed) freed" } else { '' }
    $Host.UI.RawUI.WindowTitle = "Bakunawa v3 $frame $($script:StepIndex)/$($script:TotalSteps) $($script:ActiveStepName)$freedStr"
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
            '1' { Invoke-CleanupRun 'Standard';   Write-Host ''; Write-Host 'Review the results above.' -ForegroundColor Yellow; Write-Host ''; [void](Read-Host 'Press Enter when ready to return to the menu') }
            '2' { Invoke-CleanupRun 'Aggressive'; Write-Host ''; Write-Host 'Review the results above.' -ForegroundColor Yellow; Write-Host ''; [void](Read-Host 'Press Enter when ready to return to the menu') }
            '3' { Invoke-CleanupRun 'Preview';    Write-Host ''; Write-Host 'Review the results above.' -ForegroundColor Yellow; Write-Host ''; [void](Read-Host 'Press Enter when ready to return to the menu') }
            '4' {
                try {
                    Show-Header; $script:IsPreview=$false
                    Start-Step 'Orphan + unused scan'
                    $o = Find-OrphanFolders -InteractiveDelete
                    $u = Find-UnusedFiles -InteractiveDelete
                    Finish-Step "Scan complete: $o orphans, $u unused files"
                    Write-Host ''
                    Write-Panel @(
                        '=== Scan Results ==='
                        ''
                        " Orphans found : $o"
                        " Unused files  : $u"
                    ) -BorderColor 'Green' -TextColor 'White' -MinWidth 48 -MaxWidth 72
                } catch {
                    Write-Host "Scan failed: $_" -ForegroundColor Red
                    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                }
                Write-Host ''
                Write-Host 'Review the results above.' -ForegroundColor Yellow
                Write-Host ''
                [void](Read-Host 'Press Enter when ready to return to the menu')
            }
            '5' { Show-HealthDetail; Write-Host ''; Write-Host 'Review the results above.' -ForegroundColor Yellow; Write-Host ''; [void](Read-Host 'Press Enter when ready to return to the menu') }
            'Q' { return }
            default { Write-Host 'Invalid.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 500 }
        }
    }
}

function Show-CleanupPotential {
    param([ValidateSet('Standard','Aggressive','Preview')][string]$Mode = 'Standard')
    $effectiveMode = if ($Mode -eq 'Preview') { 'Standard' } else { $Mode }
    $items = @(Get-CleanupPotential -Mode $effectiveMode)
    if ($items.Count -eq 0) { return }
    Write-SectionHeader 'Estimated Cleanup Potential'
    $maxByte = [long]0; $totalBytes = [long]0; $totalFiles = 0; $unknownCount = 0
    foreach ($item in $items) {
        if ($item.EstimatedBytes -gt $maxByte) { $maxByte = $item.EstimatedBytes }
        $totalBytes += $item.EstimatedBytes
        $totalFiles += $item.FileCount
        if ($item.Status -eq 'unknown') { $unknownCount++ }
    }
    $useVT100 = Test-VT100Supported
    $barFillChar = if ($useVT100) { '█' } else { '#' }
    $barEmptyChar = if ($useVT100) { '░' } else { '-' }
    $barWidth = 20
    foreach ($item in $items) {
        if ($item.Status -eq 'unknown') {
            $sizeStr = '    n/a  '
            $fileStr = '   n/a'
        } elseif ($item.EstimatedBytes -gt 0) {
            $sizeStr = Format-FileSize $item.EstimatedBytes
            if ($item.IsEstimate) { $sizeStr = '*' + $sizeStr }  # prepend * for partial estimates
            $fileStr = '{0,5}' -f $item.FileCount
        } else {
            $sizeStr = '   --   '
            $fileStr = '   --'
        }
        $color = switch ($item.Status) {
            'ok'      { 'Green' }
            'skipped' { 'DarkGray' }
            default   { 'DarkYellow' }
        }
        $statusStr = ('{0,-8}' -f $item.Status)
        # Visual size bar proportional to max (min 1 block for non-zero)
        $barLen = if ($maxByte -gt 0 -and $item.EstimatedBytes -gt 0) { [math]::Min($barWidth, [math]::Max(1, [int]($item.EstimatedBytes * $barWidth / $maxByte))) } else { 0 }
        $barFill = if ($barLen -gt 0) { $barFillChar * $barLen } else { '' }
        $barEmpty = $barEmptyChar * [math]::Max(0, $barWidth - $barLen)
        $bar = "$barFill$barEmpty"
        Write-Host ("  {0,-25} {1,10} {2,6}  {3} {4}" -f $item.Target, $sizeStr, $fileStr, $statusStr, $bar) -ForegroundColor $color
    }
    $sepWidth = 53 + $barWidth  # fixed content cols (name+size+files+status+gaps) plus bar
    Write-Host ('  ' + ('─' * $sepWidth)) -ForegroundColor DarkGray
    $totalStr = Format-FileSize $totalBytes
    if (($items | Where-Object IsEstimate).Count -gt 0) {
        $totalStr = '*' + $totalStr
    }
    Write-Host ("  {0,-25} {1,10} {2,6}" -f 'Total', $totalStr, $totalFiles) -ForegroundColor Cyan
    if ($unknownCount -gt 0) {
        Write-Host ("  ({0} items pending estimation — run cleanup to measure actual space)" -f $unknownCount) -ForegroundColor DarkGray
    }
    Write-Host '  * = partial estimate (scanned first 1000 files per directory)'
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

Export-ModuleMember -Function Test-VT100Supported, Test-IsWindowsTerminal, Get-ModeColor, Write-Log, Write-FileLog, Write-CenteredLine, Write-SectionHeader, Write-Panel, Show-AppLogo, Start-Step, Finish-Step, Update-UiTicker, Show-Header, Show-Menu, Show-CleanupPotential, Show-HealthDetail, Show-RunSummary